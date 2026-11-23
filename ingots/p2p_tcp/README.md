# `p2p_tcp` — Non-Blocking TCP Mesh & PEX Transport

A pure-Fe TCP gossip transport using `p2p` shared facilities and `net_reactor::SocketIo` (`coro`), exposing both a composable `TcpEngine` (`impl p2p::P2pEngine`) and a standalone `TcpTransport` (`impl p2p::Transport`).

## Quick Start

Add `coro`, `net_reactor`, `p2p`, and `p2p_tcp` to `fe.toml`:

```toml
[dependencies]
coro = { path = "../coro" }
net_reactor = { path = "../net_reactor" }
p2p = { path = "../p2p" }
p2p_tcp = { path = "../p2p_tcp" }
```

### Embedded in an Event Loop (`TcpEngine`)

```fe
use std::net::{IpAddr, Ipv4Addr, Net, SocketAddr}
use std::time::Clock
use coro::{LocalScheduler, Scheduler}
use net_reactor::{NetPoller, SocketIo}
use p2p::{GossipConfig, P2pEngine}
use p2p_tcp::{TcpConfig, TcpEngine}

fn run_tcp_engine() uses (net: mut Net, clock: Clock) {
    var sched = LocalScheduler::new(0)
    var io = NetPoller::new().unwrap()

    with (Scheduler = sched, SocketIo = io) {
        let owner = sched.alloc_task()
        let cfg = TcpConfig {
            bind_addr: SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0),
            self_tag: 1,
            seeds: MemVec::new(),
            gossip: GossipConfig::default(),
        }
        var engine = TcpEngine::bind(cfg, owner).unwrap()
        let _ = engine.publish("hello".span())
        let _ = engine.poll_io()
        engine.stop()
    }
}
```

### Standalone `Transport` Wrapper (`TcpTransport`)

```fe
let mut tx = TcpTransport::bind(cfg).unwrap()
let _ = tx.publish("hello".span())
let _ = tx.poll(timeout_ms: 20)
```

---

## Architecture

```text
  TcpEngine (uses Scheduler, SocketIo)
    ├─ listener_token (SocketIo TCP accept)
    ├─ peers: MemVec<PeerConn>  ──▶ FrameStep (NeedMore / Frame / Invalid)
    ├─ DialBook (state.dialer)  ──▶ exponential backoff dialing (up to 8 due/tick)
    ├─ GossipCore (state.base)  ──▶ 0xFE50 SeenCache, Inbox, PeerBook, fanout forwarding
    └─ Timers                   ──▶ PEX gossip + PING/PONG keepalives + dead_ms reaping
```

| Module | Responsibility |
| --- | --- |
| `src/lib.fe` | Public re-exports (`TcpConfig`, `TcpEngine`, `TcpTransport`) |
| `src/transport.fe` | `TcpConfig`, `TcpEngine::bind`, dial/accept/read/write loop, and `TcpTransport::bind` |
| `src/transport_impl.fe` | `P2pEngine` (`TcpEngine`), `Transport` (`TcpTransport`), PEX/ping/stale timers |
| `src/conn.fe` | `PeerConn`, `ConnState`, partial-read `0xFE50` frame slicing (`FrameStep`), writable flushing |
| `src/mesh.fe` | `TcpMeshState`, queue/flush helpers, `Interest` toggling, clean peer close & bookkeeping |
| `src/dialer.fe` | `DialBook` backoff state per seed/PEX address |
| `src/dispatch.fe` | Handles `KIND_DATA`, `HELLO`, `PEX`, `PING`, `PONG` and deterministic simultaneous-dial tiebreak |
| `src/wire.fe` | Control frame codecs (`KIND_HELLO = 0x20`, `KIND_PEX = 0x21`, `KIND_PING = 0x22`, `KIND_PONG = 0x23`) |
| `src/test.fe` | 4 native tests covering shared-reactor engines, PEX mesh gossip, tiebreak, and burst reconnect |

---

## Testing

```bash
fe test --backend native ingots/p2p_tcp
```

---

## Trade-offs & Limitations

- **Bounded peer table:** `MAX_TCP_PEERS = 64` caps open TCP connections per node, with dial attempts batched to 8 due targets per pass.
- **Plaintext `0xFE50` stream framing:** Frames use shared self-delimiting `0xFE50` headers over non-blocking `TcpStream`s without built-in Noise/TLS encryption (use `libp2p` for Noise-encrypted peer streams or authenticate application payloads via signed frames as Feracle does for `QuoteMsg`/`SigMsg`).
- **Simultaneous-dial tiebreak:** Duplicate bidirectional connections are closed deterministically by peer tag ordering once `KIND_HELLO` identifies the remote node.

---

## Core API Summary

| Symbol | Role |
| --- | --- |
| `TcpConfig` | Startup configuration (`bind_addr`, `self_tag`, `seeds`, `gossip`) |
| `TcpEngine` | Reactor-native engine implementing `p2p::P2pEngine` for direct event-loop composition |
| `TcpTransport` | Self-contained `LocalScheduler` + `NetPoller` + `NetDriver` wrapper implementing `p2p::Transport` |
