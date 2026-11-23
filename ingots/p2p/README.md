# `p2p` — Shared P2P Gossip Engine & Transport Traits

Transport-agnostic peer-to-peer building blocks and effect-polymorphic traits (`P2pEngine`, `Transport`) shared by `p2p_tcp`, `p2p_udp`, and `p2p_libp2p`.

## Quick Start

Add `p2p` to `fe.toml`:

```toml
[dependencies]
p2p = { path = "../p2p" }
```

### Framing & Gossip Deduplication (`0xFE50` Envelope)

```fe
use p2p::{Header, KIND_DATA, MAX_PAYLOAD, MAGIC, decode_header, encode_frame}

fn roundtrip_envelope(payload: MemSpan) {
    assert!(payload.len() <= MAX_PAYLOAD)
    let hdr = Header::new(kind: KIND_DATA, origin: 1, seq: 1, ttl: 4)
    var buf = MemBuffer::empty()
    assert!(encode_frame(hdr, payload, mut buf))

    let decoded = decode_header(buf.span()).unwrap()
    assert!(decoded.kind == KIND_DATA)
    assert!(decoded.id() == hdr.id())
}
```

### Selecting Transports Uniformly via `P2pEngine`

```fe
use p2p::P2pEngine

fn broadcast_quote<M: P2pEngine>(mut net: M, payload: MemSpan) -> bool uses M::E {
    net.publish(payload)
}
```

---

## Architecture

```text
  Callers (`feracle`) ──▶ `P2pEngine` (uses E) / `Transport`
                             ├─ `p2p_udp`    (`UdpEngine` / `UdpTransport`)
                             ├─ `p2p_tcp`    (`TcpEngine` / `TcpTransport`)
                             └─ `p2p_libp2p` (`Libp2pTransport`)
                                   │
                                   ▼
                        `p2p` shared facilities
                          ├─ `0xFE50` Envelope (`HEADER_LEN = 23`, `MAX_PAYLOAD = 1200`)
                          ├─ `GossipCore` (`prepare_publish`, `accept_data` with TTL decrement)
                          └─ `SeenCache` + `Inbox` + `PeerBook` + `Ticker` / `Backoff` + `pick_fanout`
```

| Module | Responsibility |
| --- | --- |
| `src/lib.fe` | Public re-exports across envelope, gossip state, peer book, seeds, timers, and traits |
| `src/transport.fe` | `P2pEngine` (`uses E`), `Transport`, `GossipConfig`, `Delivery`, `Stats`, and `pick_fanout` |
| `src/envelope.fe` | 23-byte `0xFE50` binary header codec, `frame_len`, and in-place `set_ttl` |
| `src/gossip.fe` | `GossipCore` gluing `PeerBook`, `SeenCache`, `Inbox`, sequence numbers, and stats |
| `src/peers.fe` | Bounded `PeerBook` (`MAX_PEERS = 128`) tracking `Alive`/`Suspect` peers and monotonic `version()` |
| `src/peer_entry.fe` | Compact wire `PeerEntry` encode/decode and `normalize_addr` (`0.0.0.0` rewrite) |
| `src/seen.fe` | Fixed-capacity ring `SeenCache` keyed by `u128` `(origin, seq)` frame IDs |
| `src/inbox.fe` | Bounded FIFO `Inbox` counting overflows in `dropped()` |
| `src/timer.fe` | `Ticker`, exponential `Backoff`, and `MonoClock` helpers |
| `src/seeds.fe` | `parse_seeds` (`ip:port` and `/ip4/<ip>/(tcp\|udp)/<port>`), CSV formatting, ephemeral tags |
| `src/rng.fe` | Fast `Rng` used by `pick_fanout` |
| `src/test.fe` | 6 unit tests covering codecs, seeds, `PeerBook`, `SeenCache`, `Inbox`, timers, and fanout |

---

## Testing

```bash
fe test --backend native ingots/p2p
```

---

## Trade-offs & Limitations

- **Single-datagram payload bound:** `MAX_PAYLOAD = 1200` ensures every `0xFE50` frame fits comfortably in one UDP datagram; larger messages must be chunked at a higher layer.
- **Bounded tables & linear scans:** `PeerBook` caps entries at `MAX_PEERS = 128` (preferentially evicting the oldest `Suspect` peer), and `SeenCache`/`Inbox` use bounded rings so memory stays predictable during partitions.
- **Two abstraction tiers:** `P2pEngine` (`uses E`) integrates zero-overhead with shared `coro::Scheduler` + `net_reactor::SocketIo` event loops, while `Transport` provides a self-contained driver wrapper for callers without an existing reactor.

---

## Core API Summary

| Symbol | Role |
| --- | --- |
| `P2pEngine` | Effect-polymorphic trait (`uses E`) for reactor-driven P2P engines |
| `Transport` | Self-contained non-blocking P2P transport trait (`publish`, `poll`, `recv`, `peer_count`, `add_seed`) |
| `GossipCore` | Reusable node gossip state (`prepare_publish`, `accept_data`, `recv`, `peer_entries`) |
| `GossipConfig` | Shared tuning (`fanout = 3`, `ttl = 4`, `seen_capacity = 1024`, `inbox_capacity = 128`, SWIM/dial intervals) |
| `Header`, `encode_frame`, `decode_header` | Self-delimiting 23-byte `0xFE50` wire header (`MAX_PAYLOAD = 1200`, `KIND_DATA = 0x01`) |
| `PeerBook`, `PeerEntry`, `parse_seeds` | Peer table management, wire peer serialization, and multiaddr/`ip:port` seed parsing |
