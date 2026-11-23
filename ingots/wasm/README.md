# `wasm` — Oracle Telemetry Engine (`telemetry_wasm`)

A standalone WASM module built on `feracle_core` that ingests EVM JSON-RPC responses, transaction receipts, and off-chain `QuoteMsg`/`SigMsg` wire frames, and renders a terminal TUI, JSON snapshot, and Prometheus metrics.

## Build & Test

Build `out/telemetry_wasm.wasm` and its manifest (`out/telemetry_wasm.manifest.json`), or run tests:

```bash
./scripts/build-wasm.sh
fe test --backend wasm ingots/wasm
node --test telemetry/host.test.mjs
```

---

## Architecture

```text
  telemetry/host.mjs (Node.js)
    ├─ eth_getLogs (MediansSubmitted) + eth_call batch ─▶ telemetry_ingest_rpc / telemetry_ingest_tx
    └─ node HTTP /status + SSE /events                 ─▶ telemetry_ingest_node_status / telemetry_ingest_wire_frame
                                                                  │
                                                                  ▼
                                                          TelemetryEngine (WASM)
                                                                  │
        ┌─────────────────────────┬───────────────────────────────┴────────────────────────┐
        ▼                         ▼                                                        ▼
  telemetry_render_tui     telemetry_render_json                                   telemetry_render_prometheus
```

| Module | Responsibility |
| --- | --- |
| `src/lib.fe` | C-style WASM exports (`telemetry_*`), `resolve_engine` null-handle guard, and `Stdout` `Reply` framing |
| `src/state.fe` | `TelemetryEngine` state (`MAX_ORACLES = 4`, `MAX_ROUNDS_HISTORY = 32`, `MAX_WIRE_SLOTS = 16`), failover & `±100 bps` breach detection |
| `src/codec.fe` | RPC batch JSON builder, ABI/hex wrappers over `feracle_core`, USD / bps formatting, and `FixedStr` helpers |
| `src/render.fe` | 20-asset TUI board + sparkline, `/status` JSON serializer, and Prometheus exposition renderer |
| `src/fixed_str.fe` | Stack-allocated fixed-capacity ASCII/JSON string buffer |
| `src/test.fe` | 6 WASM unit tests covering handles, RPC batches, wire breach decoding, tx failover detection, and renderers |

---

## Exported WASM ABI (`src/lib.fe`)

Every export accepts a non-zero `u32` engine handle checked by `resolve_engine` (returning `Reply::error(1)` when null except `telemetry_free`) and writes rendered payloads to `Stdout`:

| Export | Purpose |
| --- | --- |
| `telemetry_new() -> u32` | Allocates a `TelemetryEngine` instance and returns its opaque `u32` handle |
| `telemetry_free(handle)` | Frees the engine instance safely (`0` handle is a no-op) |
| `telemetry_configure(handle, contract_hex, oracles_csv)` | Sets target oracle contract address and authorized oracle addresses |
| `telemetry_build_rpc_batch(handle)` | Emits batched `eth_chainId`, `eth_blockNumber`, `currentRound`, `owner`, `latestPrices`, and `isOracle` JSON-RPC calls |
| `telemetry_ingest_rpc(handle, payload, latency_ms)` | Decodes the JSON-RPC batch response using `feracle_core` |
| `telemetry_ingest_tx(handle, round_id, block_num, gas_used, tx_count, submitter_hex)` | Records settled tx gas, tx count, and expected-vs-actual leader failover status |
| `telemetry_ingest_wire_frame(handle, frame_hex, peer_tag, is_tx)` | Decodes 262-byte `QuoteMsg` (`0x00`) or `SigMsg` (`0x01`) wire frames and checks `±100 bps` deviations |
| `telemetry_ingest_node_status(handle, node_id, payload)` | Updates per-node peers, round phase, local quotes, submission counters, and exchange feed latencies |
| `telemetry_mark_node_offline(handle, node_id)` | Marks an unreachable oracle node offline |
| `telemetry_render_tui(handle, ansi)` | Renders the Top-20 terminal dashboard (with or without ANSI codes) |
| `telemetry_render_json(handle)` | Renders the structured `/status` JSON document |
| `telemetry_render_prometheus(handle)` | Renders Prometheus gauge/counter metrics (`feracle_*`) |

---

## Trade-offs & Limitations

- **Fixed-size telemetry tables:** `MAX_ORACLES = 4`, `MAX_FEEDS_PER_NODE = 4`, `MAX_ROUNDS_HISTORY = 32`, and `MAX_WIRE_SLOTS = 16` bound linear WASM memory without unbounded heap growth.
- **Host-driven I/O:** WASM modules cannot open sockets directly; `telemetry/host.mjs` handles `eth_getLogs` polling, HTTP/SSE node collection, and `/status` + `/metrics` HTTP serving.
