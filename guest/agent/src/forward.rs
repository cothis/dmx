//! `connect`: open a TCP connection in the guest for a host port forward. After the `ok` reply
//! the vsock connection carries the TCP stream's raw bytes both ways, with no framing.

use crate::vsock::Stream;
use serde::Deserialize;
use std::io::{Read, Write};
use std::net::{IpAddr, Ipv4Addr, Shutdown, SocketAddr, TcpStream};
use std::sync::{Arc, Mutex};
use std::time::Duration;

#[derive(Deserialize)]
pub struct Params {
    pub port: u16,
    /// The address to connect to; loopback by default, where the forwarded service listens.
    pub host: Option<IpAddr>,
}

/// A refused or unreachable port fails at once; this only bounds a target that drops SYNs.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
/// Copy buffer, on the stack. Guest memory a burst of connections touches mostly stays with the
/// guest kernel in blocks too small for free page reporting, so each connection keeps it small.
const BUF: usize = 32 << 10;
/// Stack of the second copying thread: the buffer plus a little (the default is 2 MiB).
const STACK: usize = BUF + (64 << 10);

pub fn run(id: u64, p: Params, conn: Stream, out: Arc<Mutex<Stream>>) {
    let addr = SocketAddr::new(p.host.unwrap_or(IpAddr::V4(Ipv4Addr::LOCALHOST)), p.port);
    let tcp = match TcpStream::connect_timeout(&addr, CONNECT_TIMEOUT) {
        Ok(t) => t,
        Err(e) => return crate::reply_err(&out, id, "connect_failed", format!("connect {addr}: {e}")),
    };
    let _ = tcp.set_nodelay(true);
    crate::reply_ok(&out, id, serde_json::json!({}));
    drop(out);

    // Two descriptors per connection: both directions share the sockets instead of duplicating them.
    // End of stream on one side becomes a half close on the other; an error ends both sides.
    let (conn, tcp) = (Arc::new(conn), Arc::new(tcp));
    let up = {
        let (conn, tcp) = (conn.clone(), tcp.clone());
        std::thread::Builder::new().stack_size(STACK).spawn(move || {
            let ok = copy(&*conn, &*tcp);
            let _ = tcp.shutdown(if ok { Shutdown::Write } else { Shutdown::Both });
            ok
        })
    };
    let Ok(up) = up else {
        conn.shutdown();
        let _ = tcp.shutdown(Shutdown::Both);
        return;
    };
    if copy(&*tcp, &*conn) {
        conn.shutdown_write();
    } else {
        conn.shutdown();
        let _ = tcp.shutdown(Shutdown::Both);
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
