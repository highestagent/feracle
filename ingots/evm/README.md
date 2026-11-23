# `evm` — `OffchainMedianOracle` Settlement Contract

The on-chain verification and settlement contract for Feracle, written in Fe for the `sonatina` EVM backend.

## Build & Test

Add the dependency if importing ABI types or selectors:

```toml
[dependencies]
feracle_core = { path = "../core" }
```

Compile ABI and EVM bytecode to `ingots/evm/out/`, or run the contract test suite:

```bash
fe build --emit abi,bytecode --out-dir ingots/evm/out ingots/evm
fe test --backend sonatina ingots/evm
```

---

## Architecture & Settlement Flow

```text
  submitMedians(round_id, prices[20], timestamp, sigs[3])
        │
        ├─▶ Guards: !paused, round_id == current_round, timestamp in (last_updated, block.timestamp],
        │           all 20 prices in [1, MAX_PRICE_U64]
        │
        ├─▶ Digest: prices_hash = keccak_words(prices)
        │           digest      = keccak_words([chainid, address(this), round_id, prices_hash, timestamp])
        │
        ├─▶ Quorum: loop i in 0..QUORUM (3)
        │             v in {27, 28}, 0 < s <= SECP256K1_N_HALF  (EIP-2)
        │             recovered = ecrecover(digest, v, r, s)
        │             assert is_oracle[recovered] && recovered > last_signer
        │
        └─▶ State:  pack 20×u64 prices into 5 storage slots (4 prices/word)
                    current_round += 1, last_updated = timestamp
                    emit MediansSubmitted(round_id, timestamp, btc_price)
```

| Item | Responsibility |
| --- | --- |
| `src/lib.fe` | `OffchainMedianOracle` contract, `OracleMsg` ABI interface, custom `#[error]` types, `#[event]` structs, and packed storage |
| `src/test.fe` | 17 `sonatina` EVM tests covering quorum verification, malleability, ordering, replay, 3-of-4 subsets, governance, and Chainlink view |
| `fe.toml` | Depends only on `feracle_core` (`ASSET_COUNT = 20`, `QUORUM = 3`) |

---

## Contract Interface (`OracleMsg`)

| Method / View | Selector (`sol`) | Behavior |
| --- | --- | --- |
| `submitMedians(uint256,uint256[20],uint256,(uint8,uint256,uint256)[3])` | `0x6d2b8b3f` | Verifies 3 strictly ascending oracle signatures and updates all 20 packed prices atomically |
| `addOracle(address)` / `removeOracle(address)` | `0x...` | Owner-only oracle allowlist management (`OracleAdded` / `OracleRemoved`; rejects `0x0` on add) |
| `transferOwnership(address)` / `acceptOwnership()` | `0x...` | Two-step ownership handoff (`OwnershipTransferStarted` → `OwnershipTransferred`) |
| `pause()` / `unpause()` | `0x...` | Owner-only emergency circuit breaker blocking `submitMedians` (`OraclePaused` / `OracleUnpaused`) |
| `latestPrice(uint256)` | `0x174ed5cc` | Unpacks `(price, last_updated)` for asset index `0..19` |
| `latestPrices()` | `0xda8fa900` | Unpacks all 20 prices plus `last_updated` across 5 storage reads |
| `latestRoundData()` | `0xfeaf968c` | Chainlink AggregatorV3-style tuple `(roundId, btcAnswer, startedAt, updatedAt, answeredInRound)` |
| `decimals()` / `assetCount()` | `0x313ce567` / `0xeafe7a74` | Returns `8` decimals and `20` assets |
| `currentRound()` / `isOracle(address)` | `0x8a19c8bc` / `0xa97e5c93` | Next expected round (`1` at genesis) and oracle authorization status |
| `owner()` / `pendingOwner()` / `paused()` | `0x8da5cb5b` / `0xe30c3978` / `0x5c975abb` | Governance state inspection views |

---

## Trade-offs & Limitations

- **Fixed compile-time `ASSET_COUNT = 20` and `QUORUM = 3`:** Keeping `[u256; 20]` and `[Sig; 3]` fixed avoids dynamic ABI array decoding overhead and packs all 20 `u64` prices (`MAX_PRICE_U64`) into 5 storage slots, yielding ~78.4k warm settlement gas (~195k on Round 1 cold slot initialization). Changing basket size or quorum requires updating `ingots/core` and redeploying.
- **Decoupled liveness via oracle set size:** While settlement requires `QUORUM = 3` sorted signatures, governance can authorize `4+` oracles (`addOracle`), giving fault tolerance (e.g., 3-of-4) without dynamic arrays.
- **`latestRoundData()` returns BTC only:** For Chainlink AggregatorV3 drop-in callers, `latestRoundData()` surfaces asset index `0` (`BTC`, 8 decimals); multi-asset consumers query `latestPrice(asset_id)` or `latestPrices()`.
- **Timestamp monotonicity:** `submitMedians` requires `last_updated < timestamp <= block.timestamp`, limiting settlements to at most once per distinct block second.
