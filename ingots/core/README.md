# `core` (`feracle_core`) — Target-Independent Oracle Core

The shared oracle library compiled identically across Fe's `native`, `sonatina` (EVM), and `wasm` backends. Declared as `feracle_core` in `fe.toml` so it never shadows Fe's builtin `core` ingot.

## Quick Start

Add the dependency to `fe.toml`:

```toml
[dependencies]
feracle_core = { path = "../core" }
```

Use canonical protocol constants, fixed-point parsing, tolerance math, signed wire codecs, and EIP-1559 transaction RLP encoders directly across targets:

```fe
use feracle_core::{
    ASSET_COUNT,
    MAX_TOLERANCE_BPS,
    PRICE_SCALE,
    parse_decimal_1e8,
    within_tolerance_bps,
}

fn check_quote() {
    let local = parse_decimal_1e8("92451.00").unwrap()
    let peer = parse_decimal_1e8("92500.00").unwrap()
    assert!(local == 92451 * PRICE_SCALE)
    assert!(ASSET_COUNT == 20)
    assert!(within_tolerance_bps(local, proposed: peer, max_bps: MAX_TOLERANCE_BPS))
}
```

---

## Architecture

```text
  ingots/core (feracle_core — pure Fe, zero std::net / std::evm / std::wasm deps)
    ├─ Native (`ingots/feracle`) ──▶ feed parsing, tolerance guard, EIP-1559/155 RLP, 0x00/0x01 codecs
    ├─ EVM    (`ingots/evm`)     ──▶ `ASSET_COUNT = 20`, `QUORUM = 3` compile-time constants
    └─ WASM   (`ingots/wasm`)    ──▶ JSON-RPC / ABI decoders, wire decoders, deviation bps math
```

| Module | Responsibility |
| --- | --- |
| `src/lib.fe` | Public re-exports across all protocol, codec, math, and RLP helpers |
| `src/assets.fe` | `ASSET_COUNT = 20`, `NODE_COUNT = 4`, `QUORUM = 3`, `MAX_TOLERANCE_BPS = 100`, `PRICE_SCALE = 100_000_000`, `BTC..AAVE` symbols |
| `src/math.fe` | `median_of_three`/`four`, `u128`-safe `within_tolerance_bps`, `signed_bps_diff`, `worst_quote_deviation`, float-free `parse_decimal_1e8`, `leader_index` |
| `src/wire.fe` | Canonical 262-byte `QuoteMsg` (`0x00`) & `SigMsg` (`0x01`) codecs, 220-byte `feracle-quote-v1` preimage, `add_sig_dedup`, `sort_three_sigs` |
| `src/abi.fe` | Solidity ABI selectors (`SEL_*`), 996-byte `encode_submit_medians_calldata`, and 32-byte word / `latestPrices()` decoders |
| `src/rlp.fe` | EIP-1559 type-2 (`0x02 \|\| rlp(...)`) and legacy EIP-155 tx RLP encoders, `parse_fee_history_result`, `compute_eip1559_fees`, `bump_fee_wei` |
| `src/json.fe` | Zero-allocation JSON slice scanners (`json_get_raw`, `json_get_u64`, `json_get_bool`, array/object iterators) |
| `src/hex.fe` | Hex decoders/formatters for 20-byte addresses, 32-byte hashes, and `u64`/`u128` scalars |
| `src/test.fe` | 10 pure cross-target unit tests |

---

## Testing

Verify parity across all three compiler backends:

```bash
fe test --backend native ingots/core
fe test --backend sonatina ingots/core
fe test --backend wasm ingots/core
```

---

## Trade-offs & Limitations

- **`u64` fixed-point prices (`1e8`):** Exchange prices are scaled by `100_000_000` into `u64` (saturating/rejecting above `MAX_PRICE_U64` on-chain) so cross-target arithmetic uses native integers without floating point.
- **Zero-copy slice scanning:** `json.fe` and `abi.fe` walk `MemSpan` directly rather than building DOM trees, assuming well-formed ASCII JSON from exchanges and JSON-RPC endpoints.
- **No external runtime effects:** Keeping `feracle_core` effect-free lets `feracle`, `evm`, and `wasm` share one source of truth, at the cost of putting secp256k1/keccak implementations in host/VM bindings (`p2p-shim` natively, `std::evm::crypto` on-chain).

---

## Core API Summary

| Symbol | Role |
| --- | --- |
| `ASSET_COUNT`, `NODE_COUNT`, `QUORUM`, `MAX_TOLERANCE_BPS` | Protocol constants (`20`, `4`, `3`, `100`) |
| `QuoteMsg`, `SigMsg` | 262-byte fixed wire structs (`encode_quote*`, `decode_quote*`, `encode_sig_msg*`, `decode_sig_msg*`) |
| `encode_quote_sign_preimage` | Builds the 220-byte `feracle-quote-v1` domain-separated quote preimage |
| `sort_three_sigs`, `add_sig_dedup` | Deduplicates and sorts 3 signatures by ascending `signer_addr` to match EVM verification |
| `encode_submit_medians_calldata`, `decode_latest_prices_abi_hex` | Calldata encoder and 21-word `latestPrices()` ABI hex decoder |
| `encode_eip1559_signed_tx`, `encode_eip155_signed_tx` | EIP-1559 type-2 and legacy EIP-155 raw transaction RLP encoders |
| `parse_fee_history_result`, `compute_eip1559_fees`, `bump_fee_wei` | EIP-1559 base/priority fee estimation and replacement bump math |
