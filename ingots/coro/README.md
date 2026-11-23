# `coro` — Cooperative Stackless Coroutines & Combinators

A single-threaded, cooperative state-machine and combinator library for event-loop Fe programs.

`coro` provides composable `Poll<T>` state machines (`Sleep`, `Timeout`, `Join2`, `Select2`, `JoinAll`, `BoundedPool`), a `Scheduler` capability for timers and wake hints, and a `Driver` loop (`block_on`) that pumps one root coroutine tree on the current thread. It has no networking, filesystem, or OS clock dependencies of its own—native event loops plug in I/O via separate ingots such as `net_reactor`, while unit tests swap in `VirtualClockDriver` with zero syscalls.

---

## How It Works

Unlike multithreaded work-stealing executors in Rust or Go, `coro` runs synchronously on a single call thread using top-down cooperative polling:

1. **Top-down polling (`block_on`)**: A caller enters `with (Scheduler = sched)` and hands one root `Coroutine` and one `Driver` to `block_on`. Every iteration runs `driver.begin_tick()` -> `coro.poll()` -> (if `Poll::Pending`) `driver.wait()`.
2. **State machines as plain structs**: Every `Coroutine` is a Fe struct/enum holding its current step and child coroutines. When `poll()` returns `Poll::Pending`, nothing allocates a stack frame or background task; state simply stays in the struct until the next tick.
3. **Timers and wake hints without I/O**: `Scheduler` tracks logical milliseconds (`now_ms`), pending timer deadlines (`TimerId`), and woken task IDs (`TaskId`). Calling `sched.wake(task)` or having an expired timer causes `sched.next_timeout_ms(max_ms)` to return `0` so the driver knows not to block in `wait()`.
4. **Effect polymorphism (`uses E`)**: Coroutines declare only the capabilities they require. Combinators propagate child effects automatically (for example `Join2` requires `(A::E, B::E)`), keeping timing and concurrency logic decoupled from sockets or host state.

---

## Quick Start

Add the dependency to `fe.toml`:

```toml
[dependencies]
coro = { path = "../coro" }
```

Bind a `LocalScheduler` via `with (Scheduler = sched)` and run composed timers with `VirtualClockDriver` and `block_on`:

```fe
use coro::{
    Join2,
    LocalScheduler,
    Map,
    Scheduler,
    Sleep,
    Timeout,
    VirtualClockDriver,
    block_on,
}

fn run_concurrent_tasks() {
    var sched = LocalScheduler::new(0)
    let task_a = sched.alloc_task()
    let task_b = sched.alloc_task()

    with (Scheduler = sched) {
        var jobs = Join2::new(
            Map::new(Sleep::after(owner: task_a, delay_ms: 15), |_ v: ()| -> u64 { 10 }),
            Map::new(Sleep::after(owner: task_b, delay_ms: 40), |_ v: ()| -> u64 { 32 }),
        )
        var bounded = Timeout::new(owner: task_a, delay_ms: 100, jobs)
        var driver = VirtualClockDriver::new(step_ms: 50)

        let result = block_on(mut bounded, mut driver)
        let (left, right) = result.unwrap()
        assert!(left + right == 42)
    }
}
```

---

## Architecture

```text
  Root Coroutine (application state machine / combinators)
        │  poll() propagates `C::E` (e.g. `sched: mut Scheduler`, `io: mut SocketIo`)
        ▼
  coro::block_on(mut coro, mut driver) ──▶ loop: begin_tick() ─▶ poll() ─▶ wait()
        │                                       │
        │                                       ▼
        │                               Driver::wait()
        │                                 ├─ VirtualClockDriver  (advances logical clock)
        │                                 └─ Host I/O Driver     (e.g. `net_reactor::NetDriver`)
        ▼
  Scheduler (`LocalScheduler`) ──▶ logical `now_ms`, `TimerId` list, woken `TaskId` hints
```

