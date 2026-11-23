# Feracle

Feracle is a decentralized price oracle with both on-chain settlement and off-chain consensus facilities built end-to-end in **Fe**. A single target-independent core compiles across Native, EVM, and WASM targets, powering an off-chain node runtime with three selectable peer-to-peer networking backends (`libp2p` GossipSub, TCP mesh with PEX, and UDP SWIM gossip).

![Fe 26.7.0](https://img.shields.io/badge/Fe-26.7.0-4A6FA5?style=flat&labelColor=2A2D36)

> [!IMPORTANT]
> Feracle is experimental, unaudited software. It intentionally omits many safeguards required in a production decentralized oracle network—such as staking/slashing, Sybil-resistant membership, HSM key management, and governance fail-safes—and should not be used in production with real funds.

## The problem

Decentralized price oracles split their stack across different toolchains—Solidity on-chain, Go or Rust off-chain, and TypeScript for monitoring. Protocol engineers and oracle operators end up re-implementing ABI framing, fixed-point math, and tolerance checks in three languages, creating silent parity bugs and heavy operational glue.

## Approach

Feracle unifies the entire oracle pipeline around one shared core and three selectable peer-to-peer networking backends:

- **Shared core (`feracle_core`):** Fixed-point medians, tolerance math, ABI selectors, and `QuoteMsg`/`SigMsg` wire codecs compile identically to Native, EVM, and WASM.
- **On-chain settlement (`evm`):** `OffchainMedianOracle` verifies sorted 3-of-3 `ecrecover` quorums over a two-step batch digest and settles atomically in one transaction per round.
- **Off-chain consensus (`feracle`) & P2P backends (`p2p`, `p2p_udp`, `p2p_tcp`, `p2p_libp2p`):** Nodes aggregate exchange quotes over HTTP/1.1, run a 3-phase consensus protocol (quote gossip -> `±100 bps` guard & ECDSA signing -> leader rotation with backup failover), and swap transports cleanly behind `p2p::Transport`.
- **Deep telemetry (`wasm`):** A standalone WASM engine decodes live off-chain gossip frames and EVM RPC settlement batches into a terminal TUI, JSON snapshots, and Prometheus metrics.

## Fe highlight

Fe's **effect polymorphism (`uses E`)** and **scoped capability injection (`with (...)`)** let shared libraries abstract over host I/O, runtime config, and unit tests without mocks or global state—for example, in `ingots/cli` and `ingots/feracle`:

```fe
pub trait Input {
    uses E

    fn arg_count(self) -> usize uses E
    fn arg_at(self, _ index: usize) -> MemBuffer uses E
    fn env_lookup(self, _ name: MemSpan) -> Option<MemBuffer> uses E
}

// Production binds HostInput (Args, Env); tests bind MemoryInput (uses E = ()).
// Parsed values are then injected cleanly into downstream readers:
let config = with (Cli = matches) { load_config() }
```

## Architecture

![Feracle Architecture](docs/feracle-architecture.png)

### Off-Chain Node & Networking (`[Native]`)

1. **`ingots/feracle/`** — Standalone oracle node executable (`out/feracle`):
   - Parses CLI configuration (`--p2p-backend libp2p|tcp|udp`, `--lan-discovery-port`, `--telemetry-port`) with `FERACLE_*` environment variable fallbacks
   - Fetches market quotes concurrently over non-blocking HTTP/1.1 (`http::HttpRequest` + `coro::Timeout` + `coro::BoundedPool` sliding-window fan-out and retry for Coinbase) from Hyperliquid, Binance, and Coinbase and computes per-asset local medians
   - Executes the 3-phase stackless coroutine state machine (`ConsensusCoro`, driven by `NodeCoro` + `coro::block_on`) over `coro::Scheduler` and `net_reactor::SocketIo` capabilities: Quote gossip -> per-asset `±100 bps` tolerance guard and ECDSA signing -> sorted 3-of-3 quorum collection and single-leader batch submission via EIP-155 signed `eth_sendRawTransaction` + receipt polling (with backup-leader failover)
   - Reads on-chain `currentRound()` and `latestPrices()` via `QueryRoundState` / `QueryCurrentRound` (`coro::Join2`) and serves pure-Fe HTTP/SSE telemetry (`/status` and `/events`) over `http::HttpServer` for `tcp` and `udp` backends
2. **`ingots/coro/`** — Cooperative, single-threaded stackless coroutine & combinator library:
   - Defines `Coroutine` (`uses E`), `Driver`, `Poll<T>`, `Either<A, B>`, `Scheduler` (`LocalScheduler`, `VirtualClockDriver`), and `block_on`, plus composable combinators (`Sleep`, `Timeout`, `Ready`, `YieldOnce`, `Map`, `Join2`, `Select2`, `JoinAll`, `BoundedPool`)
   - Keeps state-machine timing and concurrency decoupled from I/O (paired with `net_reactor` for native event loops and `VirtualClockDriver` for deterministic tests)
3. **`ingots/net_reactor/`** — Native OS socket multiplexing & `coro::Driver` bridge:
   - Exposes the `SocketIo` capability trait (`NetPoller` backed by `std::net::Poller`) and `NetDriver` (`impl coro::Driver`) synchronizing wall-clock time to `coro::Scheduler`
4. **`ingots/http/`** — Consumer-agnostic non-blocking HTTP/1.1 client & server:
   - Provides `HttpRequest` (`impl coro::Coroutine`, chunked transfer decoding, `HttpRequest::start_with_timeout`) and generic `HttpServer` (`HttpEvent`, SSE upgrade, keepalive, backpressure lag detection) driven via `Scheduler` + `SocketIo`
5. **`ingots/cli/`** — Standalone, effect-polymorphic CLI parser and runner:
   - `Input` / `Output` effect traits (`Args`/`Env`/`Stdout`/`Stderr` in host mode; deterministic `MemoryInput`/`BufferOutput` in unit tests)
   - Capability injection via `with (Cli = matches)` and `FromArg` return-type inference for primitives, network addresses, and domain types
   - GNU/POSIX option parsing, env/default precedence, repeatable/delimited values, recursive subcommands, Levenshtein typo suggestions, sensitive-value redaction, `.arg_required_else_help()`, and `--help` / `--version`
6. **`ingots/p2p/`** — Shared P2P engine and transport contract:
   - Common self-delimiting binary envelope (`0xFE50` magic, `version`, `kind`, `(origin, seq)` identity, mutable hop `ttl`, `len <= 1200`) and `Transport` trait (`publish`, `poll`, `recv`, `peer_count`, `peer_entries`, `stats`, `add_seed`)
   - Shared `GossipCore` state, bounded ring `SeenCache`, bounded FIFO `Inbox`, `PeerBook` (direct `observe` vs gossip `learn`, suspicion & expiry), `PeerEntry` wire codecs with `0.0.0.0` normalization, timers/backoff, fanout selection, and seed parsing (`ip:port` or `/ip4/<ip>/(tcp|udp)/<port>`)
7. **`ingots/p2p_udp/`** — Connectionless UDP gossip + SWIM membership backend (`UdpEngine` using `Scheduler` + `SocketIo` capabilities + `UdpTransport` wrapper):
   - Non-blocking `UdpSocket` I/O under `SocketIo` (`kqueue`/`epoll`), TTL-decrementing gossip forwarding, SWIM failure detection (`JOIN`/`PING`/`PING_REQ`/`Suspect` expiry), and optional UDP broadcast LAN discovery
8. **`ingots/p2p_tcp/`** — Non-blocking TCP mesh + Peer Exchange backend (`TcpEngine` using `Scheduler` + `SocketIo` capabilities + `TcpTransport` wrapper):
   - `TcpListener`/`TcpStream` interest management under `SocketIo`, partial read/write framing, PEX peer discovery, deterministic simultaneous-dial tie-breaking, exponential backoff dialing, and `PING`/`PONG` keepalives
9. **`ingots/p2p_libp2p/`** — `libp2p` GossipSub binding (`Libp2pTransport`):
   - Isolates the `p2p_*` C-ABI FFI surface behind `p2p::Transport` so `ingots/feracle/` switches uniformly across `libp2p`, `tcp`, and `udp`
10. **`p2p-shim/`** (`[Rust staticlib]`) — Panic-safe C ABI (`libp2p_shim.a`):
    - `libp2p` GossipSub (`"fe-oracle/top20-usd/v1"`) over TCP + Noise + Yamux + mDNS
    - `crypto_keccak_and_sign` and `crypto_keccak_and_sign_bytes` (`tiny-keccak` + `k256`) for quorum batch signatures and raw EIP-155 transaction signing
    - Exposes local peer ID and connected-peer CSV snapshots to Fe's unified HTTP/SSE `TelemetryServer` (`http::HttpServer`, serving `/status` and `/events` across `libp2p`, `tcp`, and `udp`)

### Shared Core & On-Chain Settlement (`[Native / EVM / WASM]`, `[EVM]`)

11. **`ingots/core/` (`feracle_core`)** (`[Shared Core: Native / EVM / WASM]`) — Target-independent library shared by all on-chain and off-chain oracle targets (named `feracle_core` so it does not shadow Fe's builtin `core` ingot):
    - Default 20-asset registry (`ASSET_COUNT = 20`: `BTC`..`AAVE`, scaled by `1e8`, settled atomically in one transaction per round)
    - Median helpers, `u128`-safe integer `within_tolerance_bps` checks, float-free `parse_decimal_1e8`, hex/JSON/ABI/RLP EIP-155 codecs, and canonical `QuoteMsg` (`0x00`) / `SigMsg` (`0x01`) wire codecs
    - Round-leader rotation (`round_id % 3`), address comparators, and deterministic 3-signature quorum sorting
12. **`ingots/evm/`** (`[EVM]`) — `OffchainMedianOracle` settlement contract:
    - Tracks authorized oracles, `current_round`, `latest_prices`, and `last_updated`
    - Verifies the 2-step batch digest (`keccak256(abi.encode(chain_id, address(this), round_id, keccak256(abi.encode(prices)), timestamp))`) and recovers `QUORUM = 3` strictly ascending unique signers via `ecrecover`
    - Exposes `submitMedians`, `latestPrices()`, `latestPrice(uint256)`, and `assetCount()`

### Deep Telemetry & Local Tooling (`[WASM]`, `[Node.js]`, `[Python / Caddy]`)

13. **`ingots/wasm/` & `telemetry/host.mjs`** (`[WASM]` + `[Node.js]` host):
    - `ingots/wasm/` reuses `feracle_core` to decode JSON-RPC batches and 21-word `latestPrices()` responses, parse off-chain `QuoteMsg`/`SigMsg` wire frames, flag leader failovers and `>100 bps` per-asset breaches, and render a live price-board TUI, JSON snapshot, and Prometheus metrics
    - `telemetry/host.mjs` streams EVM RPC receipts and `--telemetry-port` HTTP/SSE node events into `out/telemetry_wasm.wasm`, serving `/status` and `/metrics` via `--metrics-port`
14. **`infra/` & `scripts/`**:
    - `infra/Caddyfile`: Default loopback TLS reverse proxy (`127.0.0.1:9001`–`:9003`) forwarding live Hyperliquid, Binance (`data-api.binance.vision`), and Coinbase feeds for `feracle-demo` and `scripts/dev-telemetry.sh`
    - `infra/mock_feeds.py` (`[Python 3]`): Deterministic local mock HTTP servers used for `--mock-feeds` offline runs and E2E outlier fault-injection suites (with `--outlier-port`)
    - `scripts/ensure-deps.sh`, `scripts/install.sh`, `scripts/build-feracle.sh`, `scripts/build-wasm.sh`, `scripts/e2e.sh`, `scripts/e2e-telemetry.sh`, `scripts/dev-telemetry.sh`

## Quickstart (Prebuilt Binaries)

Install `feracle`, `feracle-telemetry`, and the local devnet launcher (`feracle-demo`) into `~/.local/bin` (downloads the release archive for `linux-x86_64`, `linux-arm64`, or `darwin-arm64`, or falls back to building from source). Missing runtime dependencies (`anvil`/`cast`, `Node.js >= 20`, `caddy`) are installed automatically on first run or upfront with `--install-deps`:

```bash
curl -fsSL https://raw.githubusercontent.com/highestagent/feracle/main/scripts/install.sh | bash
```

Optional installer flags: `--prefix <DIR>`, `--version <TAG>`, `--archive <PATH>` (install a CI artifact tarball), `--install-foundry`, and `--install-deps`. Ensure `~/.local/bin` is on your `PATH`, then run:

```bash
feracle                      # print node CLI options (or pass flags to run)
feracle-telemetry --help     # WASM telemetry collector options
feracle-demo                 # local Anvil + 3 nodes + Caddy live feeds + telemetry TUI
feracle-demo --backend udp   # switch P2P transport (libp2p | tcp | udp)
feracle-demo --mock-feeds    # run offline with deterministic mock_feeds.py
```

## Build & Test

**Prerequisites:** Missing dependencies (`fe`, Rust `cargo`, Foundry, `Node.js >= 20`, `caddy`) are installed automatically when needed by `scripts/install.sh`, `feracle-demo`, `scripts/dev-telemetry.sh`, `scripts/e2e.sh`, and `scripts/e2e-telemetry.sh` (or via `scripts/ensure-deps.sh`). `python3` is only needed for `--mock-feeds` or the E2E suites.

### Build from source

Clone and install to `~/.local/bin`, or build artifacts in-place under `out/` and `ingots/evm/out/`:

```bash
git clone https://github.com/highestagent/feracle.git && cd feracle

# Option A: build and install wrappers to ~/.local/bin
./scripts/install.sh --from-source

# Option B: build artifacts in-place and run directly
fe build --emit abi,bytecode --out-dir ingots/evm/out ingots/evm
./scripts/build-wasm.sh
./scripts/build-feracle.sh

./out/feracle                   # native oracle node (prints CLI help with no args)
node telemetry/host.mjs --help  # WASM telemetry collector
```

> **Private keys:** Set `FERACLE_PRIVKEY_HEX` via the environment instead of passing `--privkey-hex` on the command line so signing keys are not exposed in process listings or shell history.

`scripts/build-feracle.sh` links `p2p-shim/target/release/libp2p_shim.a` into `out/feracle` via `fe build --backend native --link`—linking `CoreFoundation` / `SystemConfiguration` framework stubs and `-liconv` on macOS, or `-lpthread -ldl -lm` on Linux.

### Unit tests

```bash
fe test --backend native ingots/cli
fe test --backend native ingots/coro
fe test --backend native ingots/net_reactor
fe test --backend native ingots/http
fe test --backend native ingots/core && fe test ingots/core && fe test --backend wasm ingots/core
fe test ingots/evm
fe test --backend wasm ingots/wasm
fe test --backend native ingots/p2p
fe test --backend native ingots/p2p_udp
fe test --backend native ingots/p2p_tcp
fe check --backend native ingots/p2p_libp2p
cargo test --manifest-path p2p-shim/Cargo.toml
```

### End-to-end & local devnet

```bash
# Consensus & telemetry E2E suites across all 3 P2P backends (uses deterministic mock feeds)
./scripts/e2e.sh
P2P_BACKEND=tcp ./scripts/e2e.sh
P2P_BACKEND=udp ./scripts/e2e.sh
./scripts/e2e-telemetry.sh
P2P_BACKEND=tcp ./scripts/e2e-telemetry.sh
P2P_BACKEND=udp ./scripts/e2e-telemetry.sh

# Interactive live devnet (Anvil + 3 nodes + Caddy live feeds + WASM telemetry TUI)
./scripts/dev-telemetry.sh
# Or run offline with deterministic mock feeds
./scripts/dev-telemetry.sh --mock-feeds
```

> **Live vs. mock feeds:** Live Hyperliquid, Binance (`data-api.binance.vision`), and Coinbase feeds via `infra/Caddyfile` are the default for `feracle-demo` and `scripts/dev-telemetry.sh`. `infra/mock_feeds.py` is only used when `--mock-feeds` is passed or inside the deterministic fault-injection E2E suites (`scripts/e2e.sh` and `scripts/e2e-telemetry.sh`).

## License

Licensed under the [Apache License 2.0](LICENSE).
