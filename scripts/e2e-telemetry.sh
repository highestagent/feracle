#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/ensure-deps.sh"
ensure_fe
ensure_cargo
ensure_foundry
ensure_node
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
ADDR3="0x90F79bf6EB2c4f870365E785982E1f101E93b906"
PK3="0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6"

LOG_DIR="$(mktemp -d)"
ANVIL_PID=""
FEEDS_PID=""
EXTRA_FEEDS_PID=""
HOST_PID=""
NODE_PIDS=()

cleanup() {
  local exit_code=$?
  for pid in "${NODE_PIDS[@]:-}"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  for pid in "$HOST_PID" "$EXTRA_FEEDS_PID" "$FEEDS_PID" "$ANVIL_PID"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done

  if [[ $exit_code -ne 0 ]]; then
    echo "=== TELEMETRY E2E FAILED (exit=$exit_code); dumping logs from $LOG_DIR ===" >&2
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

echo "[1/9] Building evm, feracle, and telemetry wasm..."
fe build --emit abi,bytecode --out-dir ingots/evm/out ingots/evm
"$ROOT_DIR/scripts/build-feracle.sh"
"$ROOT_DIR/scripts/build-wasm.sh"

echo "[2/9] Starting Anvil on port 8545 (chainId=$CHAIN_ID)..."
anvil --port 8545 --chain-id "$CHAIN_ID" >"$LOG_DIR/anvil.log" 2>&1 &
ANVIL_PID=$!
for _ in $(seq 1 50); do
  if cast block-number --rpc-url "$RPC_URL" >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done
cast block-number --rpc-url "$RPC_URL" >/dev/null

echo "[3/9] Deploying OffchainMedianOracle and registering 4 oracles..."
BYTECODE="0x$(tr -d '\r\n' < "$ROOT_DIR/ingots/evm/out/OffchainMedianOracle.bin")"
DEPLOY_JSON="$(cast send --rpc-url "$RPC_URL" --private-key "$PK0" --json --create "$BYTECODE")"
CONTRACT_ADDR="$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["contractAddress"])' <<<"$DEPLOY_JSON")"
echo "Deployed OffchainMedianOracle at $CONTRACT_ADDR"

cast send "$CONTRACT_ADDR" "addOracle(address)" "$ADDR0" --rpc-url "$RPC_URL" --private-key "$PK0" >/dev/null
cast send "$CONTRACT_ADDR" "addOracle(address)" "$ADDR1" --rpc-url "$RPC_URL" --private-key "$PK0" >/dev/null
cast send "$CONTRACT_ADDR" "addOracle(address)" "$ADDR2" --rpc-url "$RPC_URL" --private-key "$PK0" >/dev/null
cast send "$CONTRACT_ADDR" "addOracle(address)" "$ADDR3" --rpc-url "$RPC_URL" --private-key "$PK0" >/dev/null

echo "[4/9] Starting mock feeds and live Node.js WASM telemetry collector (:9200)..."
python3 "$ROOT_DIR/infra/mock_feeds.py" >"$LOG_DIR/feeds.log" 2>&1 &
FEEDS_PID=$!
for _ in $(seq 1 30); do
  if curl -sf http://127.0.0.1:9003/products/BTC-USD/ticker >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

node "$ROOT_DIR/telemetry/host.mjs" \
  --rpc-url "$RPC_URL" \
  --contract "$CONTRACT_ADDR" \
  --oracles "$ADDR0,$ADDR1,$ADDR2,$ADDR3" \
  --nodes "http://127.0.0.1:9101,http://127.0.0.1:9102,http://127.0.0.1:9103,http://127.0.0.1:9104" \
  --interval-ms 300 \
  --mode json \
  --no-ansi \
  --metrics-port 9200 \
  >"$LOG_DIR/telemetry_host.log" 2>&1 &
HOST_PID=$!

for _ in $(seq 1 30); do
  if curl -sf http://127.0.0.1:9200/status >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
curl -sf http://127.0.0.1:9200/status >/dev/null

echo "[5/9] Running Rounds 1 & 2 across 4 nodes with --telemetry-port 9101..9104 (Top-20 basket, backend=$P2P_BACKEND)..."
"$ROOT_DIR/out/feracle" \
  --node-id 0 --p2p-backend "$P2P_BACKEND" --p2p-port 7001 --telemetry-port 9101 \
  --sources "hyperliquid=127.0.0.1:9001,binance=127.0.0.1:9002" \
  --privkey-hex "$PK0" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 2 --round-timeout-secs 15 \
  >"$LOG_DIR/node0_r12.log" 2>&1 &
PID0=$!

sleep 0.3
"$ROOT_DIR/out/feracle" \
  --node-id 1 --p2p-backend "$P2P_BACKEND" --p2p-port 7002 --telemetry-port 9102 \
  --bootstrap "/ip4/127.0.0.1/tcp/7001" \
  --sources "binance=127.0.0.1:9002,coinbase=127.0.0.1:9003" \
  --privkey-hex "$PK1" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 2 --round-timeout-secs 15 \
  >"$LOG_DIR/node1_r12.log" 2>&1 &
PID1=$!

"$ROOT_DIR/out/feracle" \
  --node-id 2 --p2p-backend "$P2P_BACKEND" --p2p-port 7003 --telemetry-port 9103 \
  --bootstrap "/ip4/127.0.0.1/tcp/7001,/ip4/127.0.0.1/tcp/7002" \
  --sources "hyperliquid=127.0.0.1:9001,coinbase=127.0.0.1:9003" \
  --privkey-hex "$PK2" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 2 --round-timeout-secs 15 \
  >"$LOG_DIR/node2_r12.log" 2>&1 &
PID2=$!

"$ROOT_DIR/out/feracle" \
  --node-id 3 --p2p-backend "$P2P_BACKEND" --p2p-port 7004 --telemetry-port 9104 \
  --bootstrap "/ip4/127.0.0.1/tcp/7001,/ip4/127.0.0.1/tcp/7002,/ip4/127.0.0.1/tcp/7003" \
  --sources "hyperliquid=127.0.0.1:9001,binance=127.0.0.1:9002,coinbase=127.0.0.1:9003" \
  --privkey-hex "$PK3" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 2 --round-timeout-secs 15 \
  >"$LOG_DIR/node3_r12.log" 2>&1 &
PID3=$!
NODE_PIDS=("$PID0" "$PID1" "$PID2" "$PID3")

sleep 1.2
wait "$PID0"
wait "$PID1"
wait "$PID2"
wait "$PID3"
NODE_PIDS=()

echo "[6/9] Asserting deep 20-asset WASM telemetry (JSON /status, Prometheus /metrics, TUI --once)..."
python3 - <<'PY'
import json
import time
import urllib.request

deadline = time.time() + 5.0
snap = None
data = None
while time.time() < deadline:
    with urllib.request.urlopen("http://127.0.0.1:9200/status") as resp:
        data = json.loads(resp.read().decode())
    if (
        data["onchain"]["current_round"] == 3
        and data["onchain"]["latest_price"] == 9245100000000
        and len(data["onchain"]["prices"]) == 20
        and len(data["rounds"]) >= 2
        and all(r["tx_count"] == 1 and r["gas_used"] > 0 for r in data["rounds"])
        and data["onchain"]["has_tx_data"]
        and len(data["wire"]["quotes"]) >= 4
        and len(data["wire"]["sigs"]) >= 3
    ):
        snap = data
        break
    time.sleep(0.2)

assert snap is not None, f"timed out waiting for converged telemetry snapshot; last={data}"
assert snap["protocol"]["asset_count"] == 20
assert snap["protocol"]["quorum"] == 3
assert snap["protocol"]["node_count"] == 4
assert snap["protocol"]["max_tolerance_bps"] == 100
assert snap["onchain"]["connected"] is True
assert snap["onchain"]["chain_id"] == 31337
assert snap["onchain"]["last_tx_gas"] > 0
assert snap["onchain"]["tx_invariant_ok"] is True
assert snap["onchain"]["last_tx_failover"] is False

prices = snap["onchain"]["prices"]
assert len(prices) == 20
assert all(p["price"] > 0 for p in prices), prices
assert prices[0]["symbol"] == "BTC" and prices[0]["price"] == 9245100000000
assert prices[1]["symbol"] == "ETH" and 341980000000 <= prices[1]["price"] <= 342210000000
assert prices[19]["symbol"] == "AAVE" and 31820000000 <= prices[19]["price"] <= 31890000000

assert snap["wire"]["active_round"] == 2
assert snap["wire"]["group_median"] == 9245100000000
assert len(snap["wire"]["group_medians"]) == 20
assert snap["wire"]["breach_detected"] is False
assert snap["wire"]["breach_asset"] == -1
assert snap["wire"]["decode_errors"] == 0

assert len(snap["nodes"]) == 4
for n in snap["nodes"]:
    assert n["is_authorized_onchain"] is True, f"node {n['node_id']} not authorized"
    assert n["seen"] is True, f"node {n['node_id']} tap never observed"
    assert len(n["feeds"]) >= 2, f"node {n['node_id']} missing feed telemetry: {n['feeds']}"
    assert all(f["assets_ok"] == 20 for f in n["feeds"]), f"expected 20/20 assets on feeds: {n['feeds']}"

with urllib.request.urlopen("http://127.0.0.1:9200/metrics") as resp:
    metrics = resp.read().decode()
assert "feracle_asset_count 20\n" in metrics, metrics
assert "feracle_latest_price_1e8 9245100000000\n" in metrics, metrics
assert f'feracle_asset_price_1e8{{asset="ETH"}} {prices[1]["price"]}\n' in metrics, metrics
assert f'feracle_asset_price_1e8{{asset="AAVE"}} {prices[19]["price"]}\n' in metrics, metrics
assert "feracle_current_round 3\n" in metrics, metrics
assert "feracle_tx_per_round_ok 1\n" in metrics, metrics
assert 'feracle_node_authorized{node="0"} 1\n' in metrics, metrics
assert 'feracle_node_authorized{node="3"} 1\n' in metrics, metrics
assert 'feracle_feed_assets_ok{node="0"' in metrics, metrics

print(
    f"Verified Rounds 1 & 2 WASM telemetry (4-of-4, 20 assets): btc=$92,451.00, "
    f"eth={prices[1]['price']}, aave={prices[19]['price']}, round=3, "
    f"gas={snap['onchain']['last_tx_gas']}, wire_quotes={len(snap['wire']['quotes'])}, "
    f"wire_sigs={len(snap['wire']['sigs'])}"
)
PY

TUI_OUT="$(node "$ROOT_DIR/telemetry/host.mjs" \
  --rpc-url "$RPC_URL" \
  --contract "$CONTRACT_ADDR" \
  --oracles "$ADDR0,$ADDR1,$ADDR2,$ADDR3" \
  --mode tui --no-ansi --once)"
echo "$TUI_OUT" | grep -q "FERACLE"
echo "$TUI_OUT" | grep -q "BTC"
echo "$TUI_OUT" | grep -q "ETH"
echo "$TUI_OUT" | grep -q "SOL"
echo "$TUI_OUT" | grep -q "AAVE"
echo "$TUI_OUT" | grep -q "\$92,451.00"
echo "$TUI_OUT" | grep -q "Assets: 20"
echo "$TUI_OUT" | grep -q "OK (1 tx/round)"

JSON_ONCE="$(node "$ROOT_DIR/telemetry/host.mjs" \
  --rpc-url "$RPC_URL" \
  --contract "$CONTRACT_ADDR" \
  --oracles "$ADDR0,$ADDR1,$ADDR2,$ADDR3" \
  --mode json --once)"
python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); assert d["protocol"]["asset_count"]==20 and len(d["onchain"]["prices"])==20 and d["onchain"]["latest_price"]==9245100000000' <<<"$JSON_ONCE"

