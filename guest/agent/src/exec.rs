//! `exec`: run a process, stream its output as frames, feed it stdin, report its exit.
//! The request takes over the connection; it closes after the `exit` event.

use crate::frame;
use crate::vsock::Stream;
use serde::Deserialize;
use std::fs::File;
use std::io::{Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{mpsc, Arc, Condvar, Mutex};
use std::collections::VecDeque;
use std::time::{Duration, Instant};

#[derive(Deserialize)]
pub struct Params {
    pub argv: Vec<String>,
    /// "KEY=VALUE" entries added to the agent's environment.
    #[serde(default)]
    pub env: Vec<String>,
    pub cwd: Option<String>,
    #[serde(default)]
    pub tty: bool,
    /// Without a tty, whether the host sends stdin; otherwise stdin is /dev/null.
    #[serde(default)]
    pub stdin: bool,
    #[serde(default)]
    pub flow_control: bool,
    #[serde(default = "rows")]
    pub rows: u16,
    #[serde(default = "cols")]
    pub cols: u16,
}

fn rows() -> u16 {
    24
}
fn cols() -> u16 {
    80
}

#[derive(Deserialize)]
struct Control {
    method: String,
    #[serde(default)]
    params: serde_json::Value,
}

/// After the process exits, output still arriving is forwarded until the streams have been
/// quiet this long; background children that keep a stream open do not block `exit` forever.
const DRAIN_QUIET: Duration = Duration::from_millis(500);

/// A byte limit, not a frame limit: terminal input may arrive one byte per frame.
struct InputQueue {
    state: Mutex<(VecDeque<u8>, bool)>,
    ready: Condvar,
    limit: usize,
}
impl InputQueue {
    fn new(limit: usize) -> Self { Self { state: Mutex::new((VecDeque::new(), false)), ready: Condvar::new(), limit } }
    fn push(&self, data: &[u8]) -> bool {
        let mut s = self.state.lock().unwrap();
        if s.1 || s.0.len()+data.len()>self.limit { return false; }
        if data.is_empty() { s.1 = true; } else { s.0.extend(data); }
        self.ready.notify_one();
        true
    }
    fn end(&self) { let mut s = self.state.lock().unwrap(); s.1 = true; self.ready.notify_one(); }
    fn take(&self) -> Option<Vec<u8>> {
        let mut s = self.state.lock().unwrap();
        while s.0.is_empty() && !s.1 { s = self.ready.wait(s).unwrap(); }
        if s.0.is_empty() { return None; }
        let n = s.0.len().min(32768);
        let data = s.0.drain(..n).collect();
        Some(data)
    }
}

pub fn run(id: u64, p: Params, mut conn: Stream, out: Arc<Mutex<Stream>>) {
    if p.argv.is_empty() {
        crate::reply_err(&out, id, "bad_request", "argv is empty".into());
        return;
    }
    let mut cmd = Command::new(&p.argv[0]);
    cmd.args(&p.argv[1..]);
    for kv in &p.env {
        if let Some((k, v)) = kv.split_once('=') {
            cmd.env(k, v);
        }
    }
    if let Some(cwd) = &p.cwd {
        cmd.current_dir(cwd);
    }

    // The agent runs in a background subshell of /init, which starts it with SIGINT and SIGQUIT
    // ignored, and dispositions set to SIG_IGN survive exec. Give the process default ones.
    unsafe {
        cmd.pre_exec(|| {
            default_signals();
            Ok(())
        });
    }

    // Where stdin frames go, and the streams to forward as stdout/stderr frames.
    let mut stdin: Option<Box<dyn Write + Send>> = None;
    let mut outputs: Vec<(u8, Box<dyn Read + Send>)> = Vec::new();
    let mut master: Option<OwnedFd> = None;
    if p.tty {
        let (m, s) = match openpty(p.rows, p.cols) {
            Ok(pair) => pair,
            Err(e) => return crate::reply_err(&out, id, "exec_failed", format!("openpty: {e}")),
        };
        let dup = |fd: &OwnedFd| fd.try_clone().map(Stdio::from);
        match (dup(&s), dup(&s), dup(&s)) {
            (Ok(a), Ok(b), Ok(c)) => {
                cmd.stdin(a).stdout(b).stderr(c);
            }
            _ => return crate::reply_err(&out, id, "exec_failed", "dup pty".into()),
        }
        // A new session with the pty as its controlling terminal, so job control and ^C work.
        unsafe {
            cmd.pre_exec(|| {
                if libc::setsid() < 0 || libc::ioctl(0, libc::TIOCSCTTY, 0) < 0 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
        if let (Ok(r), Ok(w)) = (m.try_clone(), m.try_clone()) {
            outputs.push((frame::STDOUT, Box::new(File::from(r))));
            stdin = Some(Box::new(File::from(w)));
        }
        master = Some(m);
    } else {
        cmd.stdin(if p.stdin { Stdio::piped() } else { Stdio::null() });
        cmd.stdout(Stdio::piped()).stderr(Stdio::piped());
        cmd.process_group(0);
    }

    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => return crate::reply_err(&out, id, "exec_failed", format!("{}: {e}", p.argv[0])),
    };
    // Command holds the parent's copies of the pty slave; the master only reports EOF once they close.
    drop(cmd);
    if let Some(s) = child.stdin.take() {
        stdin = Some(Box::new(s));
    }
    if let Some(s) = child.stdout.take() {
        outputs.push((frame::STDOUT, Box::new(s)));
    }
    if let Some(s) = child.stderr.take() {
        outputs.push((frame::STDERR, Box::new(s)));
    }
    let pid = child.id() as libc::pid_t;
    let alive = Arc::new(Mutex::new(true));
    let master = master.map(Arc::new);
    crate::reply_ok(&out, id, serde_json::json!({ "pid": pid, "stdin_window": if p.flow_control { Some(65536) } else { None } }));

    let started = Instant::now();
    let last_output = Arc::new(AtomicU64::new(0));
    // Pumps blocked writing to the host (which reads slower than the process wrote) are not quiet.
    let writing = Arc::new(AtomicUsize::new(0));
    let (done_tx, done_rx) = mpsc::channel();
    let pumps = outputs.len();
    for (kind, mut src) in outputs {
        let (out, last, done, writing) = (out.clone(), last_output.clone(), done_tx.clone(), writing.clone());
        std::thread::spawn(move || {
            let mut buf = vec![0u8; 32 << 10];
            // A pty master reads EIO once the last slave closes; treat it like EOF.
            while let Ok(n @ 1..) = src.read(&mut buf) {
                last.store(started.elapsed().as_millis() as u64, Ordering::Relaxed);
                writing.fetch_add(1, Ordering::SeqCst);
                let sent = frame::write(&mut *out.lock().unwrap(), kind, &buf[..n]);
                last.store(started.elapsed().as_millis() as u64, Ordering::Relaxed);
                writing.fetch_sub(1, Ordering::SeqCst);
                if sent.is_err() {
                    break;
                }
            }
            let _ = done.send(());
        });
    }

    // The reader never writes child stdin. Credit bounds queued bytes, leaving control live.
    let input = Arc::new(InputQueue::new(if p.flow_control { 65536 } else { frame::MAX_FRAME }));
    // Legacy clients cannot negotiate byte credit. Their queue remains bounded; overflow
    // retires the connection instead of blocking the reader behind a stalled child.
    {
        let input = input.clone();
        let out = out.clone();
        std::thread::spawn(move || {
            while let Some(data) = input.take() {
                if let Some(w) = stdin.as_mut() {
                    if w.write_all(&data).is_err() { stdin = None; }
                }
                if p.flow_control {
                    let event = serde_json::json!({"event":"stdin_credit", "bytes":data.len()});
                    if frame::write(&mut *out.lock().unwrap(), frame::JSON, event.to_string().as_bytes()).is_err() { break; }
                }
            }
        });
    }
    {
        let alive = alive.clone();
        let master = master.clone();
        let input = input.clone();
        std::thread::spawn(move || {
            while let Ok(Some(f)) = frame::read(&mut conn) {
                match f.kind {
                    frame::STDIN => {
                        // A peer that ignores the negotiated window must not pin the reader.
                        if (p.flow_control && f.payload.len() > 32768) || !input.push(&f.payload) { break; }
                    }
                    frame::JSON => {
                        control_if_live(&f.payload, pid, master.as_ref().map(|m| m.as_raw_fd()), &alive);
                    }
                    _ => {}
                }
            }
            input.end();
            conn.shutdown(); // wake legacy writers/control calls even if stdout is also full
            // Keep the unreaped PID reserved while signalling its process group.
            let live = alive.lock().unwrap();
            if *live { unsafe { libc::kill(-pid, libc::SIGKILL); } }
        });
    }

    // Observe exit without reaping: the reader can signal until this point without PID reuse.
    let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
    unsafe {
        while libc::waitid(libc::P_PID, pid as libc::id_t, &mut info, libc::WEXITED | libc::WNOWAIT) < 0 {
            if std::io::Error::last_os_error().kind() != std::io::ErrorKind::Interrupted { break; }
        }
    }
    let status = {
        let mut live = alive.lock().unwrap();
        *live = false;
        child.wait()
    };
    let mut finished = 0;
    while finished < pumps {
        match done_rx.recv_timeout(Duration::from_millis(50)) {
            Ok(()) => finished += 1,
            Err(_) => {
                let quiet = started.elapsed().as_millis() as u64 - last_output.load(Ordering::Relaxed);
                if quiet >= DRAIN_QUIET.as_millis() as u64 && writing.load(Ordering::SeqCst) == 0 {
                    break;
                }
            }
        }
    }
    let (code, signal) = match &status {
        Ok(s) => (s.code(), s.signal()),
        Err(_) => (None, None),
    };
    let event = serde_json::json!({ "id": id, "event": "exit", "code": code, "signal": signal });
    let _ = frame::write(&mut *out.lock().unwrap(), frame::JSON, event.to_string().as_bytes());
    drop(master);
}

/// Default dispositions and an empty mask, for a process the agent starts (in `pre_exec`).
pub fn default_signals() {
    unsafe {
        for sig in 1..libc::SIGRTMIN() {
            if sig != libc::SIGKILL && sig != libc::SIGSTOP {
                libc::signal(sig, libc::SIG_DFL);
            }
        }
        let mut empty: libc::sigset_t = std::mem::zeroed();
        libc::sigemptyset(&mut empty);
        libc::sigprocmask(libc::SIG_SETMASK, &empty, std::ptr::null_mut());
    }
}

fn control_if_live(payload: &[u8], pid: libc::pid_t, master: Option<libc::c_int>, alive: &Mutex<bool>) {
    let live = alive.lock().unwrap();
    if *live { control(payload, pid, master); }
}

fn control(payload: &[u8], pid: libc::pid_t, master: Option<libc::c_int>) {
    let Ok(c) = serde_json::from_slice::<Control>(payload) else { return };
    let num = |k: &str| c.params.get(k).and_then(|v| v.as_u64());
    match c.method.as_str() {
        "resize" => {
            if let (Some(fd), Some(rows), Some(cols)) = (master, num("rows"), num("cols")) {
                let ws = winsize(rows as u16, cols as u16);
                unsafe { libc::ioctl(fd, libc::TIOCSWINSZ, &ws) };
            }
        }
        "signal" => {
            if let Some(sig) = num("signal") {
                unsafe { libc::kill(pid, sig as libc::c_int) };
            }
        }
        _ => {}
    }
}

fn winsize(rows: u16, cols: u16) -> libc::winsize {
    libc::winsize { ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0 }
}

fn openpty(rows: u16, cols: u16) -> std::io::Result<(OwnedFd, OwnedFd)> {
    let (mut m, mut s) = (-1, -1);
    let mut ws = winsize(rows, cols);
    if unsafe { libc::openpty(&mut m, &mut s, std::ptr::null_mut(), std::ptr::null(), &mut ws) } < 0 {
        return Err(std::io::Error::last_os_error());
    }
    for fd in [m, s] {
        unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) };
    }
    Ok(unsafe { (OwnedFd::from_raw_fd(m), OwnedFd::from_raw_fd(s)) })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::net::UnixStream;

    #[test]
    fn blocked_stdin_disconnect_reaps_child() {
        let (agent, mut host) = UnixStream::pair().unwrap();
        let conn = Stream::from_fd(agent.into());
        let out = Arc::new(Mutex::new(conn.try_clone().unwrap()));
        let params: Params = serde_json::from_value(serde_json::json!({"argv":["sleep","30"],"stdin":true,"flow_control":true})).unwrap();
        let thread = std::thread::spawn(move || run(1, params, conn, out));
        let started = frame::read(&mut host).unwrap().unwrap();
        let pid = serde_json::from_slice::<serde_json::Value>(&started.payload).unwrap()["result"]["pid"].as_i64().unwrap() as libc::pid_t;
        for _ in 0..2 { frame::write(&mut host, frame::STDIN, &vec![1;32768]).unwrap(); }
        std::thread::sleep(Duration::from_millis(100));
        drop(host);
        let deadline = Instant::now()+Duration::from_secs(1);
        while Instant::now()<deadline && unsafe { libc::kill(pid,0) } == 0 { std::thread::sleep(Duration::from_millis(10)); }
        let gone = unsafe { libc::kill(pid,0) } < 0;
        if !gone { unsafe { libc::kill(-pid,libc::SIGKILL); } }
        thread.join().unwrap();
        assert!(gone,"disconnect must kill/reap a child even while its stdin writer is blocked");
    }

    #[test]
    fn legacy_overflow_disconnects_instead_of_blocking_control() {
        let (agent, mut host) = UnixStream::pair().unwrap();
        host.set_write_timeout(Some(Duration::from_millis(500))).unwrap();
        let conn = Stream::from_fd(agent.into());
        let out = Arc::new(Mutex::new(conn.try_clone().unwrap()));
        let params: Params = serde_json::from_value(serde_json::json!({"argv":["sleep","30"],"stdin":true})).unwrap();
        let thread = std::thread::spawn(move || run(1, params, conn, out));
        let started = frame::read(&mut host).unwrap().unwrap();
        let pid = serde_json::from_slice::<serde_json::Value>(&started.payload).unwrap()["result"]["pid"].as_i64().unwrap() as libc::pid_t;
        let mut closed = false;
        for _ in 0..64 {
            if let Err(e) = frame::write(&mut host, frame::STDIN, &vec![1;512<<10]) {
                closed = !matches!(e.kind(), std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut);
                break;
            }
        }
        drop(host);
        let deadline = Instant::now()+Duration::from_secs(1);
        while Instant::now()<deadline && unsafe { libc::kill(pid,0) } == 0 { std::thread::sleep(Duration::from_millis(10)); }
        let gone = unsafe { libc::kill(pid,0) } < 0;
        if !gone { unsafe { libc::kill(-pid,libc::SIGKILL); } }
        thread.join().unwrap();
        assert!(closed,"legacy queue overflow must close the stream rather than retain a blocked writer");
        assert!(gone,"legacy overflow must reap the child");
    }

    #[test]
    fn control_after_exit_does_not_signal_another_process() {
        let mut child = Command::new("sleep").arg("30").spawn().unwrap();
        let payload = br#"{"method":"signal","params":{"signal":9}}"#;
        control_if_live(payload,child.id() as libc::pid_t,None,&Mutex::new(false));
        std::thread::sleep(Duration::from_millis(20));
        let alive = child.try_wait().unwrap().is_none();
        let _ = child.kill(); let _ = child.wait();
        assert!(alive,"a late control must not signal a reused pid");
    }
}
