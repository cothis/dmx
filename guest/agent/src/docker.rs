//! `docker_start`: starts dockerd through /sbin/dmx-docker (guest/docker) the first time the host
//! uses the Docker socket after a boot, and returns once the socket answers. Nothing of Docker
//! runs before that, so a VM that never sees a Docker client does not pay for it, unless a
//! container would come back by its restart policy: the host asks at boot (`docker_autostart`).

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::fs::OpenOptions;
use std::io::{self, Read, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::process::{ChildStderr, Command, Stdio};
use std::os::fd::AsRawFd;
use std::sync::{Arc, Mutex};
use std::collections::VecDeque;
use std::path::Path;
use std::time::{Duration, Instant};

const SCRIPT: &str = "/sbin/dmx-docker";
pub const SOCKET: &str = "/var/run/docker.sock";
const PIDFILE: &str = "/var/run/docker.pid";
const CONFIG: &str = "/run/dmx/daemon.json";
const HOST_CA: &str = "/run/dmx/host-ca.pem";
const LOG: &str = "/var/lib/dmx/log/dockerd.log";
const CONTAINERS: &str = "/var/lib/docker/containers";
/// The first start unpacks Docker onto the data disk; a loaded host slows everything down.
const START_TIMEOUT: Duration = Duration::from_secs(120);

#[derive(Serialize)]
pub struct Started {
    /// False when dockerd was answering already, or was not started (`docker_autostart`).
    pub started: bool,
    pub ms: u64,
    /// Whether dockerd answers now.
    pub running: bool,
    /// For `docker_autostart`: the containers that would come back.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub restartable: Option<usize>,
}

#[derive(Deserialize)]
pub struct StartParams {
    /// dockerd's daemon.json as the host built it: the user's Docker Engine settings under dmx's
    /// own keys. Without it the script writes dmx's keys alone.
    #[serde(default)]
    config: Option<String>,
    /// PEM certificates the Mac trusts beyond Apple's roots, which dockerd trusts too.
    #[serde(default)]
    ca_certificates: Option<String>,
}

/// Starts dockerd unless it answers; with `only_restartable`, only if a container would come
/// back by its restart policy. Concurrent calls wait for the one start.
pub fn start(only_restartable: bool, params: StartParams) -> io::Result<Started> {
    static LOCK: Mutex<()> = Mutex::new(());
    let _held = LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let begun = Instant::now();
    if answers() {
        return Ok(Started { started: false, ms: 0, running: true, restartable: None });
    }
    let mut restartable = None;
    if only_restartable {
        let n = restartable_containers();
        if n == 0 {
            return Ok(Started { started: false, ms: begun.elapsed().as_millis() as u64, running: false, restartable: Some(0) });
        }
        restartable = Some(n);
    }
    std::fs::create_dir_all("/run/dmx")?;
    if let Some(config) = &params.config {
        // Proxy settings may carry credentials.
        let mut file = OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(CONFIG)?;
        file.write_all(config.as_bytes())?;
    }
    match &params.ca_certificates {
        Some(pem) => std::fs::write(HOST_CA, pem)?,
        None => drop(std::fs::remove_file(HOST_CA)),
    }
    let log = match crate::rotating_log::RotatingLog::new(Path::new(LOG), crate::rotating_log::LIMIT) {
        Ok(log) => Some(log),
        Err(error) => {
            eprintln!("dmx-agent: diagnostic logging disabled for {LOG}: {error}");
            None
        }
    };
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
    let collector = match OutputCollector::start(child.stderr.take().unwrap(), log) {
        Ok(collector) => collector,
        Err(error) => {
            unsafe { libc::kill(-(child.id() as i32), libc::SIGKILL); }
            let _ = child.wait();
            return Err(error);
        }
    };
    loop {
        if answers() {
            std::thread::spawn(move || {
                let status = child.wait();
                collector.finish();
                eprintln!("dmx-agent: dockerd exited: {status:?}");
            });
            return Ok(Started { started: true, ms: begun.elapsed().as_millis() as u64, running: true, restartable });
        }
        if let Some(status) = child.try_wait()? {
            let text = collector.finish();
            return Err(io::Error::other(format!("dockerd did not start ({status}): {} (see {LOG})", text.trim())));
        }
        if begun.elapsed() > START_TIMEOUT {
            // A retry must not leave another dockerd and collector alive in the background.
            unsafe { libc::kill(-(child.id() as i32), libc::SIGKILL); }
            let _ = child.wait();
            collector.finish();
            return Err(io::Error::other(format!("dockerd did not answer within {} s (see {LOG})", START_TIMEOUT.as_secs())));
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// The child owns its collector lifetime. A cancellation socket wakes an indefinite poll
/// when the child exits, even if a descendant inherited stderr. No idle timer or polling loop.
struct OutputCollector {
    cancel: UnixStream,
    reader: std::thread::JoinHandle<()>,
    tail: Arc<Mutex<VecDeque<u8>>>,
}

impl OutputCollector {
    fn start(mut stderr: ChildStderr, mut log: Option<crate::rotating_log::RotatingLog>) -> io::Result<Self> {
        let (cancel, stop) = UnixStream::pair()?;
        let fd = stderr.as_raw_fd();
        let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
        if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
            return Err(io::Error::last_os_error());
        }
        let tail = Arc::new(Mutex::new(VecDeque::with_capacity(8192)));
        let saved = tail.clone();
        let reader = std::thread::spawn(move || {
            let mut buffer = [0u8; 8192];
            let mut consume = |bytes: &[u8]| {
                if let Some(log) = log.as_mut() { log.append(bytes); }
                let mut tail = saved.lock().unwrap_or_else(|e| e.into_inner());
                let excess = (tail.len() + bytes.len()).saturating_sub(8192);
                tail.drain(..excess);
                tail.extend(bytes);
            };
            let mut fds = [
                libc::pollfd { fd, events: libc::POLLIN, revents: 0 },
                libc::pollfd { fd: stop.as_raw_fd(), events: libc::POLLIN, revents: 0 },
            ];
            loop {
                if unsafe { libc::poll(fds.as_mut_ptr(), 2, -1) } < 0 {
                    if io::Error::last_os_error().kind() == io::ErrorKind::Interrupted { continue; }
                    break;
                }
                if fds[1].revents != 0 {
                    // Drain only bytes already queued at cancellation. A live descendant
                    // cannot extend this finite budget or keep the log lock alive.
                    let mut available: libc::c_int = 0;
                    unsafe { libc::ioctl(fd, libc::FIONREAD, &mut available); }
                    let mut left = (available.max(0) as usize).min(crate::rotating_log::LIMIT);
                    while left > 0 {
                        let want = left.min(buffer.len());
                        match stderr.read(&mut buffer[..want]) {
                            Ok(0) => break,
                            Ok(n) => { consume(&buffer[..n]); left -= n; }
                            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                            Err(_) => break,
                        }
                    }
                    break;
                }
                match stderr.read(&mut buffer) {
                    Ok(0) => break,
                    Ok(n) => consume(&buffer[..n]),
                    Err(e) if matches!(e.kind(), io::ErrorKind::Interrupted | io::ErrorKind::WouldBlock) => continue,
                    Err(_) => break,
                }
            }
        });
        Ok(Self { cancel, reader, tail })
    }

    fn finish(self) -> String {
        drop(self.cancel);
        let _ = self.reader.join();
        complaint_tail(&self.tail)
    }
}

fn complaint_tail(tail: &Mutex<VecDeque<u8>>) -> String {
    let bytes: Vec<u8> = tail.lock().unwrap_or_else(|e| e.into_inner()).iter().copied().collect();
    String::from_utf8_lossy(&bytes).into_owned()
}

fn answers() -> bool {
    UnixStream::connect(SOCKET).is_ok()
}

/// Containers dockerd would start again when it starts, as its restart manager decides, but
/// leaving out those stopped with `docker stop`: an `always` container the user stopped comes
/// back when dockerd next starts, but does not by itself bring Docker up at boot. Read from
/// dockerd's own records, which it writes on every state change.
fn restartable_containers() -> usize {
    let Ok(dirs) = std::fs::read_dir(CONTAINERS) else { return 0 };
    let read = |path: std::path::PathBuf| -> Option<Value> { serde_json::from_slice(&std::fs::read(path).ok()?).ok() };
    dirs.flatten()
        .filter(|dir| {
            let (Some(host), Some(state)) = (read(dir.path().join("hostconfig.json")), read(dir.path().join("config.v2.json"))) else {
                return false;
            };
            let policy = host["RestartPolicy"]["Name"].as_str().unwrap_or("");
            let stopped_by_user = state["HasBeenManuallyStopped"].as_bool().unwrap_or(false);
            let started_before = state["HasBeenStartedBefore"].as_bool().unwrap_or(false);
            let failed = state["State"]["ExitCode"].as_i64().unwrap_or(0) != 0;
            started_before
                && !stopped_by_user
                && match policy {
                    "always" | "unless-stopped" => true,
                    "on-failure" => failed,
                    _ => false,
                }
        })
        .count()
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

#[cfg(test)]
mod output_tests {
    use super::*;

    #[test]
    fn inherited_stderr_cannot_hold_the_log_lock_after_child_exit() {
        let dir = std::env::temp_dir().join(format!("dmx-collector-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("dockerd.log");
        let log = crate::rotating_log::RotatingLog::new(&path, 64).unwrap();
        let mut child = Command::new("sh").args(["-c", "sleep 3 & echo COLLECTOR-TAIL >&2; exit 23"])
            .stdout(Stdio::null()).stderr(Stdio::piped()).spawn().unwrap();
        let collector = OutputCollector::start(child.stderr.take().unwrap(), Some(log)).unwrap();
        assert_eq!(child.wait().unwrap().code(), Some(23));
        let started = Instant::now();
        let tail = collector.finish();
        assert!(started.elapsed() < Duration::from_secs(1));
        assert!(tail.contains("COLLECTOR-TAIL"));
        assert!(crate::rotating_log::RotatingLog::new(&path, 64).is_ok());
        std::fs::remove_dir_all(dir).unwrap();
    }
}