echo "[7/9] Verifying Round 3 (3-of-4 liveness + leader failover telemetry)..."
"$ROOT_DIR/out/feracle" \
  --node-id 0 --p2p-backend "$P2P_BACKEND" --p2p-port 7051 --telemetry-port 9101 \
  --sources "hyperliquid=127.0.0.1:9001,binance=127.0.0.1:9002" \
  --privkey-hex "$PK0" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 1 --round-timeout-secs 6 \
  >"$LOG_DIR/node0_r3_liveness.log" 2>&1 &
PID0=$!

sleep 0.3
"$ROOT_DIR/out/feracle" \
  --node-id 1 --p2p-backend "$P2P_BACKEND" --p2p-port 7052 --telemetry-port 9102 \
  --bootstrap "/ip4/127.0.0.1/tcp/7051" \
  --sources "binance=127.0.0.1:9002,coinbase=127.0.0.1:9003" \
  --privkey-hex "$PK1" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 1 --round-timeout-secs 6 \
  >"$LOG_DIR/node1_r3_liveness.log" 2>&1 &
PID1=$!

"$ROOT_DIR/out/feracle" \
  --node-id 2 --p2p-backend "$P2P_BACKEND" --p2p-port 7053 --telemetry-port 9103 \
  --bootstrap "/ip4/127.0.0.1/tcp/7051,/ip4/127.0.0.1/tcp/7052" \
  --sources "hyperliquid=127.0.0.1:9001,coinbase=127.0.0.1:9003" \
  --privkey-hex "$PK2" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 1 --round-timeout-secs 6 \
  >"$LOG_DIR/node2_r3_liveness.log" 2>&1 &
