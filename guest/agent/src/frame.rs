//! Wire format: every frame is a u32 big-endian length, then one kind byte, then the payload.
//! The length counts the kind byte and the payload. See docs/agent-protocol.md.

use std::io::{self, Read, Write};

pub const JSON: u8 = 0;
pub const STDIN: u8 = 1;
pub const STDOUT: u8 = 2;
pub const STDERR: u8 = 3;

/// Larger frames are a protocol error; data streams are sent in chunks well below this.
pub const MAX_FRAME: usize = 16 << 20;

pub struct Frame {
    pub kind: u8,
    pub payload: Vec<u8>,
}

/// Returns None on a clean end of stream between frames.
pub fn read(r: &mut impl Read) -> io::Result<Option<Frame>> {
    let mut len = [0u8; 4];
    match r.read_exact(&mut len) {
        Ok(()) => {}
        Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(e) => return Err(e),
    }
    let len = u32::from_be_bytes(len) as usize;
    if len == 0 || len > MAX_FRAME {
        return Err(io::Error::new(io::ErrorKind::InvalidData, format!("bad frame length {len}")));
    }
    let mut buf = vec![0u8; len];
    r.read_exact(&mut buf)?;
    let kind = buf.remove(0);
    Ok(Some(Frame { kind, payload: buf }))
}

pub fn write(w: &mut impl Write, kind: u8, payload: &[u8]) -> io::Result<()> {
    let mut buf = Vec::with_capacity(5 + payload.len());
    buf.extend_from_slice(&(payload.len() as u32 + 1).to_be_bytes());
    buf.push(kind);
    buf.extend_from_slice(payload);
    w.write_all(&buf)
}
