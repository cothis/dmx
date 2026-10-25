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
use std::process::{Command, Stdio};
use std::sync::Mutex;
use std::time::{Duration, Instant};

const SCRIPT: &str = "/sbin/dmx-docker";
pub const SOCKET: &str = "/var/run/docker.sock";
const PIDFILE: &str = "/var/run/docker.pid";
const CONFIG: &str = "/run/dmx/daemon.json";
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
    if let Some(config) = &params.config {
        std::fs::create_dir_all("/run/dmx")?;
        // Proxy settings may carry credentials.
        let mut file = OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(CONFIG)?;
        file.write_all(config.as_bytes())?;
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
            return Ok(Started { started: true, ms: begun.elapsed().as_millis() as u64, running: true, restartable });
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