PID2=$!
NODE_PIDS=("$PID0" "$PID1" "$PID2")

wait "$PID0"
wait "$PID1"
wait "$PID2"
NODE_PIDS=()

python3 - <<'PY'
import json
import time
import urllib.request

deadline = time.time() + 5.0
snap = None
data = None
while time.time() < deadline:
    with urllib.request.urlopen("http://127.0.0.1:9200/status") as resp:
        data = json.loads(resp.read().decode())
    if (
        data["onchain"]["current_round"] == 4
        and data["onchain"]["latest_price"] == 9245150000000
        and any(r["round_id"] == 3 and r["failover"] is True and r["tx_count"] == 1 for r in data["rounds"])
    ):
        snap = data
        break
    time.sleep(0.2)

assert snap is not None, f"timed out waiting for Round 3 failover telemetry; last={data}"
assert snap["onchain"]["last_tx_failover"] is True
assert snap["onchain"]["tx_invariant_ok"] is True
assert snap["nodes"][3]["online"] is False
print("Verified Round 3 telemetry: current_round=4, btc=9245150000000, failover=True, node3_online=False")
PY

echo "[8/9] Verifying Round 4A ETH outlier breach telemetry..."
kill "$FEEDS_PID"
wait "$FEEDS_PID" 2>/dev/null || true
FEEDS_PID=""

