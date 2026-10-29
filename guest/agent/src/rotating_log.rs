//! A bounded diagnostic file, owned by one collector. No queue of output in memory.
use std::fs::{File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

pub const LIMIT: usize = 1 << 20;

pub struct RotatingLog {
    path: PathBuf,
    limit: usize,
    file: Option<File>,
    size: usize,
    _lock: File,
}

impl RotatingLog {
    pub fn new(path: &Path, limit: usize) -> io::Result<Self> {
        assert!(limit > 0);
        std::fs::create_dir_all(path.parent().unwrap())?;
        let lock = open(&suffix(path, ".lock"), true)?.unwrap();
        // A crashed child's reaper may still be draining its finite queued output.
        // Give that owner time to release the file; never wait indefinitely on a live owner.
        let deadline = Instant::now() + Duration::from_secs(1);
        loop {
            if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 { break; }
            let error = io::Error::last_os_error();
            if error.kind() != io::ErrorKind::WouldBlock || Instant::now() >= deadline { return Err(error); }
            std::thread::sleep(Duration::from_millis(5));
        }
        for end in [".2", ".1", ""] {
            if let Some(mut file) = open(&suffix(path, end), end.is_empty())? {
                let size = file.metadata()?.len();
                if size > limit as u64 {
                    file.seek(SeekFrom::End(-(limit as i64)))?;
                    let mut tail = vec![0; limit];
                    file.read_exact(&mut tail)?;
                    file.set_len(0)?;
                    file.seek(SeekFrom::Start(0))?;
                    file.write_all(&tail)?;
                }
            }
        }
        let mut log = Self { path: path.to_owned(), limit, file: None, size: 0, _lock: lock };
        log.reopen()?;
        Ok(log)
    }

    pub fn append(&mut self, bytes: &[u8]) {
        if self.write(bytes).is_err() {
            // Disk full or permissions changed: drop output, retry next chunk, never queue it.
            self.file = None;
        }
    }

    fn write(&mut self, mut bytes: &[u8]) -> io::Result<()> {
        if self.file.is_none() { self.reopen()?; }
        while !bytes.is_empty() {
            if self.size >= self.limit { self.rotate()?; }
            let n = bytes.len().min(self.limit - self.size);
            self.file.as_mut().unwrap().write_all(&bytes[..n])?;
            self.size += n;
            bytes = &bytes[n..];
        }
        Ok(())
    }

    fn reopen(&mut self) -> io::Result<()> {
        let mut file = open(&self.path, true)?.unwrap();
        self.size = file.metadata()?.len().try_into().unwrap_or(usize::MAX);
        file.seek(SeekFrom::End(0))?;
        self.file = Some(file);
        if self.size > self.limit { self.rotate()?; }
        Ok(())
    }

    fn rotate(&mut self) -> io::Result<()> {
        self.file = None;
        match std::fs::remove_file(suffix(&self.path, ".2")) {
            Ok(()) => {}, Err(e) if e.kind() == io::ErrorKind::NotFound => {}, Err(e) => return Err(e),
        }
        match std::fs::rename(suffix(&self.path, ".1"), suffix(&self.path, ".2")) {
            Ok(()) => {}, Err(e) if e.kind() == io::ErrorKind::NotFound => {}, Err(e) => return Err(e),
        }
        std::fs::rename(&self.path, suffix(&self.path, ".1"))?;
        self.reopen()
    }
}

fn suffix(path: &Path, end: &str) -> PathBuf {
    let mut name = path.as_os_str().to_owned();
    name.push(end);
    PathBuf::from(name)
}

fn open(path: &Path, create: bool) -> io::Result<Option<File>> {
    let file = match OpenOptions::new().read(true).write(true).create(create).mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC).open(path) {
        Ok(f) => f,
        Err(e) if !create && e.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(e),
    };
    let info = file.metadata()?;
    if !info.is_file() || info.nlink() != 1 {
        return Err(io::Error::other("log must be a regular file with one link"));
    }
    Ok(Some(file))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn retains_tail_with_fixed_disk_budget() {
        let dir = std::env::temp_dir().join(format!("dmx-log-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("dockerd.log");
        let old: Vec<u8> = (0..200).map(|i| i as u8).collect();
        for s in ["", ".1", ".2"] { std::fs::write(suffix(&path, s), &old).unwrap(); }
        let mut log = RotatingLog::new(&path, 64).unwrap();
        for s in ["", ".1", ".2"] { assert_eq!(std::fs::read(suffix(&path, s)).unwrap(), old[136..]); }
        let bytes: Vec<u8> = (0..251).map(|i| i as u8).collect();
        log.append(&bytes);
        drop(log);
        let retained: Vec<u8> = [".2", ".1", ""].into_iter().flat_map(|s| {
            let bytes = std::fs::read(suffix(&path, s)).unwrap();
            assert!(bytes.len() <= 64);
            bytes
        }).collect();
        assert!(retained.ends_with(&bytes[bytes.len()-128..]));
        // A log planted as a symlink/hard link must not change the target.
        std::fs::remove_file(&path).unwrap();
        let target = dir.join("keep");
        std::fs::write(&target, b"preserve").unwrap();
        std::os::unix::fs::symlink(&target, &path).unwrap();
        assert!(RotatingLog::new(&path, 64).is_err());
        std::fs::remove_file(&path).unwrap();
        std::fs::hard_link(&target, &path).unwrap();
        assert!(RotatingLog::new(&path, 64).is_err());
        assert_eq!(std::fs::read(&target).unwrap(), b"preserve");
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn rotation_error_drops_bytes_then_recovers() {
        let dir = std::env::temp_dir().join(format!("dmx-retry-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("dockerd.log");
        let mut log = RotatingLog::new(&path, 64).unwrap();
        log.append(&[b'a'; 64]);
        // Even root cannot unlink a directory with remove_file; deterministic I/O failure.
        std::fs::create_dir(suffix(&path, ".2")).unwrap();
        log.append(&[b'b'; 1000]);
        assert_eq!(std::fs::read(&path).unwrap(), &[b'a'; 64]);
        std::fs::remove_dir(suffix(&path, ".2")).unwrap();
        log.append(b"RECOVERED");
        assert_eq!(std::fs::read(&path).unwrap(), b"RECOVERED");
        drop(log);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn contended_lock_waits_for_previous_owner_with_a_deadline() {
        let dir = std::env::temp_dir().join(format!("dmx-lock-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("dockerd.log");
        let held = RotatingLog::new(&path, 64).unwrap();
        let started = Instant::now();
        assert!(RotatingLog::new(&path, 64).is_err());
        assert!(started.elapsed() >= Duration::from_secs(1));
        assert!(started.elapsed() < Duration::from_secs(3));
        let release = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(80));
            drop(held);
        });
        let mut replacement = RotatingLog::new(&path, 64).unwrap();
        replacement.append(b"NEW-OWNER");
        assert_eq!(std::fs::read(&path).unwrap(), b"NEW-OWNER");
        release.join().unwrap();
        drop(replacement);
        std::fs::remove_dir_all(dir).unwrap();
    }

}
