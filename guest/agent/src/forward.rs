//! `connect`: open a TCP connection or a Unix socket connection in the guest, for a host port
//! forward or the Docker socket. After the `ok` reply the vsock connection carries the stream's
//! raw bytes both ways, with no framing.

use crate::vsock::Stream;
use serde::Deserialize;
use std::io::{self, Read, Write};
use std::net::{IpAddr, Ipv4Addr, Shutdown, SocketAddr, TcpStream};
use std::os::unix::net::UnixStream;
use std::sync::{Arc, Mutex};
use std::time::Duration;

#[derive(Deserialize)]
pub struct Params {
    /// A TCP port, or else `path`.
    pub port: Option<u16>,
    /// The address to connect to; loopback by default, where the forwarded service listens.
    pub host: Option<IpAddr>,
    /// A Unix socket to connect to instead of a TCP port.
    pub path: Option<String>,
}

/// The guest end of a forwarded connection.
enum Target {
    Tcp(TcpStream),
    Unix(UnixStream),
}

impl Target {
    fn shutdown(&self, how: Shutdown) {
        let _ = match self {
            Target::Tcp(s) => s.shutdown(how),
            Target::Unix(s) => s.shutdown(how),
        };
    }
}

impl Read for &Target {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        match *self {
            Target::Tcp(s) => (&*s).read(buf),
            Target::Unix(s) => (&*s).read(buf),
        }
    }
}

impl Write for &Target {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        match *self {
            Target::Tcp(s) => (&*s).write(buf),
            Target::Unix(s) => (&*s).write(buf),
        }
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

fn open(p: &Params) -> Result<Target, String> {
    match (&p.path, p.port) {
        (Some(path), None) => UnixStream::connect(path).map(Target::Unix).map_err(|e| format!("connect {path}: {e}")),
        (None, Some(port)) => {
            let addr = SocketAddr::new(p.host.unwrap_or(IpAddr::V4(Ipv4Addr::LOCALHOST)), port);
            let tcp = TcpStream::connect_timeout(&addr, CONNECT_TIMEOUT).map_err(|e| format!("connect {addr}: {e}"))?;
            let _ = tcp.set_nodelay(true);
            Ok(Target::Tcp(tcp))
        }
        _ => Err("give either port or path".into()),
    }
}

/// A refused or unreachable port fails at once; this only bounds a target that drops SYNs.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
/// Copy buffer, on the stack. Guest memory a burst of connections touches mostly stays with the
/// guest kernel in blocks too small for free page reporting, so each connection keeps it small.
const BUF: usize = 32 << 10;
/// Stack of the second copying thread: the buffer plus a little (the default is 2 MiB).
const STACK: usize = BUF + (64 << 10);

pub fn run(id: u64, p: Params, conn: Stream, out: Arc<Mutex<Stream>>) {
    let target = match open(&p) {
        Ok(t) => t,
        Err(e) if p.path.is_some() == p.port.is_some() => return crate::reply_err(&out, id, "bad_request", e),
        Err(e) => return crate::reply_err(&out, id, "connect_failed", e),
    };
    crate::reply_ok(&out, id, serde_json::json!({}));
    drop(out);

    // Two descriptors per connection: both directions share the sockets instead of duplicating them.
    // End of stream on one side becomes a half close on the other; an error ends both sides.
    let (conn, target) = (Arc::new(conn), Arc::new(target));
    let up = {
        let (conn, target) = (conn.clone(), target.clone());
        std::thread::Builder::new().stack_size(STACK).spawn(move || {
            let ok = copy(&*conn, &*target);
            target.shutdown(if ok { Shutdown::Write } else { Shutdown::Both });
            ok
        })
    };
    let Ok(up) = up else {
        conn.shutdown();
        target.shutdown(Shutdown::Both);
        return;
    };
    if copy(&*target, &*conn) {
        conn.shutdown_write();
    } else {
        conn.shutdown();
        target.shutdown(Shutdown::Both);
    }
    if !up.join().unwrap_or(false) {
        conn.shutdown();
    }
}

/// Each forwarded connection holds two descriptors in the agent; the guest's default soft limit of
/// 1024 would cap forwards at ~500 connections. Raise it to the hard limit (4096 for /init's
/// children); processes the agent starts inherit it.
pub fn raise_fd_limit() {
    let mut lim = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
    unsafe {
        if libc::getrlimit(libc::RLIMIT_NOFILE, &mut lim) == 0 && lim.rlim_cur < lim.rlim_max {
            lim.rlim_cur = lim.rlim_max;
            libc::setrlimit(libc::RLIMIT_NOFILE, &lim);
        }
    }
}

/// Copies until end of stream (true) or an error on either side (false). Blocking writes are the
/// backpressure: a slow reader stops us reading, and the sender then waits on TCP or vsock credit.
fn copy(mut from: impl Read, mut to: impl Write) -> bool {
    let mut buf = [0u8; BUF];
    loop {
        match from.read(&mut buf) {
            Ok(0) => return true,
            Ok(n) => {
                if to.write_all(&buf[..n]).is_err() {
                    return false;
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
            Err(_) => return false,
        }
    }
}