python3 "$ROOT_DIR/infra/mock_feeds.py" --outlier-port 9003 --outlier-asset ETH --outlier-price 99999.00 >"$LOG_DIR/feeds_outlier.log" 2>&1 &
FEEDS_PID=$!
for _ in $(seq 1 30); do
  if curl -sf http://127.0.0.1:9003/products/ETH-USD/ticker >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

"$ROOT_DIR/out/feracle" \
  --node-id 0 --p2p-backend "$P2P_BACKEND" --p2p-port 7101 --telemetry-port 9101 \
  --sources "hyperliquid=127.0.0.1:9001,binance=127.0.0.1:9002" \
  --privkey-hex "$PK0" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 1 --round-timeout-secs 6 \
  >"$LOG_DIR/node0_r4a.log" 2>&1 &
PID0=$!

sleep 0.3
"$ROOT_DIR/out/feracle" \
  --node-id 1 --p2p-backend "$P2P_BACKEND" --p2p-port 7102 --telemetry-port 9102 \
  --bootstrap "/ip4/127.0.0.1/tcp/7101" \
  --sources "binance=127.0.0.1:9002,coinbase=127.0.0.1:9003" \
  --privkey-hex "$PK1" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 1 --round-timeout-secs 6 \
  >"$LOG_DIR/node1_r4a.log" 2>&1 &
