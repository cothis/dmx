//! Calls that read or change guest state: stats, caches, clock, power.

use serde::{Deserialize, Serialize};
use std::{fs, io, path::Path};

/// Runs a libc call until it is not interrupted by a signal.
pub fn retry(mut f: impl FnMut() -> isize) -> io::Result<usize> {
    loop {
        let n = f();
        if n >= 0 {
            return Ok(n as usize);
        }
        let err = io::Error::last_os_error();
        if err.kind() != io::ErrorKind::Interrupted {
            return Err(err);
        }
    }
}

/// Values from /proc/meminfo, in bytes.
#[derive(Serialize, Default)]
pub struct Memory {
    pub total: u64,
    pub free: u64,
    pub available: u64,
    pub buffers: u64,
    pub cached: u64,
    pub shmem: u64,
    pub swap_total: u64,
    pub swap_free: u64,
    /// Pages held by the balloon driver, i.e. handed back to the host.
    pub balloon: u64,
}

#[derive(Serialize)]
pub struct Cgroup {
    pub path: String,
    pub memory_current: u64,
}

#[derive(Serialize)]
pub struct Stats {
    pub memory: Memory,
    pub uptime_s: f64,
    pub load: [f64; 3],
    pub cgroups: Vec<Cgroup>,
}

pub fn memory() -> io::Result<Memory> {
    let mut m = Memory::default();
    for line in fs::read_to_string("/proc/meminfo")?.lines() {
        let mut it = line.split_whitespace();
        let (Some(key), Some(kb)) = (it.next(), it.next().and_then(|v| v.parse::<u64>().ok())) else { continue };
        let slot = match key {
            "MemTotal:" => &mut m.total,
            "MemFree:" => &mut m.free,
            "MemAvailable:" => &mut m.available,
            "Buffers:" => &mut m.buffers,
            "Cached:" => &mut m.cached,
            "Shmem:" => &mut m.shmem,
            "SwapTotal:" => &mut m.swap_total,
            "SwapFree:" => &mut m.swap_free,
            "Balloon:" => &mut m.balloon,
            _ => continue,
        };
        *slot = kb * 1024;
    }
    Ok(m)
}

pub fn stats() -> io::Result<Stats> {
    let uptime = fs::read_to_string("/proc/uptime")?;
    let loadavg = fs::read_to_string("/proc/loadavg")?;
    let mut load = [0.0; 3];
    for (slot, v) in load.iter_mut().zip(loadavg.split_whitespace()) {
        *slot = v.parse().unwrap_or(0.0);
    }
    let mut cgroups = Vec::new();
    walk_cgroups(Path::new("/sys/fs/cgroup"), &mut cgroups);
    Ok(Stats {
        memory: memory()?,
        uptime_s: uptime.split_whitespace().next().and_then(|v| v.parse().ok()).unwrap_or(0.0),
        load,
        cgroups,
    })
}

/// Every cgroup below the root that has the memory controller enabled.
fn walk_cgroups(dir: &Path, out: &mut Vec<Cgroup>) {
    let Ok(entries) = fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        if !entry.file_type().is_ok_and(|t| t.is_dir()) {
            continue;
        }
        if let Some(current) = fs::read_to_string(path.join("memory.current")).ok().and_then(|v| v.trim().parse().ok()) {
            let rel = path.strip_prefix("/sys/fs/cgroup").unwrap_or(&path);
            out.push(Cgroup { path: format!("/{}", rel.display()), memory_current: current });
        }
        walk_cgroups(&path, out);
    }
}

#[derive(Deserialize)]
pub struct DropCachesParams {
    /// 1: page cache, 2: dentries and inodes, 3: both (the default).
    #[serde(default = "three")]
    pub level: u8,
}

fn three() -> u8 {
    3
}

#[derive(Serialize)]
pub struct DropCachesResult {
    pub available_before: u64,
    pub available_after: u64,
}

pub fn drop_caches(p: DropCachesParams) -> io::Result<DropCachesResult> {
    if !(1..=3).contains(&p.level) {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "level must be 1, 2 or 3"));
    }
    let before = memory()?.available;
    unsafe { libc::sync() };
    fs::write("/proc/sys/vm/drop_caches", p.level.to_string())?;
    Ok(DropCachesResult { available_before: before, available_after: memory()?.available })
}

#[derive(Deserialize)]
pub struct TimeSyncParams {
    pub unix_ns: i128,
}

#[derive(Serialize)]
pub struct TimeSyncResult {
    /// Guest clock minus host clock before the change.
    pub offset_ns: i128,
}

pub fn time_sync(p: TimeSyncParams) -> io::Result<TimeSyncResult> {
    let mut now = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    unsafe { libc::clock_gettime(libc::CLOCK_REALTIME, &mut now) };
    let guest = now.tv_sec as i128 * 1_000_000_000 + now.tv_nsec as i128;
    let set = libc::timespec {
        tv_sec: p.unix_ns.div_euclid(1_000_000_000) as _,
        tv_nsec: p.unix_ns.rem_euclid(1_000_000_000) as _,
    };
    if unsafe { libc::clock_settime(libc::CLOCK_REALTIME, &set) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(TimeSyncResult { offset_ns: guest - p.unix_ns })
}

/// Flushes filesystems and powers the VM off. Does not return on success.
pub fn power_off() -> io::Error {
    unsafe {
        libc::sync();
        libc::reboot(libc::RB_POWER_OFF);
    }
    io::Error::last_os_error()
}

pub fn kernel_release() -> String {
    fs::read_to_string("/proc/sys/kernel/osrelease").map(|s| s.trim().to_string()).unwrap_or_default()
}
