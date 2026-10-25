//! `connect`: open a TCP connection or a Unix socket connection in the guest, for a host port
//! forward or the Docker socket. After the `ok` reply the vsock connection carries the stream's
//! raw bytes both ways, with no framing. With `udp`, it carries datagrams to and from a UDP port
//! instead, each framed as a big-endian u16 length and the bytes.

use crate::vsock::Stream;
use serde::Deserialize;
use std::io::{self, Read, Write};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, Shutdown, SocketAddr, TcpStream, UdpSocket};
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicBool, Ordering};
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
    /// `port` is a UDP port: the stream carries framed datagrams (see `run_udp`).
    #[serde(default)]
    pub udp: bool,
}

/// The guest end of a forwarded connection.
pub enum Target {
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
pub const STACK: usize = BUF + (64 << 10);
/// The largest UDP payload over IPv4.
const DATAGRAM: usize = 65507;

pub fn run(id: u64, p: Params, conn: Stream, out: Arc<Mutex<Stream>>) {
    if p.udp {
        return run_udp(id, p, conn, out);
    }
    let target = match open(&p) {
        Ok(t) => t,
        Err(e) if p.path.is_some() == p.port.is_some() => return crate::reply_err(&out, id, "bad_request", e),
        Err(e) => return crate::reply_err(&out, id, "connect_failed", e),
    };
    crate::reply_ok(&out, id, serde_json::json!({}));
    drop(out);
    join(conn, target);
}

/// Copies both ways between a vsock stream and its guest end until both directions are done.
pub fn join(conn: Stream, target: Target) {
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

/// One host peer's datagrams to a guest UDP port, and the replies, for a forwarded UDP port. The
/// host keeps one stream per peer and closes it after a quiet minute. The UDP socket here is
/// connected to the target, so only its replies come back. Nothing is retried: a datagram the
/// target refuses is lost, as on a network.
fn run_udp(id: u64, p: Params, conn: Stream, out: Arc<Mutex<Stream>>) {
    let Some(port) = p.port.filter(|_| p.path.is_none()) else {
        return crate::reply_err(&out, id, "bad_request", "udp needs a port and no path".into());
    };
    let addr = SocketAddr::new(p.host.unwrap_or(IpAddr::V4(Ipv4Addr::LOCALHOST)), port);
    let any = if addr.is_ipv4() { IpAddr::V4(Ipv4Addr::UNSPECIFIED) } else { IpAddr::V6(Ipv6Addr::UNSPECIFIED) };
    let socket = match UdpSocket::bind(SocketAddr::new(any, 0)).and_then(|s| s.connect(addr).map(|_| s)) {
        Ok(s) => s,
        Err(e) => return crate::reply_err(&out, id, "connect_failed", format!("udp {addr}: {e}")),
    };
    crate::reply_ok(&out, id, serde_json::json!({}));
    drop(out);

    let (conn, socket) = (Arc::new(conn), Arc::new(socket));
    let closed = Arc::new(AtomicBool::new(false));
    let up = {
        let (conn, socket, closed) = (conn.clone(), socket.clone(), closed.clone());
        std::thread::Builder::new().stack_size(STACK).spawn(move || {
            let mut buf = vec![0u8; DATAGRAM];
            let mut from = &*conn;
            let mut len = [0u8; 2];
            while from.read_exact(&mut len).is_ok() {
                let n = (u16::from_be_bytes(len) as usize).min(DATAGRAM);
                if from.read_exact(&mut buf[..n]).is_err() {
                    break;
                }
                // Refused (nothing listens yet) or no buffer space: dropped, like on a network.
                let _ = socket.send(&buf[..n]);
            }
            // Wakes the receiving loop: recv returns 0 once the socket is shut down.
            closed.store(true, Ordering::SeqCst);
            unsafe { libc::shutdown(socket.as_raw_fd(), libc::SHUT_RDWR) };
        })
    };
    let Ok(up) = up else {
        conn.shutdown();
        return;
    };
    let mut buf = vec![0u8; 2 + DATAGRAM];
    loop {
        match socket.recv(&mut buf[2..]) {
            Ok(0) if closed.load(Ordering::SeqCst) => break,
            Ok(n) => {
                buf[..2].copy_from_slice(&(n as u16).to_be_bytes());
                if (&*conn).write_all(&buf[..2 + n]).is_err() {
                    break;
                }
            }
            // ICMP port unreachable for an earlier datagram, reported here.
            Err(e) if e.kind() == io::ErrorKind::ConnectionRefused || e.kind() == io::ErrorKind::Interrupted => {}
            Err(_) => break,
        }
    }
    conn.shutdown();
    let _ = up.join();
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
