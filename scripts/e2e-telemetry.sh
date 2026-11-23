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

LOG_DIR="$(mktemp -d)"
ANVIL_PID=""
FEEDS_PID=""
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
  for pid in "$HOST_PID" "$FEEDS_PID" "$ANVIL_PID"; do
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

echo "[1/7] Building evm, feracle, and telemetry wasm..."
fe build --emit abi,bytecode --out-dir "$ROOT_DIR/ingots/evm/out" "$ROOT_DIR/ingots/evm"
"$ROOT_DIR/scripts/build-feracle.sh"
"$ROOT_DIR/scripts/build-wasm.sh"

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

echo "[4/7] Starting mock feeds and live Node.js WASM telemetry collector (:9200)..."
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
  --oracles "$ADDR0,$ADDR1,$ADDR2" \
  --nodes "http://127.0.0.1:9101,http://127.0.0.1:9102,http://127.0.0.1:9103" \
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

echo "[5/7] Running Rounds 1 & 2 with --telemetry-port 9101..9103 (Top-20 basket, backend=$P2P_BACKEND)..."
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
NODE_PIDS=("$PID0" "$PID1" "$PID2")

sleep 1.2
wait "$PID0"
wait "$PID1"
wait "$PID2"
NODE_PIDS=()

echo "[6/7] Asserting deep 20-asset WASM telemetry (JSON /status, Prometheus /metrics, TUI --once)..."
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
        and data["onchain"]["latest_price"] == 9245150000000
        and len(data["onchain"]["prices"]) == 20
        and len(data["rounds"]) >= 2
        and all(r["tx_count"] == 1 and r["gas_used"] > 0 for r in data["rounds"])
        and data["onchain"]["has_tx_data"]
        and len(data["wire"]["quotes"]) >= 3
        and len(data["wire"]["sigs"]) >= 3
    ):
        snap = data
        break
    time.sleep(0.2)

assert snap is not None, f"timed out waiting for converged telemetry snapshot; last={data}"
assert snap["protocol"]["asset_count"] == 20
assert snap["protocol"]["quorum"] == 3
assert snap["protocol"]["max_tolerance_bps"] == 100
assert snap["onchain"]["connected"] is True
assert snap["onchain"]["chain_id"] == 31337
assert snap["onchain"]["last_tx_gas"] > 0
assert snap["onchain"]["tx_invariant_ok"] is True
assert snap["onchain"]["last_tx_failover"] is False

prices = snap["onchain"]["prices"]
assert len(prices) == 20
assert all(p["price"] > 0 for p in prices), prices
assert prices[0]["symbol"] == "BTC" and prices[0]["price"] == 9245150000000
assert prices[1]["symbol"] == "ETH" and 341980000000 <= prices[1]["price"] <= 342210000000
assert prices[19]["symbol"] == "AAVE" and 31820000000 <= prices[19]["price"] <= 31890000000

assert snap["wire"]["active_round"] == 2
assert snap["wire"]["group_median"] == 9245150000000
assert len(snap["wire"]["group_medians"]) == 20
assert snap["wire"]["breach_detected"] is False
assert snap["wire"]["breach_asset"] == -1
assert snap["wire"]["decode_errors"] == 0

for n in snap["nodes"]:
    assert n["is_authorized_onchain"] is True, f"node {n['node_id']} not authorized"
    assert n["seen"] is True, f"node {n['node_id']} tap never observed"
    assert len(n["feeds"]) >= 2, f"node {n['node_id']} missing feed telemetry: {n['feeds']}"
    assert all(f["assets_ok"] == 20 for f in n["feeds"]), f"expected 20/20 assets on feeds: {n['feeds']}"

with urllib.request.urlopen("http://127.0.0.1:9200/metrics") as resp:
    metrics = resp.read().decode()
assert "feracle_asset_count 20\n" in metrics, metrics
assert "feracle_latest_price_1e8 9245150000000\n" in metrics, metrics
assert f'feracle_asset_price_1e8{{asset="ETH"}} {prices[1]["price"]}\n' in metrics, metrics
assert f'feracle_asset_price_1e8{{asset="AAVE"}} {prices[19]["price"]}\n' in metrics, metrics
assert "feracle_current_round 3\n" in metrics, metrics
assert "feracle_tx_per_round_ok 1\n" in metrics, metrics
assert 'feracle_node_authorized{node="0"} 1\n' in metrics, metrics
assert 'feracle_feed_assets_ok{node="0"' in metrics, metrics

