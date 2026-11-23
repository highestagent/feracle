#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/ensure-deps.sh"
ensure_fe
ensure_cargo
ensure_foundry
ensure_python3

RPC_URL="http://127.0.0.1:8545"
CHAIN_ID="31337"
P2P_BACKEND="${P2P_BACKEND:-libp2p}"

ADDR0="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
PK0="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
ADDR1="0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
PK1="0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
ADDR2="0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"
PK2="0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"

LOG_DIR="$(mktemp -d)"
ANVIL_PID=""
FEEDS_PID=""
NODE_PIDS=()

cleanup() {
  local exit_code=$?
  for pid in "${NODE_PIDS[@]:-}"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  if [[ -n "$FEEDS_PID" ]] && kill -0 "$FEEDS_PID" 2>/dev/null; then
    kill "$FEEDS_PID" 2>/dev/null || true
    wait "$FEEDS_PID" 2>/dev/null || true
  fi
  if [[ -n "$ANVIL_PID" ]] && kill -0 "$ANVIL_PID" 2>/dev/null; then
    kill "$ANVIL_PID" 2>/dev/null || true
    wait "$ANVIL_PID" 2>/dev/null || true
  fi

  if [[ $exit_code -ne 0 ]]; then
    echo "=== E2E FAILED (exit=$exit_code); dumping logs from $LOG_DIR ===" >&2
    for f in "$LOG_DIR"/*.log; do
      if [[ -f "$f" ]]; then
        echo "--- $f ---" >&2
        cat "$f" >&2
      fi
    done
  fi
  rm -rf "$LOG_DIR"
  exit "$exit_code"
}
trap cleanup EXIT

echo "[1/7] Building evm and feracle..."
fe build --emit abi,bytecode --out-dir "$ROOT_DIR/ingots/evm/out" "$ROOT_DIR/ingots/evm"
"$ROOT_DIR/scripts/build-feracle.sh"

echo "[2/7] Starting Anvil on port 8545 (chainId=$CHAIN_ID)..."
anvil --port 8545 --chain-id "$CHAIN_ID" >"$LOG_DIR/anvil.log" 2>&1 &
ANVIL_PID=$!

for _ in $(seq 1 50); do
  if cast block-number --rpc-url "$RPC_URL" >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done
cast block-number --rpc-url "$RPC_URL" >/dev/null

echo "[3/7] Deploying OffchainMedianOracle and registering 3 oracles..."
BYTECODE="0x$(tr -d '\r\n' < "$ROOT_DIR/ingots/evm/out/OffchainMedianOracle.bin")"
DEPLOY_JSON="$(cast send --rpc-url "$RPC_URL" --private-key "$PK0" --json --create "$BYTECODE")"
CONTRACT_ADDR="$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["contractAddress"])' <<<"$DEPLOY_JSON")"
echo "Deployed OffchainMedianOracle at $CONTRACT_ADDR"

cast send "$CONTRACT_ADDR" "addOracle(address)" "$ADDR0" --rpc-url "$RPC_URL" --private-key "$PK0" >/dev/null
cast send "$CONTRACT_ADDR" "addOracle(address)" "$ADDR1" --rpc-url "$RPC_URL" --private-key "$PK0" >/dev/null
cast send "$CONTRACT_ADDR" "addOracle(address)" "$ADDR2" --rpc-url "$RPC_URL" --private-key "$PK0" >/dev/null

echo "[4/7] Starting mock feeds on ports 9001, 9002, 9003..."
python3 "$ROOT_DIR/infra/mock_feeds.py" >"$LOG_DIR/feeds.log" 2>&1 &
FEEDS_PID=$!

for _ in $(seq 1 30); do
  if curl -sf http://127.0.0.1:9003/products/BTC-USD/ticker >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
curl -sf -X POST http://127.0.0.1:9001/info -d '{"type":"allMids"}' >/dev/null
curl -sf "http://127.0.0.1:9002/api/v3/ticker/price?symbol=BTCUSDT" >/dev/null
curl -sf http://127.0.0.1:9003/products/BTC-USD/ticker >/dev/null
curl -sf http://127.0.0.1:9003/products/AAVE-USD/ticker >/dev/null

echo "[5/7] Running Rounds 1 & 2 across 3 native Fe oracle nodes (Top-20 basket, backend=$P2P_BACKEND)..."
"$ROOT_DIR/out/feracle" \
  --node-id 0 --p2p-backend "$P2P_BACKEND" --p2p-port 7001 \
  --sources "hyperliquid=127.0.0.1:9001,binance=127.0.0.1:9002" \
  --privkey-hex "$PK0" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 2 --round-timeout-secs 15 \
  >"$LOG_DIR/node0_r12.log" 2>&1 &
PID0=$!

sleep 0.3
"$ROOT_DIR/out/feracle" \
  --node-id 1 --p2p-backend "$P2P_BACKEND" --p2p-port 7002 \
  --bootstrap "/ip4/127.0.0.1/tcp/7001" \
  --sources "binance=127.0.0.1:9002,coinbase=127.0.0.1:9003" \
  --privkey-hex "$PK1" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 2 --round-timeout-secs 15 \
  >"$LOG_DIR/node1_r12.log" 2>&1 &
PID1=$!

"$ROOT_DIR/out/feracle" \
  --node-id 2 --p2p-backend "$P2P_BACKEND" --p2p-port 7003 \
  --bootstrap "/ip4/127.0.0.1/tcp/7001,/ip4/127.0.0.1/tcp/7002" \
  --sources "hyperliquid=127.0.0.1:9001,coinbase=127.0.0.1:9003" \
  --privkey-hex "$PK2" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 2 --round-timeout-secs 15 \
  >"$LOG_DIR/node2_r12.log" 2>&1 &
PID2=$!

NODE_PIDS=("$PID0" "$PID1" "$PID2")
wait "$PID0"
wait "$PID1"
wait "$PID2"
NODE_PIDS=()

echo "[6/7] Asserting on-chain Top-20 prices and single-tx-per-round leader rotation..."
ASSET_COUNT_VAL="$(cast call "$CONTRACT_ADDR" "assetCount()(uint256)" --rpc-url "$RPC_URL" | awk '{print $1}')"
CUR_ROUND="$(cast call "$CONTRACT_ADDR" "currentRound()(uint256)" --rpc-url "$RPC_URL" | awk '{print $1}')"
BTC_RAW="$(cast call "$CONTRACT_ADDR" "latestPrice(uint256)(uint256,uint256)" 0 --rpc-url "$RPC_URL")"
AAVE_RAW="$(cast call "$CONTRACT_ADDR" "latestPrice(uint256)(uint256,uint256)" 19 --rpc-url "$RPC_URL")"
python3 - "$RPC_URL" "$CONTRACT_ADDR" "$ASSET_COUNT_VAL" "$CUR_ROUND" "$BTC_RAW" "$AAVE_RAW" "$ADDR1" "$ADDR2" <<'PY'
import json
import sys
import urllib.request

rpc_url, contract, asset_count, cur_round, btc_raw, aave_raw, addr1, addr2 = sys.argv[1:]
assert int(asset_count) == 20, f"expected assetCount=20, got {asset_count}"
assert int(cur_round) == 3, f"expected currentRound=3, got {cur_round}"

def rpc(method, params):
    req = urllib.request.Request(
        rpc_url,
        data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read().decode())["result"]

# latestPrices() == 0xda8fa900
lp_hex = rpc("eth_call", [{"to": contract, "data": "0xda8fa900"}, "latest"])
raw = lp_hex[2:]
assert len(raw) == 21 * 64, f"unexpected latestPrices() words len={len(raw)}"
prices = [int(raw[i * 64:(i + 1) * 64], 16) for i in range(20)]
last_updated = int(raw[20 * 64:21 * 64], 16)

assert all(p > 0 for p in prices), f"found zero price in {prices}"
assert 9244800000000 <= prices[0] <= 9245500000000, f"BTC price out of range: {prices[0]}"
assert 341980000000 <= prices[1] <= 342210000000, f"ETH price out of range: {prices[1]}"
assert 31820000000 <= prices[19] <= 31890000000, f"AAVE price out of range: {prices[19]}"
assert last_updated > 0

btc_p = int(btc_raw.splitlines()[0].strip().split()[0])
aave_p = int(aave_raw.splitlines()[0].strip().split()[0])
assert btc_p == prices[0] and aave_p == prices[19]

tip = int(rpc("eth_blockNumber", []), 16)
submit_txs = []
for b in range(1, tip + 1):
    blk = rpc("eth_getBlockByNumber", [hex(b), True])
    for tx in blk["transactions"]:
        to_addr = (tx.get("to") or "").lower()
        inp = tx.get("input", "").lower()
        if to_addr == contract.lower() and inp.startswith("0x6d2b8b3f"):
            submit_txs.append(tx)

assert len(submit_txs) == 2, f"expected 2 submitMedians txs, got {len(submit_txs)}"
assert submit_txs[0]["from"].lower() == addr1.lower(), f"round 1 leader mismatch: {submit_txs[0]['from']}"
assert submit_txs[1]["from"].lower() == addr2.lower(), f"round 2 leader mismatch: {submit_txs[1]['from']}"
print(
    f"Verified Rounds 1 & 2 (20 assets): currentRound=3, btc={prices[0]}, eth={prices[1]}, "
    f"aave={prices[19]}, submit_txs=2 (leaders: {addr1}, {addr2})"
)
PY

echo "[7/7] Testing outlier fault tolerance (Round 3A tolerance guard + Round 3B 3-source median immunity)..."
kill "$FEEDS_PID"
wait "$FEEDS_PID" 2>/dev/null || true
FEEDS_PID=""

python3 "$ROOT_DIR/infra/mock_feeds.py" --outlier-port 9003 --outlier-asset BTC --outlier-price 999999.00 >"$LOG_DIR/feeds_outlier.log" 2>&1 &
FEEDS_PID=$!
for _ in $(seq 1 30); do
  if curl -sf http://127.0.0.1:9003/products/BTC-USD/ticker >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

# 3A: 2-source configs cause tolerance guard breach on Node 0 (no on-chain write)
"$ROOT_DIR/out/feracle" \
  --node-id 0 --p2p-backend "$P2P_BACKEND" --p2p-port 7101 \
  --sources "hyperliquid=127.0.0.1:9001,binance=127.0.0.1:9002" \
  --privkey-hex "$PK0" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 1 --round-timeout-secs 6 \
  >"$LOG_DIR/node0_r3a.log" 2>&1 &
PID0=$!

sleep 0.3
"$ROOT_DIR/out/feracle" \
  --node-id 1 --p2p-backend "$P2P_BACKEND" --p2p-port 7102 \
  --bootstrap "/ip4/127.0.0.1/tcp/7101" \
  --sources "binance=127.0.0.1:9002,coinbase=127.0.0.1:9003" \
  --privkey-hex "$PK1" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 1 --round-timeout-secs 6 \
  >"$LOG_DIR/node1_r3a.log" 2>&1 &
PID1=$!

"$ROOT_DIR/out/feracle" \
  --node-id 2 --p2p-backend "$P2P_BACKEND" --p2p-port 7103 \
  --bootstrap "/ip4/127.0.0.1/tcp/7101,/ip4/127.0.0.1/tcp/7102" \
  --sources "hyperliquid=127.0.0.1:9001,coinbase=127.0.0.1:9003" \
  --privkey-hex "$PK2" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 1 --round-timeout-secs 6 \
  >"$LOG_DIR/node2_r3a.log" 2>&1 &
PID2=$!

NODE_PIDS=("$PID0" "$PID1" "$PID2")
wait "$PID0"
wait "$PID1"
wait "$PID2"
NODE_PIDS=()

grep -q "tolerance guard breached on BTC" "$LOG_DIR/node0_r3a.log"
CUR_ROUND_3A="$(cast call "$CONTRACT_ADDR" "currentRound()(uint256)" --rpc-url "$RPC_URL" | awk '{print $1}')"
BTC_RAW_3A="$(cast call "$CONTRACT_ADDR" "latestPrice(uint256)(uint256,uint256)" 0 --rpc-url "$RPC_URL")"
python3 - "$RPC_URL" "$CONTRACT_ADDR" "$CUR_ROUND_3A" "$BTC_RAW_3A" <<'PY'
import json, sys, urllib.request
rpc_url, contract, cur_round, btc_raw = sys.argv[1:]
assert int(cur_round) == 3, f"3A expected currentRound=3, got {cur_round}"
price = int([l.strip().split()[0] for l in btc_raw.strip().splitlines() if l.strip()][0])
assert 9244800000000 <= price <= 9245500000000, f"3A outlier leaked on-chain: {price}"
assert price != 99999900000000

def rpc(method, params):
    req = urllib.request.Request(
        rpc_url,
        data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read().decode())["result"]

tip = int(rpc("eth_blockNumber", []), 16)
count = sum(
    1
    for b in range(1, tip + 1)
    for tx in rpc("eth_getBlockByNumber", [hex(b), True])["transactions"]
    if (tx.get("to") or "").lower() == contract.lower()
    and tx.get("input", "").lower().startswith("0x6d2b8b3f")
)
assert count == 2, f"3A expected submit_txs=2, got {count}"
print(f"Verified Round 3A (Tolerance Guard): BTC outlier rejected, currentRound=3, btc={price}, submit_txs=2")
PY

# 3B: 3-source median immunity against outlier on 9003 (leader for round 3 is 3 % 3 = Node 0)
ALL_SOURCES="hyperliquid=127.0.0.1:9001,binance=127.0.0.1:9002,coinbase=127.0.0.1:9003"
"$ROOT_DIR/out/feracle" \
  --node-id 0 --p2p-backend "$P2P_BACKEND" --p2p-port 7201 \
  --sources "$ALL_SOURCES" \
  --privkey-hex "$PK0" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 1 --round-timeout-secs 15 \
  >"$LOG_DIR/node0_r3b.log" 2>&1 &
PID0=$!

sleep 0.3
"$ROOT_DIR/out/feracle" \
  --node-id 1 --p2p-backend "$P2P_BACKEND" --p2p-port 7202 \
  --bootstrap "/ip4/127.0.0.1/tcp/7201" \
  --sources "$ALL_SOURCES" \
  --privkey-hex "$PK1" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 1 --round-timeout-secs 15 \
  >"$LOG_DIR/node1_r3b.log" 2>&1 &
PID1=$!

"$ROOT_DIR/out/feracle" \
  --node-id 2 --p2p-backend "$P2P_BACKEND" --p2p-port 7203 \
  --bootstrap "/ip4/127.0.0.1/tcp/7201,/ip4/127.0.0.1/tcp/7202" \
  --sources "$ALL_SOURCES" \
  --privkey-hex "$PK2" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 1 --round-timeout-secs 15 \
  >"$LOG_DIR/node2_r3b.log" 2>&1 &
PID2=$!

NODE_PIDS=("$PID0" "$PID1" "$PID2")
wait "$PID0"
wait "$PID1"
wait "$PID2"
NODE_PIDS=()

CUR_ROUND_3B="$(cast call "$CONTRACT_ADDR" "currentRound()(uint256)" --rpc-url "$RPC_URL" | awk '{print $1}')"
BTC_RAW_3B="$(cast call "$CONTRACT_ADDR" "latestPrice(uint256)(uint256,uint256)" 0 --rpc-url "$RPC_URL")"
python3 - "$RPC_URL" "$CONTRACT_ADDR" "$CUR_ROUND_3B" "$BTC_RAW_3B" "$ADDR0" <<'PY'
import json, sys, urllib.request
rpc_url, contract, cur_round, btc_raw, addr0 = sys.argv[1:]
assert int(cur_round) == 4, f"3B expected currentRound=4, got {cur_round}"
price = int([l.strip().split()[0] for l in btc_raw.strip().splitlines() if l.strip()][0])
assert price == 9245500000000, f"3B expected exact BTC median 9245500000000, got {price}"

def rpc(method, params):
    req = urllib.request.Request(
        rpc_url,
        data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read().decode())["result"]

tip = int(rpc("eth_blockNumber", []), 16)
submit_txs = [
    tx
    for b in range(1, tip + 1)
    for tx in rpc("eth_getBlockByNumber", [hex(b), True])["transactions"]
    if (tx.get("to") or "").lower() == contract.lower()
    and tx.get("input", "").lower().startswith("0x6d2b8b3f")
]
assert len(submit_txs) == 3, f"3B expected submit_txs=3, got {len(submit_txs)}"
assert submit_txs[2]["from"].lower() == addr0.lower(), f"round 3 leader mismatch: {submit_txs[2]['from']}"
print(f"Verified Round 3B (3-Source Outlier Immunity): currentRound=4, btc={price}, submit_txs=3 (leader: {addr0})")
PY

echo "ALL E2E CHECKS PASSED!"
