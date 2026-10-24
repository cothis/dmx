//! `docker_start`: starts dockerd through /sbin/dmx-docker (guest/docker) the first time the host
//! uses the Docker socket after a boot, and returns once the socket answers. Nothing of Docker
//! runs before that, so a VM that never sees a Docker client does not pay for it.

use serde::Serialize;
use std::io::{self, Read};
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::process::{Command, Stdio};
use std::sync::Mutex;
use std::time::{Duration, Instant};

const SCRIPT: &str = "/sbin/dmx-docker";
pub const SOCKET: &str = "/var/run/docker.sock";
const PIDFILE: &str = "/var/run/docker.pid";
const LOG: &str = "/var/lib/dmx/log/dockerd.log";
/// The first start unpacks Docker onto the data disk; a loaded host slows everything down.
const START_TIMEOUT: Duration = Duration::from_secs(120);

#[derive(Serialize)]
pub struct Started {
    /// False when dockerd was answering already.
    pub started: bool,
    pub ms: u64,
}

/// Starts dockerd unless it answers. Concurrent calls wait for the one start.
pub fn start() -> io::Result<Started> {
    static LOCK: Mutex<()> = Mutex::new(());
    let _held = LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let begun = Instant::now();
    if answers() {
        return Ok(Started { started: false, ms: 0 });
    }
    let mut cmd = Command::new(SCRIPT);
    cmd.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::piped());
    // Its own session, so nothing aimed at an exec's process group reaches it.
    unsafe {
        cmd.pre_exec(|| {
            crate::exec::default_signals();
            libc::setsid();
            Ok(())
        });
    }
    let mut child = cmd.spawn().map_err(|e| io::Error::new(e.kind(), format!("{SCRIPT}: {e}")))?;
    // The script's own complaints; dockerd's output goes to its log, which closes this pipe.
    let mut stderr = child.stderr.take();
    let complaints = std::thread::spawn(move || {
        let mut text = String::new();
        if let Some(s) = stderr.as_mut() {
            let _ = s.read_to_string(&mut text);
        }
        text
    });
    loop {
        if answers() {
            std::thread::spawn(move || {
                let status = child.wait();
                eprintln!("dmx-agent: dockerd exited: {status:?}");
            });
            return Ok(Started { started: true, ms: begun.elapsed().as_millis() as u64 });
        }
        if let Some(status) = child.try_wait()? {
            let text = complaints.join().unwrap_or_default();
            return Err(io::Error::other(format!("dockerd did not start ({status}): {} (see {LOG})", text.trim())));
        }
        if begun.elapsed() > START_TIMEOUT {
            return Err(io::Error::other(format!("dockerd did not answer within {} s (see {LOG})", START_TIMEOUT.as_secs())));
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn answers() -> bool {
    UnixStream::connect(SOCKET).is_ok()
}

/// Before power off: asks dockerd to stop its containers and exit, for at most `limit`.
pub fn stop(limit: Duration) {
    let Some(pid) = std::fs::read_to_string(PIDFILE).ok().and_then(|s| s.trim().parse::<libc::pid_t>().ok()) else { return };
    if pid <= 1 || unsafe { libc::kill(pid, libc::SIGTERM) } != 0 {
        return;
    }
    let begun = Instant::now();
    while begun.elapsed() < limit && alive(pid) {
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// Whether `pid` still runs (a zombie waiting to be reaped does not).
fn alive(pid: libc::pid_t) -> bool {
    match std::fs::read_to_string(format!("/proc/{pid}/stat")) {
        Ok(stat) => stat.rsplit_once(") ").is_some_and(|(_, rest)| !rest.starts_with('Z')),
        Err(_) => false,
    }
}
