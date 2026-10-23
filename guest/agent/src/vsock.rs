//! AF_VSOCK listener. std has no vsock support, so this wraps the raw fd.

use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};

pub struct Listener(OwnedFd);

impl Listener {
    pub fn bind(port: u32) -> io::Result<Self> {
        unsafe {
            let fd = libc::socket(libc::AF_VSOCK, libc::SOCK_STREAM | libc::SOCK_CLOEXEC, 0);
            if fd < 0 {
                return Err(io::Error::last_os_error());
            }
            let fd = OwnedFd::from_raw_fd(fd);
            let mut addr: libc::sockaddr_vm = std::mem::zeroed();
            addr.svm_family = libc::AF_VSOCK as libc::sa_family_t;
            addr.svm_port = port;
            addr.svm_cid = libc::VMADDR_CID_ANY;
            let len = std::mem::size_of::<libc::sockaddr_vm>() as libc::socklen_t;
            if libc::bind(fd.as_raw_fd(), &addr as *const _ as *const libc::sockaddr, len) < 0
                || libc::listen(fd.as_raw_fd(), 16) < 0
            {
                return Err(io::Error::last_os_error());
            }
            Ok(Listener(fd))
        }
    }

    pub fn accept(&self) -> io::Result<Stream> {
        loop {
            let fd = unsafe {
                libc::accept4(self.0.as_raw_fd(), std::ptr::null_mut(), std::ptr::null_mut(), libc::SOCK_CLOEXEC)
            };
            if fd >= 0 {
                return Ok(Stream(unsafe { OwnedFd::from_raw_fd(fd) }));
            }
            let err = io::Error::last_os_error();
            if err.kind() != io::ErrorKind::Interrupted {
                return Err(err);
            }
        }
    }
}

pub struct Stream(OwnedFd);

impl Stream {
    pub fn try_clone(&self) -> io::Result<Self> {
        Ok(Stream(self.0.try_clone()?))
    }

    /// Ends both directions so a thread blocked reading this connection wakes up.
    pub fn shutdown(&self) {
        unsafe { libc::shutdown(self.0.as_raw_fd(), libc::SHUT_RDWR) };
    }
}

impl Read for Stream {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        crate::sys::retry(|| unsafe { libc::read(self.0.as_raw_fd(), buf.as_mut_ptr().cast(), buf.len()) })
    }
}

impl Write for Stream {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        crate::sys::retry(|| unsafe { libc::write(self.0.as_raw_fd(), buf.as_ptr().cast(), buf.len()) })
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}
