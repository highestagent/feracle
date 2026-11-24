#[cfg(unix)]
use std::os::raw::c_int;
use std::panic::{catch_unwind, AssertUnwindSafe};
#[cfg(unix)]
use std::sync::atomic::AtomicI32;
use std::sync::atomic::{AtomicBool, Ordering};
#[cfg(unix)]
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

#[cfg(unix)]
use crate::wake::{make_wake_pair, WakeReceiver, WakeSender};

pub(crate) static SHUTDOWN_REQUESTED: AtomicBool = AtomicBool::new(false);
#[cfg(unix)]
static SIGNAL_WAKE_FD: AtomicI32 = AtomicI32::new(-1);
#[cfg(unix)]
static SIGNAL_PIPE: OnceLock<Mutex<(WakeReceiver, WakeSender)>> = OnceLock::new();

#[cfg(unix)]
extern "C" {
    #[link_name = "signal"]
    fn c_signal(sig: c_int, handler: extern "C" fn(c_int)) -> usize;
    #[link_name = "write"]
    fn c_write(fd: c_int, buf: *const u8, count: usize) -> isize;
}

#[cfg(unix)]
pub(crate) extern "C" fn handle_shutdown_signal(_sig: c_int) {
    SHUTDOWN_REQUESTED.store(true, Ordering::SeqCst);
    let fd = SIGNAL_WAKE_FD.load(Ordering::Acquire);
    if fd >= 0 {
        let byte: u8 = 1;
        unsafe {
            let _ = c_write(fd, &byte as *const u8, 1);
        }
    }
}

#[no_mangle]
pub extern "C" fn sys_install_signal_handlers() -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        SHUTDOWN_REQUESTED.store(false, Ordering::SeqCst);
        #[cfg(unix)]
        {
            if SIGNAL_PIPE.get().is_none() {
                if let Ok(pair) = make_wake_pair() {
                    let _ = SIGNAL_PIPE.set(Mutex::new(pair));
                }
            }
            let Some(pipe_lock) = SIGNAL_PIPE.get() else {
                return -1;
            };
            let Ok(guard) = pipe_lock.lock() else {
                return -1;
            };
            guard.0.drain();
            let tx_fd = guard.1.raw_fd();
            let rx_fd = guard.0.fd();
            SIGNAL_WAKE_FD.store(tx_fd, Ordering::Release);
            unsafe {
                c_signal(2, handle_shutdown_signal);
                c_signal(15, handle_shutdown_signal);
            }
            rx_fd
        }
        #[cfg(not(unix))]
        {
            -1
        }
    }))
    .unwrap_or(-1)
}

#[no_mangle]
pub extern "C" fn sys_shutdown_requested() -> i32 {
    if SHUTDOWN_REQUESTED.load(Ordering::Acquire) {
        1
    } else {
        0
    }
}

#[no_mangle]
pub extern "C" fn sys_drain_signal_wake() -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        #[cfg(unix)]
        {
            if let Some(pipe_lock) = SIGNAL_PIPE.get() {
                if let Ok(guard) = pipe_lock.lock() {
                    return i32::try_from(guard.0.drain()).unwrap_or(i32::MAX);
                }
            }
        }
        0
    }))
    .unwrap_or(-1)
}

#[no_mangle]
pub extern "C" fn p2p_sleep_ms(ms: u32) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        std::thread::sleep(Duration::from_millis(u64::from(ms)));
    }));
}
