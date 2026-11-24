#[cfg(unix)]
use std::io::{ErrorKind, Read, Write};
#[cfg(unix)]
use std::os::unix::io::AsRawFd;
#[cfg(unix)]
use std::os::unix::net::UnixStream;

#[cfg(unix)]
pub(crate) struct WakeSender(pub(crate) UnixStream);

#[cfg(unix)]
impl WakeSender {
    pub(crate) fn notify(&self) {
        let mut s = &self.0;
        let _ = s.write(&[1u8]);
    }

    pub(crate) fn raw_fd(&self) -> i32 {
        self.0.as_raw_fd()
    }
}

#[cfg(unix)]
pub(crate) struct WakeReceiver(UnixStream);

#[cfg(unix)]
impl WakeReceiver {
    pub(crate) fn fd(&self) -> i32 {
        self.0.as_raw_fd()
    }

    pub(crate) fn drain(&self) -> usize {
        let mut s = &self.0;
        let mut buf = [0u8; 64];
        let mut total = 0usize;
        loop {
            match s.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => total = total.saturating_add(n),
                Err(e) if e.kind() == ErrorKind::WouldBlock => break,
                Err(_) => break,
            }
        }
        total
    }
}

#[cfg(unix)]
pub(crate) fn make_wake_pair() -> Result<(WakeReceiver, WakeSender), String> {
    let (rx, tx) = UnixStream::pair().map_err(|e| format!("wake pair failed: {e}"))?;
    rx.set_nonblocking(true)
        .map_err(|e| format!("wake rx nonblocking failed: {e}"))?;
    tx.set_nonblocking(true)
        .map_err(|e| format!("wake tx nonblocking failed: {e}"))?;
    Ok((WakeReceiver(rx), WakeSender(tx)))
}

#[cfg(not(unix))]
pub(crate) struct WakeSender;

#[cfg(not(unix))]
impl WakeSender {
    pub(crate) fn notify(&self) {}
}

#[cfg(not(unix))]
pub(crate) struct WakeReceiver;

#[cfg(not(unix))]
impl WakeReceiver {
    pub(crate) fn fd(&self) -> i32 {
        -1
    }

    pub(crate) fn drain(&self) -> usize {
        0
    }
}

#[cfg(not(unix))]
pub(crate) fn make_wake_pair() -> Result<(WakeReceiver, WakeSender), String> {
    Ok((WakeReceiver, WakeSender))
}
