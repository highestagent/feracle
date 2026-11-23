# `net_reactor` — Non-Blocking Socket Reactor & Coroutine Driver

A native OS socket-multiplexing reactor (`NetPoller`) and `coro::Driver` bridge (`NetDriver`) for single-threaded Fe event loops.

## Quick Start

Add `coro` and `net_reactor` to `fe.toml`:

```toml
[dependencies]
coro = { path = "../coro" }
net_reactor = { path = "../net_reactor" }
```

Create a `NetPoller` and `NetDriver`, bind them via `with (Scheduler = sched, SocketIo = io)`, and drive sockets or external wakeup descriptors through `coro::block_on`:

```fe
use std::net::{Interest, Net, SocketAddr}
use std::time::Clock
use coro::{Coroutine, LocalScheduler, Poll, Scheduler, block_on}
use net_reactor::{NetDriver, NetPoller, SocketIo}

fn accept_once(addr: SocketAddr) uses (net: mut Net, clock: Clock) {
    var sched = LocalScheduler::new(0)
    var io = NetPoller::new().unwrap()
    var driver = NetDriver::new(max_wait_ms: 50)

    with (Scheduler = sched, SocketIo = io) {
        let task = sched.alloc_task()
        let listener = net.listen(addr).unwrap()
        let tok = io.register_tcp_listener(owner: task, tag: 0, listener).unwrap()
        // Poll sockets cooperatively via `driver` or `block_on(...)`, then clean up:
        io.deregister(tok)
    }
    let _ = driver
}
```

---

## Architecture

```text
  coro::block_on(root, driver)
        │
        ├─▶ driver.begin_tick() ──▶ clear_woken() + sync_clock()
        │
        └─▶ driver.wait()       ──▶ has_ready_io() ? 0ms : sched.next_timeout_ms(max_wait_ms)
                                       │
                                       ▼
                               NetPoller::poll_os(timeout_ms, mut woken_scratch)
                                 ├─ reuses `Events::with_capacity(128)` + `ready_io`
                                 ├─ coalesces duplicate per-Token readiness flags
                                 └─ wakes owning `TaskId`s in `Scheduler`
```

| Module | Responsibility |
| --- | --- |
| `src/lib.fe` | Public re-exports (`NetDriver`, `IoEntry`, `IoEvent`, `IoSlot`, `SocketIo`, `is_would_block`, `NetPoller`) |
| `src/io.fe` | `IoSlot` (`TcpListener`, `TcpStream`, `UdpSocket`, `RawFd`), `IoEvent`, `SocketIo` capability trait, and `is_would_block` |
| `src/poller.fe` | `NetPoller` implementation over `std::net::Poller` (`kqueue`/`epoll`), per-token event coalescing, and non-blocking syscalls |
| `src/driver.fe` | `NetDriver` (`impl coro::Driver`) synchronizing `Instant` monotonic time and waking ready tasks via `woken_scratch` |
| `src/test.fe` | Native TCP/UDP coroutine tests, `IoEvent` coalescing, `register_raw_fd` wakeup, and timer tests |

---

## Usage Patterns

### Registering External / Signal Wakeup Descriptors

External FFI threads or POSIX signal handlers can wake `NetDriver` without a fixed polling interval via `register_raw_fd`:

```fe
let tok = io.register_raw_fd(owner: task, tag: 1, fd: wake_fd, Interest::READABLE)?
if let Option::Some(ev) = io.take_token_event(tok) {
    if ev.readable {
        // Drain wakeup pipe bytes and check external state
    }
}
io.deregister(tok)
```

---

## Testing

```bash
fe test --backend native ingots/net_reactor
```

---

## Trade-offs & Limitations

- **Native only:** Built on `std::net::Poller` (`kqueue` on macOS, `epoll` on Linux) and raw descriptors (`as_raw_fd`), so it targets `--backend native`.
- **Caller-owned `RawFd` lifetime:** Deregistering `IoSlot::RawFd(fd)` removes the descriptor from `Poller`, while closing `fd` remains the caller's responsibility (whereas registered `TcpListener`, `TcpStream`, and `UdpSocket` values are dropped only after `poller.remove(token)`).
- **Linear token / event scans:** `tokens` and `ready_io` use flat `MemVec` buffers suited to small-to-medium descriptor counts rather than thousands of concurrent sockets.

---

## Core API Summary

| Symbol | Role |
| --- | --- |
| `SocketIo` | Capability trait abstracting non-blocking registration, interest updates, I/O ops, and event consumption |
| `NetPoller` | Native `SocketIo` implementation backed by `std::net::Poller` with reusable `Events` / `ready_io` scratch buffers |
| `NetDriver` | `coro::Driver` keeping `Scheduler` wall-clock time synchronized and waking owners on OS readiness |
| `IoSlot` | Tagged resource union (`TcpListener`, `TcpStream`, `UdpSocket`, `RawFd(i32)`) implementing `Pollable` |
| `IoEvent` | Per-token readiness record (`token`, `owner`, `tag`, `readable`, `writable`, `error`, `hangup`) |
| `is_would_block(err)` | Checks `err.kind() == ErrorKind::WouldBlock` |
