# `p2p_udp` — Connectionless UDP Gossip & SWIM Transport

A pure-Fe UDP gossip and SWIM membership transport built on `p2p` shared facilities and `net_reactor::SocketIo` (`coro`), exposing both `UdpEngine` (`impl p2p::P2pEngine`) and `UdpTransport` (`impl p2p::Transport`).

## Quick Start

Add `coro`, `net_reactor`, `p2p`, and `p2p_udp` to `fe.toml`:

```toml
[dependencies]
coro = { path = "../coro" }
net_reactor = { path = "../net_reactor" }
p2p = { path = "../p2p" }
p2p_udp = { path = "../p2p_udp" }
```

### Embedded in an Event Loop (`UdpEngine`)

```fe
use std::net::{IpAddr, Ipv4Addr, Net, SocketAddr}
use std::time::Clock
use coro::{LocalScheduler, Scheduler}
use net_reactor::{NetPoller, SocketIo}
use p2p::{GossipConfig, P2pEngine}
use p2p_udp::{UdpConfig, UdpEngine}

fn run_udp_engine() uses (net: mut Net, clock: Clock) {
    var sched = LocalScheduler::new(0)
    var io = NetPoller::new().unwrap()

    with (Scheduler = sched, SocketIo = io) {
        let owner = sched.alloc_task()
        let cfg = UdpConfig {
            bind_addr: SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0),
            self_tag: 1,
            seeds: MemVec::new(),
            gossip: GossipConfig::default(),
            lan_broadcast_port: 0,
        }
        var engine = UdpEngine::bind(cfg, owner).unwrap()
        let _ = engine.publish("hello".span())
        let _ = engine.poll_io()
        engine.stop()
    }
}
```

### Standalone `Transport` Wrapper (`UdpTransport`)

```fe
let mut tx = UdpTransport::bind(cfg).unwrap()
let _ = tx.publish("hello".span())
let _ = tx.poll(timeout_ms: 20)
```

---

## Architecture

```text
  UdpEngine (uses Scheduler, SocketIo)
    ├─ udp_token (SocketIo UdpSocket, nonblocking, optional SO_BROADCAST)
    ├─ GossipCore (state.base)  ──▶ 0xFE50 SeenCache, Inbox, PeerBook, TTL forwarding
    ├─ SwimState  (state.swim)  ──▶ JOIN/JOIN_ACK, PING/ACK, indirect PING_REQ, Suspect -> Dead
    └─ Optional LAN discovery   ──▶ periodic broadcast probes on `lan_broadcast_port`
```

| Module | Responsibility |
| --- | --- |
| `src/lib.fe` | Public re-exports (`UdpConfig`, `UdpEngine`, `UdpTransport`) |
| `src/transport.fe` | `UdpConfig`, `UdpEngine::bind`, `P2pEngine` impl, and standalone `UdpTransport` wrapper |
| `src/dispatch.fe` | Datagram recv loop (`recv_buf = 1500B`), `KIND_DATA` TTL forwarding, and SWIM handler dispatch |
| `src/swim.fe` | `SwimState` failure detection timers, pending probe tracking, suspicion & eviction |
| `src/wire.fe` | UDP SWIM codecs (`KIND_JOIN = 0x10`, `JOIN_ACK = 0x11`, `PING = 0x12`, `ACK = 0x13`, `PING_REQ = 0x14`, `INDIRECT_ACK = 0x15`) |
| `src/test.fe` | 4 native tests covering shared-reactor engines, SWIM suspect/expiry, discovery/gossip, and multi-hop forwarding |

---

## Testing

```bash
fe test --backend native ingots/p2p_udp
```

---

## Trade-offs & Limitations

- **Unreliable datagrams & MTU cap:** Application payloads are bounded by `p2p::MAX_PAYLOAD = 1200` so every `0xFE50` frame (`header 23B + payload <= 1223B`) fits inside a single UDP datagram without fragmentation. Lost packets rely on gossip fanout (`fanout = 3`) and application-level rebroadcasts rather than retransmission.
- **No transport encryption:** Like `p2p_tcp`, UDP frames are unencrypted `0xFE50` datagrams; authenticity of consensus quotes/signatures is enforced at the application layer via signed `QuoteMsg`/`SigMsg` envelopes.
- **LAN broadcast discovery is opt-in:** Set `lan_broadcast_port > 0` in `UdpConfig` (`--lan-discovery-port` in `feracle`) to enable broadcast `JOIN` probes on local networks.

---

## Core API Summary

| Symbol | Role |
| --- | --- |
| `UdpConfig` | Startup configuration (`bind_addr`, `self_tag`, `seeds`, `gossip`, `lan_broadcast_port`) |
| `UdpEngine` | Reactor-native engine implementing `p2p::P2pEngine` over a single non-blocking `UdpSocket` |
| `UdpTransport` | Self-contained `LocalScheduler` + `NetPoller` + `NetDriver` wrapper implementing `p2p::Transport` |