| Module | Responsibility |
| --- | --- |
| `src/lib.fe` | Public re-exports for traits, scheduler, timers, combinators, and runner |
| `src/task.fe` | `TaskId`, `TimerId`, `Poll<T>` (`.map()`), `Either<A, B>`, `Coroutine`, `Driver`, and `block_on` |
| `src/scheduler.fe` | `Scheduler` capability trait, `LocalScheduler`, and `VirtualClockDriver` |
| `src/sleep.fe` | `Sleep` (`::after`, `::until`) and `Timeout<C>` with loser cancellation |
| `src/combinators.fe` | `Ready<T>`, `YieldOnce`, `Map<C, F>`, `Join2<A, B>`, `Select2<A, B>`, `JoinAll<C>`, and `BoundedPool<K, C>` |
| `src/test.fe` | Pure virtual-clock unit tests (no OS threads, sleeps, or sockets) |

---

## Usage Patterns

### Implementing a Custom `Coroutine`

A custom coroutine defines `type Output`, its required effects (`uses E`), non-blocking `poll()`, and structured cleanup in `cancel()`:

```fe
use coro::{Coroutine, Poll, Scheduler, Sleep, TaskId}

struct DelayedFlag { sleep: Sleep, done: bool }

impl DelayedFlag {
    pub fn start(owner: TaskId, delay_ms: u64) -> Self uses (sched: mut Scheduler) {
        DelayedFlag { sleep: Sleep::after(owner, delay_ms), done: false }
    }
}

impl Coroutine for DelayedFlag {
    type Output = bool
    uses E = (sched: mut Scheduler)

    fn poll(mut self) -> Poll<bool> uses E {
        if self.done {
            return Poll::Ready(true)
        }
        if let Poll::Ready(_) = self.sleep.poll() {
            self.done = true
            return Poll::Ready(true)
        }
        Poll::Pending
    }

    fn cancel(mut self) uses E {
        self.done = true
        self.sleep.cancel()
    }
}
```

---

### Concurrent Combinators & Cancellation

When racing or bounding work, combinators cancel any unfinished branch as soon as the outcome is decided:

- **`Join2::new(a, b)`** — polls both coroutines on each tick until both complete, returning `(A::Output, B::Output)`.
- **`Select2::new(a, b)`** — resolves when either completes (`Either::Left` / `Either::Right`) and calls `.cancel()` on the other immediately.
- **`Timeout::new(owner, delay_ms, inner)`** — yields `Option::Some(val)` if `inner` finishes before the timer fires, or cancels `inner` and yields `Option::None`.
- **`JoinAll::new(tasks)`** — polls a `MemVec<C>` concurrently and returns `MemVec<C::Output>` in input order regardless of completion order.

```fe
use coro::{Either, LocalScheduler, Scheduler, Select2, Sleep, VirtualClockDriver, block_on}

fn race_two() -> bool {
    var sched = LocalScheduler::new(0)
    let t1 = sched.alloc_task()
    let t2 = sched.alloc_task()

    with (Scheduler = sched) {
        var race = Select2::new(
            Sleep::after(owner: t1, delay_ms: 10),
            Sleep::after(owner: t2, delay_ms: 500),
        )
        var drv = VirtualClockDriver::new(step_ms: 100)
        match block_on(mut race, mut drv) {
            Either::Left(_) => true,
            Either::Right(_) => false,
        }
    }
}
```

---

### Sliding-Window Execution with `BoundedPool`

Use `BoundedPool<K, C>` to keep up to `max_inflight` coroutines active over a dynamic or retryable work queue without wave barriers. Finished slots are pulled synchronously via `poll_ready(mut completed)`, avoiding mutable closure captures:

```fe
use coro::{BoundedPool, PoolDone, Scheduler, Sleep, TaskId}

struct WorkKey { owner: TaskId, delay_ms: u64, retry: bool }

impl Copy for WorkKey {}

fn drain_pool(keys: MemVec<WorkKey>, max_inflight: usize) uses (sched: mut Scheduler) {
    var pool = BoundedPool<WorkKey, Sleep>::new(max_inflight)
    var i: usize = 0
    while i < keys.len() {
        pool.enqueue(keys[i])
        i += 1
    }

    pool.refill(|key: ref WorkKey| -> Sleep {
        Sleep::after(owner: key.owner, delay_ms: key.delay_ms)
    })

    var completed = MemVec<PoolDone<WorkKey, ()>>::new()
    while !pool.is_done() {
        sched.clear_woken()
        pool.poll_ready(mut completed)
        while let Option::Some(item) = completed.pop() {
            if item.key.retry {
                pool.enqueue(
                    WorkKey { owner: item.key.owner, delay_ms: 5, retry: false },
                )
            }
        }
        pool.refill(|key: ref WorkKey| -> Sleep {
            Sleep::after(owner: key.owner, delay_ms: key.delay_ms)
        })
        if !pool.is_done() {
            let wait_ms = sched.next_timeout_ms(max_ms: 100)
            let _ = sched.advance_by(delta_ms: wait_ms)
        }
    }
    pool.cancel_all()
}
```