PID1=$!

"$ROOT_DIR/out/feracle" \
  --node-id 2 --p2p-backend "$P2P_BACKEND" --p2p-port 7103 --telemetry-port 9103 \
  --bootstrap "/ip4/127.0.0.1/tcp/7101,/ip4/127.0.0.1/tcp/7102" \
  --sources "hyperliquid=127.0.0.1:9001,coinbase=127.0.0.1:9003" \
  --privkey-hex "$PK2" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 1 --round-timeout-secs 6 \
  >"$LOG_DIR/node2_r4a.log" 2>&1 &
PID2=$!

"$ROOT_DIR/out/feracle" \
  --node-id 3 --p2p-backend "$P2P_BACKEND" --p2p-port 7104 --telemetry-port 9104 \
  --bootstrap "/ip4/127.0.0.1/tcp/7101,/ip4/127.0.0.1/tcp/7102,/ip4/127.0.0.1/tcp/7103" \
  --sources "hyperliquid=127.0.0.1:9001,binance=127.0.0.1:9002,coinbase=127.0.0.1:9003" \
  --privkey-hex "$PK3" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 1 --round-timeout-secs 6 \
  >"$LOG_DIR/node3_r4a.log" 2>&1 &
PID3=$!
NODE_PIDS=("$PID0" "$PID1" "$PID2" "$PID3")

python3 - <<'PY'
import json
import time
import urllib.request

deadline = time.time() + 12.0
caught = None
while time.time() < deadline:
    try:
        with urllib.request.urlopen("http://127.0.0.1:9200/status") as resp:
            data = json.loads(resp.read().decode())
        if (
            data["wire"]["active_round"] == 4
            and data["wire"]["breach_detected"] is True
            and data["wire"]["breach_asset"] == 1
            and data["nodes"][0]["counters"]["tolerance_breaches"] >= 1
        ):
            caught = data
            break
    except Exception:
        pass
    time.sleep(0.25)

assert caught is not None, "telemetry did not observe Round 4A ETH tolerance breach in time"
assert caught["onchain"]["current_round"] == 4
with urllib.request.urlopen("http://127.0.0.1:9200/metrics") as resp:
    metrics = resp.read().decode()
assert "feracle_wire_breach_detected 1\n" in metrics, metrics
assert "feracle_wire_breach_asset 1\n" in metrics, metrics
assert 'feracle_node_tolerance_breaches_total{node="0"} 1\n' in metrics, metrics
print(
    f"Verified Round 4A multi-asset breach telemetry: active_wire_round=4, "
    f"wire_breach_detected=True, wire_breach_asset=1 (ETH), node0_tolerance_breaches={caught['nodes'][0]['counters']['tolerance_breaches']}"
)
PY

wait "$PID0"
wait "$PID1"
wait "$PID2"
wait "$PID3"
NODE_PIDS=()

echo "[9/9] Verifying mid-round restart/rejoin and unauthorized rogue rejection telemetry (Rounds 4 & 5)..."
kill "$FEEDS_PID"
wait "$FEEDS_PID" 2>/dev/null || true
FEEDS_PID=""

