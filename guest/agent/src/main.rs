//! dmx-agent: runs inside the dmx VM and answers the host over vsock.

mod exec;
mod forward;
mod frame;
mod sys;
mod vsock;

use serde::Deserialize;
use serde_json::{json, Value};
use std::io;
use std::sync::{Arc, Mutex};

const VERSION: &str = env!("CARGO_PKG_VERSION");
/// Bumped on incompatible changes to docs/agent-protocol.md.
const PROTOCOL: u32 = 1;
const PORT: u32 = 1024;

#[derive(Deserialize)]
struct Request {
    id: u64,
    method: String,
    #[serde(default)]
    params: Value,
}

fn main() {
    if std::env::args().nth(1).as_deref() == Some("--version") {
        println!("dmx-agent {VERSION}");
        return;
    }
    forward::raise_fd_limit();
    let listener = match vsock::Listener::bind(PORT) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("dmx-agent: listen on vsock port {PORT}: {e}");
            std::process::exit(1);
        }
    };
    loop {
        match listener.accept() {
            Ok(conn) => {
                std::thread::spawn(move || serve(conn));
            }
            Err(e) => {
                eprintln!("dmx-agent: accept: {e}");
                std::thread::sleep(std::time::Duration::from_millis(100));
            }
        }
    }
}

/// Answers requests in order until the host closes the connection or an `exec` takes it over.
fn serve(conn: vsock::Stream) {
    let Ok(w) = conn.try_clone() else { return };
    let out = Arc::new(Mutex::new(w));
    let mut conn = conn;
    while let Ok(Some(f)) = frame::read(&mut conn) {
        if f.kind != frame::JSON {
            reply_err(&out, 0, "bad_request", format!("unexpected frame kind {}", f.kind));
            continue;
        }
        let req: Request = match serde_json::from_slice(&f.payload) {
            Ok(r) => r,
            Err(e) => {
                reply_err(&out, 0, "bad_request", e.to_string());
                continue;
            }
        };
        let id = req.id;
        match req.method.as_str() {
            "exec" => {
                match serde_json::from_value(req.params) {
                    Ok(p) => {
                        let keep = conn.try_clone();
                        exec::run(id, p, conn, out);
                        if let Ok(c) = keep {
                            c.shutdown();
                        }
                    }
                    Err(e) => reply_err(&out, id, "bad_request", e.to_string()),
                }
                return;
            }
            "connect" => {
                match serde_json::from_value(req.params) {
                    Ok(p) => forward::run(id, p, conn, out),
                    Err(e) => reply_err(&out, id, "bad_request", e.to_string()),
                }
                return;
            }
            "shutdown" => {
                reply_ok(&out, id, json!({}));
                let e = sys::power_off();
                eprintln!("dmx-agent: power off: {e}");
            }
            _ => match dispatch(&req.method, req.params) {
                Ok(v) => reply_ok(&out, id, v),
                Err((code, message)) => reply_err(&out, id, code, message),
            },
        }
    }
    conn.shutdown();
}

type Failure = (&'static str, String);

fn dispatch(method: &str, params: Value) -> Result<Value, Failure> {
    fn params_of<T: for<'de> Deserialize<'de>>(v: Value) -> Result<T, Failure> {
        let v = if v.is_null() { json!({}) } else { v };
        serde_json::from_value(v).map_err(|e| ("bad_request", e.to_string()))
    }
    fn io(e: io::Error) -> Failure {
        let code = if e.kind() == io::ErrorKind::InvalidInput { "bad_request" } else { "io_error" };
        (code, e.to_string())
    }
    fn to_value(v: impl serde::Serialize) -> Result<Value, Failure> {
        serde_json::to_value(v).map_err(|e| ("internal", e.to_string()))
    }
    match method {
        "hello" => Ok(json!({
            "agent": "dmx-agent",
            "version": VERSION,
            "protocol": PROTOCOL,
            "kernel": sys::kernel_release(),
        })),
        "stats" => to_value(sys::stats().map_err(io)?),
        "drop_caches" => to_value(sys::drop_caches(params_of(params)?).map_err(io)?),
        "reclaim" => to_value(sys::reclaim(params_of(params)?).map_err(io)?),
        "swap_on" => to_value(sys::swap_on().map_err(io)?),
        "time_sync" => to_value(sys::time_sync(params_of(params)?).map_err(io)?),
        _ => Err(("unknown_method", format!("unknown method {method:?}"))),
    }
}

fn send(out: &Mutex<vsock::Stream>, msg: Value) {
    let _ = frame::write(&mut *out.lock().unwrap(), frame::JSON, msg.to_string().as_bytes());
}

pub fn reply_ok(out: &Mutex<vsock::Stream>, id: u64, result: Value) {
    send(out, json!({ "id": id, "ok": true, "result": result }));
}

pub fn reply_err(out: &Mutex<vsock::Stream>, id: u64, code: &str, message: String) {
    send(out, json!({ "id": id, "ok": false, "error": { "code": code, "message": message } }));
}