---

### Writing a Custom `Driver`

To pair `coro` with an external event loop (such as OS socket polling in `net_reactor::NetDriver`), implement `Driver`:

1. **`begin_tick`**: clear previous wake flags (`sched.clear_woken()`) and advance `sched` to current wall-clock time so due timers are visible to `coro.poll()`.
2. **`wait`**: query `sched.next_timeout_ms(max_ms)` before sleeping so the OS wait never oversleeps pending timers or woken tasks, then wake ready owners and advance logical time.

```fe
use coro::{Driver, Scheduler}

struct StepDriver { step_ms: u64 }

impl Driver for StepDriver {
    uses E = (sched: mut Scheduler)

    fn begin_tick(mut self) uses E {
        sched.clear_woken()
    }

    fn wait(mut self) uses E {
        let delay = sched.next_timeout_ms(max_ms: self.step_ms)
        let _ = sched.advance_by(delta_ms: delay)
    }
}
```

---

## Testing

Run the `coro` unit suite natively using virtual time (zero sockets or real delays):

```bash
fe test --backend native ingots/coro
```

---

## Trade-offs & Limitations

- **Single-threaded & cooperative**: `poll()` must never block on synchronous I/O or long sleeps. Any blocking call inside one coroutine stalls the entire root tree.
- **No detached background `spawn()`**: There is no ambient global task list; every concurrent unit lives explicitly inside the caller's state machine or a combinator (`Join2`, `JoinAll`, `BoundedPool`).
- **Not intended for EVM execution**: While `coro` uses pure Fe data structures and compiles without `std::net`, smart contract transactions execute atomically and synchronously inside single-threaded EVM calls with no event loop, real-time clock, or async suspension points. In practice, `coro` is meant for native host event loops (and pure off-chain state-machine tests).
- **Linear timer scans**: `LocalScheduler` stores timers and wake flags in flat `MemVec` buffers (`O(N)` per tick). This keeps footprint tiny for small/medium node loops (dozens to hundreds of active timers), but is not designed for tens of thousands of simultaneous timers.
- **Explicit cleanup via `cancel()`**: Fe destructors (`Drop::drop`) cannot declare effects, so abandoned coroutines must be torn down explicitly with `.cancel()` (`cancel_all()` for `BoundedPool`) to cancel active timers or external resources.

---

## Core API Summary

| Symbol | Role |
| --- | --- |
| `Poll<T>` | Step result (`Pending` / `Ready(T)`) with `.is_ready()`, `.is_pending()`, and `.map(mut f)` |
| `Either<A, B>` | Result sum type returned by `Select2` (`Left(A)` / `Right(B)`) |
| `Ready<T>` / `YieldOnce` | Leaf coroutines yielding an immediate value or a single `Pending` tick (`YieldOnce::new(owner)` wakes `owner` via `Scheduler`) |
| `Map<C, F>` | Transforms `C::Output` via `F` while propagating `(C::E, F::E)` |
| `Sleep` | Timer coroutine (`::after`, `::until`) backed by `Scheduler` |
| `Timeout<C>` | Races `C` against `Sleep`, cancelling whichever finishes second |
| `Join2<A, B>` / `JoinAll<C>` | Structured fan-out preserving tuple/vector output order and cascading `cancel` |
| `BoundedPool<K, C>` | Two-stack FIFO sliding-window runner with `refill`, pull-based `poll_ready`, and `cancel_all` |
| `LocalScheduler` / `VirtualClockDriver` | In-memory `Scheduler` + deterministic virtual-time `Driver` |
| `block_on(mut coro, mut driver)` | Single-threaded tick runner for any `(Coroutine, Driver)` pair |