python3 "$ROOT_DIR/infra/mock_feeds.py" >"$LOG_DIR/feeds_clean2.log" 2>&1 &
FEEDS_PID=$!
python3 "$ROOT_DIR/infra/mock_feeds.py" \
  --port-hl 9004 --port-binance 9005 --port-coinbase 9006 \
  --price-hl 123456.00 --price-binance 123456.00 --price-coinbase 123456.00 \
  >"$LOG_DIR/feeds_rogue.log" 2>&1 &
EXTRA_FEEDS_PID=$!
for _ in $(seq 1 30); do
  if curl -sf http://127.0.0.1:9003/products/BTC-USD/ticker >/dev/null 2>&1 \
    && curl -sf http://127.0.0.1:9005/api/v3/ticker/price?symbol=BTCUSDT >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

PK4="0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a"
"$ROOT_DIR/out/feracle" \
  --node-id 0 --p2p-backend "$P2P_BACKEND" --p2p-port 7201 --telemetry-port 9101 \
  --sources "hyperliquid=127.0.0.1:9001,binance=127.0.0.1:9002" \
  --privkey-hex "$PK0" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 2 --round-timeout-secs 10 \
  >"$LOG_DIR/node0_r45.log" 2>&1 &
PID0=$!

sleep 0.3
"$ROOT_DIR/out/feracle" \
  --node-id 2 --p2p-backend "$P2P_BACKEND" --p2p-port 7203 --telemetry-port 9103 \
  --bootstrap "/ip4/127.0.0.1/tcp/7201" \
  --sources "hyperliquid=127.0.0.1:9001,coinbase=127.0.0.1:9003" \
  --privkey-hex "$PK2" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 2 --round-timeout-secs 10 \
  >"$LOG_DIR/node2_r45.log" 2>&1 &
PID2=$!
NODE_PIDS=("$PID0" "$PID2")

# Start only {Node 0, Node 2} first so peer_count=1 holds MeshWarmup at 6000ms.
# Wait for Node 2's telemetry listener plus 600ms so signal handlers are armed and
# host.mjs observes Node 2 before SIGTERM, without racing ahead of Node 1 & Node 3.
python3 - "$LOG_DIR/node2_r45.log" "$PID2" <<'PY'
import os, signal, sys, time
log_path, pid = sys.argv[1], int(sys.argv[2])
deadline = time.time() + 12.0
while time.time() < deadline:
    try:
        with open(log_path, "r", encoding="utf-8", errors="ignore") as f:
            if "telemetry HTTP/SSE listening" in f.read():
                time.sleep(0.6)
                os.kill(pid, signal.SIGTERM)
                sys.exit(0)
    except FileNotFoundError:
        pass
    time.sleep(0.01)
raise SystemExit("timed out waiting for Node 2 telemetry listener in telemetry E2E")
PY
wait "$PID2"
grep -q "received shutdown signal" "$LOG_DIR/node2_r45.log"
NODE_PIDS=("$PID0")

"$ROOT_DIR/out/feracle" \
  --node-id 1 --p2p-backend "$P2P_BACKEND" --p2p-port 7202 --telemetry-port 9102 \
  --bootstrap "/ip4/127.0.0.1/tcp/7201" \
  --sources "binance=127.0.0.1:9002,coinbase=127.0.0.1:9003" \
  --privkey-hex "$PK1" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 2 --round-timeout-secs 10 \
  >"$LOG_DIR/node1_r45.log" 2>&1 &
PID1=$!

sleep 0.2
"$ROOT_DIR/out/feracle" \
  --node-id 3 --p2p-backend "$P2P_BACKEND" --p2p-port 7204 --telemetry-port 9104 \
  --bootstrap "/ip4/127.0.0.1/tcp/7201,/ip4/127.0.0.1/tcp/7202" \
  --sources "hyperliquid=127.0.0.1:9001,binance=127.0.0.1:9002,coinbase=127.0.0.1:9003" \
  --privkey-hex "$PK3" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 2 --round-timeout-secs 10 \
  >"$LOG_DIR/node3_r45.log" 2>&1 &
PID3=$!
NODE_PIDS=("$PID0" "$PID1" "$PID3")

