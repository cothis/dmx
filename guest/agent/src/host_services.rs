//! Services on the Mac, offered in the guest as Unix sockets under /run/host-services like in
//! Docker Desktop's VM: each connection becomes a vsock stream to the host port of that service.
//! Containers reach one by bind mounting it (`-v /run/host-services/ssh-auth.sock:...`); dockerd's
//! mount namespace shares the guest's /run.

use crate::forward::{self, Target};
use crate::vsock::Stream;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};

const DIR: &str = "/run/host-services";
/// Socket name and host vsock port (HostServices.swift).
const SERVICES: [(&str, u32); 1] = [("ssh-auth.sock", 1025)];

/// Listens on every service socket, each on a thread of its own. A socket left by an agent that
/// died is replaced.
pub fn start() {
    if let Err(e) = std::fs::create_dir_all(DIR) {
        return eprintln!("dmx-agent: {DIR}: {e}");
    }
    for (name, port) in SERVICES {
        let path = format!("{DIR}/{name}");
        let _ = std::fs::remove_file(&path);
        let listener = match UnixListener::bind(&path) {
            Ok(l) => l,
            Err(e) => {
                eprintln!("dmx-agent: listen on {path}: {e}");
                continue;
            }
        };
        // Any user: containers run as all kinds of users, and only those given the socket see it.
        let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o666));
        let spawned = std::thread::Builder::new().stack_size(forward::STACK).spawn(move || {
            for client in listener.incoming().flatten() {
                let _ = std::thread::Builder::new().stack_size(forward::STACK).spawn(move || relay(client, port));
            }
        });
        if let Err(e) = spawned {
            eprintln!("dmx-agent: {path}: {e}");
        }
    }
}

/// Joins a client to the host service. If the host refuses (nothing there), the client reads end
/// of stream.
fn relay(client: UnixStream, port: u32) {
    match Stream::connect_host(port) {
        Ok(host) => forward::join(host, Target::Unix(client)),
        Err(e) => eprintln!("dmx-agent: host service on vsock port {port}: {e}"),
    }
}