print(
    f"Verified Rounds 1 & 2 WASM telemetry (20 assets): btc=$92,451.50, "
    f"eth={prices[1]['price']}, aave={prices[19]['price']}, round=3, "
    f"gas={snap['onchain']['last_tx_gas']}, wire_quotes={len(snap['wire']['quotes'])}, "
    f"wire_sigs={len(snap['wire']['sigs'])}"
)
PY

TUI_OUT="$(node "$ROOT_DIR/telemetry/host.mjs" \
  --rpc-url "$RPC_URL" \
  --contract "$CONTRACT_ADDR" \
  --oracles "$ADDR0,$ADDR1,$ADDR2" \
  --mode tui --no-ansi --once)"
echo "$TUI_OUT" | grep -q "FERACLE"
echo "$TUI_OUT" | grep -q "BTC"
echo "$TUI_OUT" | grep -q "ETH"
echo "$TUI_OUT" | grep -q "SOL"
echo "$TUI_OUT" | grep -q "AAVE"
echo "$TUI_OUT" | grep -q "\$92,451.50"
echo "$TUI_OUT" | grep -q "Assets: 20"
echo "$TUI_OUT" | grep -q "OK (1 tx/round)"

JSON_ONCE="$(node "$ROOT_DIR/telemetry/host.mjs" \
  --rpc-url "$RPC_URL" \
  --contract "$CONTRACT_ADDR" \
  --oracles "$ADDR0,$ADDR1,$ADDR2" \
  --mode json --once)"
python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); assert d["protocol"]["asset_count"]==20 and len(d["onchain"]["prices"])==20 and d["onchain"]["latest_price"]==9245150000000' <<<"$JSON_ONCE"

echo "[7/7] Verifying Round 3A ETH outlier breach telemetry..."
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
  >"$LOG_DIR/node0_r3a.log" 2>&1 &
PID0=$!

sleep 0.3
"$ROOT_DIR/out/feracle" \
  --node-id 1 --p2p-backend "$P2P_BACKEND" --p2p-port 7102 --telemetry-port 9102 \
  --bootstrap "/ip4/127.0.0.1/tcp/7101" \
  --sources "binance=127.0.0.1:9002,coinbase=127.0.0.1:9003" \
  --privkey-hex "$PK1" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 1 --round-timeout-secs 6 \
  >"$LOG_DIR/node1_r3a.log" 2>&1 &
PID1=$!

"$ROOT_DIR/out/feracle" \
  --node-id 2 --p2p-backend "$P2P_BACKEND" --p2p-port 7103 --telemetry-port 9103 \
  --bootstrap "/ip4/127.0.0.1/tcp/7101,/ip4/127.0.0.1/tcp/7102" \
  --sources "hyperliquid=127.0.0.1:9001,coinbase=127.0.0.1:9003" \
  --privkey-hex "$PK2" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 1 --round-timeout-secs 6 \
  >"$LOG_DIR/node2_r3a.log" 2>&1 &
PID2=$!
NODE_PIDS=("$PID0" "$PID1" "$PID2")

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
            data["wire"]["active_round"] == 3
            and data["wire"]["breach_detected"] is True
            and data["wire"]["breach_asset"] == 1
            and data["nodes"][0]["counters"]["tolerance_breaches"] >= 1
        ):
            caught = data
            break
    except Exception:
        pass
    time.sleep(0.25)

assert caught is not None, "telemetry did not observe Round 3A ETH tolerance breach in time"
assert caught["onchain"]["current_round"] == 3
with urllib.request.urlopen("http://127.0.0.1:9200/metrics") as resp:
    metrics = resp.read().decode()
assert "feracle_wire_breach_detected 1\n" in metrics, metrics
assert "feracle_wire_breach_asset 1\n" in metrics, metrics
assert 'feracle_node_tolerance_breaches_total{node="0"} 1\n' in metrics, metrics
print(
    f"Verified Round 3A multi-asset breach telemetry: active_wire_round=3, "
    f"wire_breach_detected=True, wire_breach_asset=1 (ETH), node0_tolerance_breaches={caught['nodes'][0]['counters']['tolerance_breaches']}"
)
PY

wait "$PID0"
wait "$PID1"
wait "$PID2"
NODE_PIDS=()

echo "ALL TELEMETRY E2E CHECKS PASSED!"