python3 - "$RPC_URL" "$CONTRACT_ADDR" <<'PY'
import json, sys, time, urllib.request
rpc_url, contract = sys.argv[1], sys.argv[2]
deadline = time.time() + 25.0
while time.time() < deadline:
    req = urllib.request.Request(
        rpc_url,
        data=json.dumps({"jsonrpc":"2.0","id":1,"method":"eth_call","params":[{"to":contract,"data":"0x8a19c8bc"},"latest"]}).encode(),
        headers={"Content-Type":"application/json"},
    )
    with urllib.request.urlopen(req, timeout=2) as resp:
        res = json.loads(resp.read().decode()).get("result", "0x0")
    if int(res, 16) >= 5:
        sys.exit(0)
    time.sleep(0.05)
raise SystemExit("timed out waiting for Round 4 to settle 3-of-4 in telemetry E2E")
PY

"$ROOT_DIR/out/feracle" \
  --node-id 2 --p2p-backend "$P2P_BACKEND" --p2p-port 7203 --telemetry-port 9103 \
  --bootstrap "/ip4/127.0.0.1/tcp/7201,/ip4/127.0.0.1/tcp/7202,/ip4/127.0.0.1/tcp/7204" \
  --sources "hyperliquid=127.0.0.1:9001,coinbase=127.0.0.1:9003" \
  --privkey-hex "$PK2" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 1 --round-timeout-secs 12 \
  >"$LOG_DIR/node2_r5_rejoin.log" 2>&1 &
PID2_REJOIN=$!

"$ROOT_DIR/out/feracle" \
  --node-id 0 --p2p-backend "$P2P_BACKEND" --p2p-port 7205 \
  --bootstrap "/ip4/127.0.0.1/tcp/7201,/ip4/127.0.0.1/tcp/7202,/ip4/127.0.0.1/tcp/7204" \
  --sources "hyperliquid=127.0.0.1:9004,binance=127.0.0.1:9005" \
  --privkey-hex "$PK4" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 1 --round-timeout-secs 15 \
  >"$LOG_DIR/rogue_r45.log" 2>&1 &
PID_ROGUE=$!
NODE_PIDS=("$PID0" "$PID1" "$PID2_REJOIN" "$PID3" "$PID_ROGUE")

python3 - <<'PY'
import json
import time
import urllib.request

deadline = time.time() + 25.0
snap = None
data = None
saw_node2_online = False
while time.time() < deadline:
    try:
        with urllib.request.urlopen("http://127.0.0.1:9200/status") as resp:
            data = json.loads(resp.read().decode())
        if data["nodes"][2]["online"] is True:
            saw_node2_online = True
        if (
            data["onchain"]["current_round"] == 6
            and data["onchain"]["latest_price"] in (9245100000000, 9245150000000)
            and (saw_node2_online or (data["nodes"][2]["round_id"] >= 5 and data["nodes"][2]["phase"] == "settled"))
        ):
            snap = data
            break
    except Exception:
        pass
    time.sleep(0.1)

assert snap is not None, f"timed out waiting for rejoin + rogue rejection telemetry; last={data}"
assert snap["onchain"]["tx_invariant_ok"] is True
print(
    f"Verified Round 5 rejoin + rogue rejection telemetry: current_round=6, "
    f"btc={snap['onchain']['latest_price']}, node2_round={snap['nodes'][2]['round_id']}, saw_node2_online={saw_node2_online}"
)
PY

wait "$PID0"
wait "$PID1"
wait "$PID2_REJOIN"
wait "$PID3"
kill "$PID_ROGUE" 2>/dev/null || true
wait "$PID_ROGUE" 2>/dev/null || true
NODE_PIDS=()
kill "$EXTRA_FEEDS_PID" 2>/dev/null || true
wait "$EXTRA_FEEDS_PID" 2>/dev/null || true
EXTRA_FEEDS_PID=""

echo "ALL TELEMETRY E2E CHECKS PASSED!"
