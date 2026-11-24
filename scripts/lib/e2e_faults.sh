# shellcheck shell=bash

echo "[8/11] Testing outlier fault tolerance (Round 4A tolerance guard + Round 4B 3-source median immunity)..."
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

# 4A: 2-source configs cause tolerance guard breach on Node 0 & Node 3 (no on-chain write)
"$ROOT_DIR/out/feracle" \
  --node-id 0 --p2p-backend "$P2P_BACKEND" --p2p-port 7101 \
  --sources "hyperliquid=127.0.0.1:9001,binance=127.0.0.1:9002" \
  --privkey-hex "$PK0" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 1 --round-timeout-secs 6 \
  >"$LOG_DIR/node0_r4a.log" 2>&1 &
PID0=$!

sleep 0.3
"$ROOT_DIR/out/feracle" \
  --node-id 1 --p2p-backend "$P2P_BACKEND" --p2p-port 7102 \
  --bootstrap "/ip4/127.0.0.1/tcp/7101" \
  --sources "binance=127.0.0.1:9002,coinbase=127.0.0.1:9003" \
  --privkey-hex "$PK1" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 1 --round-timeout-secs 6 \
  >"$LOG_DIR/node1_r4a.log" 2>&1 &
PID1=$!

"$ROOT_DIR/out/feracle" \
  --node-id 2 --p2p-backend "$P2P_BACKEND" --p2p-port 7103 \
  --bootstrap "/ip4/127.0.0.1/tcp/7101,/ip4/127.0.0.1/tcp/7102" \
  --sources "hyperliquid=127.0.0.1:9001,coinbase=127.0.0.1:9003" \
  --privkey-hex "$PK2" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 1 --round-timeout-secs 6 \
  >"$LOG_DIR/node2_r4a.log" 2>&1 &
PID2=$!

"$ROOT_DIR/out/feracle" \
  --node-id 3 --p2p-backend "$P2P_BACKEND" --p2p-port 7104 \
  --bootstrap "/ip4/127.0.0.1/tcp/7101,/ip4/127.0.0.1/tcp/7102,/ip4/127.0.0.1/tcp/7103" \
  --sources "hyperliquid=127.0.0.1:9001,binance=127.0.0.1:9002,coinbase=127.0.0.1:9003" \
  --privkey-hex "$PK3" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 1 --round-timeout-secs 6 \
  >"$LOG_DIR/node3_r4a.log" 2>&1 &
PID3=$!

NODE_PIDS=("$PID0" "$PID1" "$PID2" "$PID3")
wait "$PID0"
wait "$PID1"
wait "$PID2"
wait "$PID3"
NODE_PIDS=()

grep -q "tolerance guard breached on BTC" "$LOG_DIR/node0_r4a.log"
CUR_ROUND_4A="$(cast call "$CONTRACT_ADDR" "currentRound()(uint256)" --rpc-url "$RPC_URL" | awk '{print $1}')"
BTC_RAW_4A="$(cast call "$CONTRACT_ADDR" "latestPrice(uint256)(uint256,uint256)" 0 --rpc-url "$RPC_URL")"
python3 - "$RPC_URL" "$CONTRACT_ADDR" "$CUR_ROUND_4A" "$BTC_RAW_4A" <<'PY'
import json, sys, urllib.request
rpc_url, contract, cur_round, btc_raw = sys.argv[1:]
assert int(cur_round) == 4, f"4A expected currentRound=4, got {cur_round}"
price = int([l.strip().split()[0] for l in btc_raw.strip().splitlines() if l.strip()][0])
assert price == 9245150000000, f"4A outlier leaked on-chain: {price}"
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
assert count == 3, f"4A expected submit_txs=3, got {count}"
print(f"Verified Round 4A (Tolerance Guard): BTC outlier rejected, currentRound=4, btc={price}, submit_txs=3")
PY

# 4B: 3-source median immunity against outlier on 9003 (leader for round 4 is 4 % 4 = Node 0)
ALL_SOURCES="hyperliquid=127.0.0.1:9001,binance=127.0.0.1:9002,coinbase=127.0.0.1:9003"
"$ROOT_DIR/out/feracle" \
  --node-id 0 --p2p-backend "$P2P_BACKEND" --p2p-port 7201 \
  --sources "$ALL_SOURCES" \
  --privkey-hex "$PK0" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 1 --round-timeout-secs 15 \
  >"$LOG_DIR/node0_r4b.log" 2>&1 &
PID0=$!

sleep 0.3
"$ROOT_DIR/out/feracle" \
  --node-id 1 --p2p-backend "$P2P_BACKEND" --p2p-port 7202 \
  --bootstrap "/ip4/127.0.0.1/tcp/7201" \
  --sources "$ALL_SOURCES" \
  --privkey-hex "$PK1" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 1 --round-timeout-secs 15 \
  >"$LOG_DIR/node1_r4b.log" 2>&1 &
PID1=$!

"$ROOT_DIR/out/feracle" \
  --node-id 2 --p2p-backend "$P2P_BACKEND" --p2p-port 7203 \
  --bootstrap "/ip4/127.0.0.1/tcp/7201,/ip4/127.0.0.1/tcp/7202" \
  --sources "$ALL_SOURCES" \
  --privkey-hex "$PK2" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 1 --round-timeout-secs 15 \
  >"$LOG_DIR/node2_r4b.log" 2>&1 &
PID2=$!

"$ROOT_DIR/out/feracle" \
  --node-id 3 --p2p-backend "$P2P_BACKEND" --p2p-port 7204 \
  --bootstrap "/ip4/127.0.0.1/tcp/7201,/ip4/127.0.0.1/tcp/7202,/ip4/127.0.0.1/tcp/7203" \
  --sources "$ALL_SOURCES" \
  --privkey-hex "$PK3" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 1 --round-timeout-secs 15 \
  >"$LOG_DIR/node3_r4b.log" 2>&1 &
PID3=$!

NODE_PIDS=("$PID0" "$PID1" "$PID2" "$PID3")
wait "$PID0"
wait "$PID1"
wait "$PID2"
wait "$PID3"
NODE_PIDS=()

CUR_ROUND_4B="$(cast call "$CONTRACT_ADDR" "currentRound()(uint256)" --rpc-url "$RPC_URL" | awk '{print $1}')"
BTC_RAW_4B="$(cast call "$CONTRACT_ADDR" "latestPrice(uint256)(uint256,uint256)" 0 --rpc-url "$RPC_URL")"
DECIMALS_VAL="$(cast call "$CONTRACT_ADDR" "decimals()(uint8)" --rpc-url "$RPC_URL" | awk '{print $1}')"
LRD_RAW="$(cast call "$CONTRACT_ADDR" "latestRoundData()(uint80,int256,uint256,uint256,uint80)" --rpc-url "$RPC_URL")"
python3 - "$RPC_URL" "$CONTRACT_ADDR" "$CUR_ROUND_4B" "$BTC_RAW_4B" "$DECIMALS_VAL" "$LRD_RAW" "$ADDR0" <<'PY'
import json, sys, urllib.request
rpc_url, contract, cur_round, btc_raw, decimals_val, lrd_raw, addr0 = sys.argv[1:]
assert int(cur_round) == 5, f"4B expected currentRound=5, got {cur_round}"
assert int(decimals_val) == 8, f"expected decimals=8, got {decimals_val}"
price = int([l.strip().split()[0] for l in btc_raw.strip().splitlines() if l.strip()][0])
assert price == 9245500000000, f"4B expected exact BTC median 9245500000000, got {price}"
lrd_parts = [int(l.strip().split()[0]) for l in lrd_raw.strip().splitlines() if l.strip()]
assert len(lrd_parts) == 5, f"expected 5 latestRoundData fields, got {lrd_parts}"
assert lrd_parts[0] == 4 and lrd_parts[1] == price and lrd_parts[2] > 0 and lrd_parts[3] == lrd_parts[2] and lrd_parts[4] == 4, lrd_parts

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
assert len(submit_txs) == 4, f"4B expected submit_txs=4, got {len(submit_txs)}"
assert submit_txs[3]["from"].lower() == addr0.lower(), f"round 4 leader mismatch: {submit_txs[3]['from']}"
print(
    f"Verified Round 4B (3-Source Outlier Immunity + Chainlink View): currentRound=5, "
    f"decimals=8, latestRoundData={lrd_parts}, submit_txs=4 (leader: {addr0})"
)
PY

echo "[9/11] Testing backup-leader failover when online primary leader fails eth_sendRawTransaction (Round 5)..."
kill "$FEEDS_PID"
wait "$FEEDS_PID" 2>/dev/null || true
FEEDS_PID=""

python3 "$ROOT_DIR/infra/mock_feeds.py" >"$LOG_DIR/feeds_clean2.log" 2>&1 &
FEEDS_PID=$!
for _ in $(seq 1 30); do
  if curl -sf http://127.0.0.1:9003/products/BTC-USD/ticker >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

PROXY_RPC_URL="http://127.0.0.1:8546"
python3 "$ROOT_DIR/infra/fault_proxy.py" "$RPC_URL" "$LOG_DIR/rpc_proxy.log" &
PROXY_PID=$!

for _ in $(seq 1 30); do
  if cast block-number --rpc-url "$PROXY_RPC_URL" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

"$ROOT_DIR/out/feracle" \
  --node-id 0 --p2p-backend "$P2P_BACKEND" --p2p-port 7301 \
  --sources "hyperliquid=127.0.0.1:9001,binance=127.0.0.1:9002" \
  --privkey-hex "$PK0" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 1 --round-timeout-secs 6 \
  >"$LOG_DIR/node0_r5.log" 2>&1 &
PID0=$!

sleep 0.3
"$ROOT_DIR/out/feracle" \
  --node-id 1 --p2p-backend "$P2P_BACKEND" --p2p-port 7302 \
  --bootstrap "/ip4/127.0.0.1/tcp/7301" \
  --sources "binance=127.0.0.1:9002,coinbase=127.0.0.1:9003" \
  --privkey-hex "$PK1" --rpc-url "$PROXY_RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 1 --round-timeout-secs 6 \
  >"$LOG_DIR/node1_r5.log" 2>&1 &
PID1=$!

"$ROOT_DIR/out/feracle" \
  --node-id 2 --p2p-backend "$P2P_BACKEND" --p2p-port 7303 \
  --bootstrap "/ip4/127.0.0.1/tcp/7301,/ip4/127.0.0.1/tcp/7302" \
  --sources "hyperliquid=127.0.0.1:9001,coinbase=127.0.0.1:9003" \
  --privkey-hex "$PK2" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 1 --round-timeout-secs 6 \
  >"$LOG_DIR/node2_r5.log" 2>&1 &
PID2=$!

"$ROOT_DIR/out/feracle" \
  --node-id 3 --p2p-backend "$P2P_BACKEND" --p2p-port 7304 \
  --bootstrap "/ip4/127.0.0.1/tcp/7301,/ip4/127.0.0.1/tcp/7302,/ip4/127.0.0.1/tcp/7303" \
  --sources "hyperliquid=127.0.0.1:9001,binance=127.0.0.1:9002,coinbase=127.0.0.1:9003" \
  --privkey-hex "$PK3" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 1 --round-timeout-secs 6 \
  >"$LOG_DIR/node3_r5.log" 2>&1 &
PID3=$!

NODE_PIDS=("$PID0" "$PID1" "$PID2" "$PID3")
wait "$PID0"
wait "$PID1"
wait "$PID2"
wait "$PID3"
NODE_PIDS=()

kill "$PROXY_PID" 2>/dev/null || true
wait "$PROXY_PID" 2>/dev/null || true
PROXY_PID=""

grep -q "blocked eth_sendRawTransaction" "$LOG_DIR/rpc_proxy.log"
CUR_ROUND_5="$(cast call "$CONTRACT_ADDR" "currentRound()(uint256)" --rpc-url "$RPC_URL" | awk '{print $1}')"
BTC_RAW_5="$(cast call "$CONTRACT_ADDR" "latestPrice(uint256)(uint256,uint256)" 0 --rpc-url "$RPC_URL")"
python3 - "$RPC_URL" "$CONTRACT_ADDR" "$CUR_ROUND_5" "$BTC_RAW_5" "$ADDR2" <<'PY'
import json, sys, urllib.request
rpc_url, contract, cur_round, btc_raw, addr2 = sys.argv[1:]
assert int(cur_round) == 6, f"Round 5 expected currentRound=6, got {cur_round}"
price = int([l.strip().split()[0] for l in btc_raw.strip().splitlines() if l.strip()][0])
assert price == 9245100000000, f"Round 5 expected BTC median 9245100000000, got {price}"

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
assert len(submit_txs) == 5, f"Round 5 expected submit_txs=5, got {len(submit_txs)}"
assert submit_txs[4]["from"].lower() == addr2.lower(), f"Round 5 backup leader mismatch: {submit_txs[4]['from']}"
assert submit_txs[4].get("type") == "0x2", f"Round 5 expected type 0x2, got {submit_txs[4].get('type')}"
print(f"Verified Round 5 (Online Primary RPC Fail -> Backup Failover): currentRound=6, btc={price}, submit_txs=5 (backup: {addr2})")
PY

echo "[10/11] Testing mid-round node restart and rejoin (Rounds 6 & 7)..."
"$ROOT_DIR/out/feracle" \
  --node-id 0 --p2p-backend "$P2P_BACKEND" --p2p-port 7401 \
  --sources "hyperliquid=127.0.0.1:9001,binance=127.0.0.1:9002" \
  --privkey-hex "$PK0" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 2 --round-timeout-secs 10 \
  >"$LOG_DIR/node0_r67.log" 2>&1 &
PID0=$!

sleep 0.3
"$ROOT_DIR/out/feracle" \
  --node-id 2 --p2p-backend "$P2P_BACKEND" --p2p-port 7403 \
  --bootstrap "/ip4/127.0.0.1/tcp/7401" \
  --sources "hyperliquid=127.0.0.1:9001,coinbase=127.0.0.1:9003" \
  --privkey-hex "$PK2" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 2 --round-timeout-secs 10 \
  >"$LOG_DIR/node2_r67.log" 2>&1 &
PID2=$!
NODE_PIDS=("$PID0" "$PID2")

# Start only {Node 0, Node 2} first so peer_count=1 holds MeshWarmup at 6000ms.
# After Node 2 starts and arms signal handlers (600ms delay), stop it cleanly with
# SIGTERM before launching Node 1 and Node 3 so Round 6 cannot race ahead first.
python3 - "$LOG_DIR/node2_r67.log" "$PID2" <<'PY'
import os, signal, sys, time
log_path, pid = sys.argv[1], int(sys.argv[2])
deadline = time.time() + 12.0
while time.time() < deadline:
    try:
        with open(log_path, "r", encoding="utf-8", errors="ignore") as f:
            if "starting " in f.read():
                time.sleep(0.6)
                os.kill(pid, signal.SIGTERM)
                sys.exit(0)
    except FileNotFoundError:
        pass
    time.sleep(0.01)
raise SystemExit("timed out waiting for Node 2 startup")
PY
wait "$PID2"
grep -q "received shutdown signal" "$LOG_DIR/node2_r67.log"
NODE_PIDS=("$PID0")

"$ROOT_DIR/out/feracle" \
  --node-id 1 --p2p-backend "$P2P_BACKEND" --p2p-port 7402 \
  --bootstrap "/ip4/127.0.0.1/tcp/7401" \
  --sources "binance=127.0.0.1:9002,coinbase=127.0.0.1:9003" \
  --privkey-hex "$PK1" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 2 --round-timeout-secs 10 \
  >"$LOG_DIR/node1_r67.log" 2>&1 &
PID1=$!

sleep 0.2
"$ROOT_DIR/out/feracle" \
  --node-id 3 --p2p-backend "$P2P_BACKEND" --p2p-port 7404 \
  --bootstrap "/ip4/127.0.0.1/tcp/7401,/ip4/127.0.0.1/tcp/7402" \
  --sources "hyperliquid=127.0.0.1:9001,binance=127.0.0.1:9002,coinbase=127.0.0.1:9003" \
  --privkey-hex "$PK3" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 2 --round-timeout-secs 10 \
  >"$LOG_DIR/node3_r67.log" 2>&1 &
PID3=$!
NODE_PIDS=("$PID0" "$PID1" "$PID3")

# Wait for 3 remaining nodes to settle Round 6 -> currentRound=7, then immediately rejoin Node 2 for Round 7.
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
    if int(res, 16) >= 7:
        sys.exit(0)
    time.sleep(0.05)
raise SystemExit("timed out waiting for Round 6 to settle 3-of-4")
PY

"$ROOT_DIR/out/feracle" \
  --node-id 2 --p2p-backend "$P2P_BACKEND" --p2p-port 7403 \
  --bootstrap "/ip4/127.0.0.1/tcp/7401,/ip4/127.0.0.1/tcp/7402,/ip4/127.0.0.1/tcp/7404" \
  --sources "hyperliquid=127.0.0.1:9001,coinbase=127.0.0.1:9003" \
  --privkey-hex "$PK2" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 1 --round-timeout-secs 12 \
  >"$LOG_DIR/node2_r7_rejoin.log" 2>&1 &
PID2_REJOIN=$!
NODE_PIDS=("$PID0" "$PID1" "$PID2_REJOIN" "$PID3")

wait "$PID0"
wait "$PID1"
wait "$PID2_REJOIN"
wait "$PID3"
NODE_PIDS=()

grep -q "round 7" "$LOG_DIR/node2_r7_rejoin.log"
CUR_ROUND_7="$(cast call "$CONTRACT_ADDR" "currentRound()(uint256)" --rpc-url "$RPC_URL" | awk '{print $1}')"
BTC_RAW_7="$(cast call "$CONTRACT_ADDR" "latestPrice(uint256)(uint256,uint256)" 0 --rpc-url "$RPC_URL")"
python3 - "$RPC_URL" "$CONTRACT_ADDR" "$CUR_ROUND_7" "$BTC_RAW_7" <<'PY'
import json, sys, urllib.request
rpc_url, contract, cur_round, btc_raw = sys.argv[1:]
assert int(cur_round) == 8, f"Rounds 6-7 expected currentRound=8, got {cur_round}"
price = int([l.strip().split()[0] for l in btc_raw.strip().splitlines() if l.strip()][0])
assert price in (9245100000000, 9245150000000), f"Round 7 unexpected BTC median {price}"

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
assert len(submit_txs) == 7, f"Round 7 expected submit_txs=7, got {len(submit_txs)}"
print(f"Verified Rounds 6 & 7 (Mid-Round Stop + 3-of-4 + Node 2 Rejoin): currentRound=8, btc={price}, submit_txs=7")
PY

echo "[11/11] Testing forged and unauthorized off-chain quote/sig rejection (Round 8)..."
python3 "$ROOT_DIR/infra/mock_feeds.py" \
  --port-hl 9004 --port-binance 9005 --port-coinbase 9006 \
  --price-hl 123456.00 --price-binance 123456.00 --price-coinbase 123456.00 \
  >"$LOG_DIR/feeds_rogue.log" 2>&1 &
EXTRA_FEEDS_PID=$!
for _ in $(seq 1 30); do
  if curl -sf http://127.0.0.1:9005/api/v3/ticker/price?symbol=BTCUSDT >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

PK4="0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a"
"$ROOT_DIR/out/feracle" \
  --node-id 0 --p2p-backend "$P2P_BACKEND" --p2p-port 7501 \
  --sources "hyperliquid=127.0.0.1:9001,binance=127.0.0.1:9002" \
  --privkey-hex "$PK0" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 1 --round-timeout-secs 15 \
  >"$LOG_DIR/node0_r8.log" 2>&1 &
PID0=$!

sleep 0.3
"$ROOT_DIR/out/feracle" \
  --node-id 1 --p2p-backend "$P2P_BACKEND" --p2p-port 7502 \
  --bootstrap "/ip4/127.0.0.1/tcp/7501" \
  --sources "binance=127.0.0.1:9002,coinbase=127.0.0.1:9003" \
  --privkey-hex "$PK1" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 1 --round-timeout-secs 15 \
  >"$LOG_DIR/node1_r8.log" 2>&1 &
PID1=$!

"$ROOT_DIR/out/feracle" \
  --node-id 2 --p2p-backend "$P2P_BACKEND" --p2p-port 7503 \
  --bootstrap "/ip4/127.0.0.1/tcp/7501,/ip4/127.0.0.1/tcp/7502" \
  --sources "hyperliquid=127.0.0.1:9001,coinbase=127.0.0.1:9003" \
  --privkey-hex "$PK2" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 1 --round-timeout-secs 15 \
  >"$LOG_DIR/node2_r8.log" 2>&1 &
PID2=$!

"$ROOT_DIR/out/feracle" \
  --node-id 3 --p2p-backend "$P2P_BACKEND" --p2p-port 7504 \
  --bootstrap "/ip4/127.0.0.1/tcp/7501,/ip4/127.0.0.1/tcp/7502,/ip4/127.0.0.1/tcp/7503" \
  --sources "hyperliquid=127.0.0.1:9001,binance=127.0.0.1:9002,coinbase=127.0.0.1:9003" \
  --privkey-hex "$PK3" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 1 --round-timeout-secs 15 \
  >"$LOG_DIR/node3_r8.log" 2>&1 &
PID3=$!

"$ROOT_DIR/out/feracle" \
  --node-id 0 --p2p-backend "$P2P_BACKEND" --p2p-port 7505 \
  --bootstrap "/ip4/127.0.0.1/tcp/7501,/ip4/127.0.0.1/tcp/7502,/ip4/127.0.0.1/tcp/7503,/ip4/127.0.0.1/tcp/7504" \
  --sources "hyperliquid=127.0.0.1:9004,binance=127.0.0.1:9005" \
  --privkey-hex "$PK4" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 1 --round-timeout-secs 15 \
  >"$LOG_DIR/rogue_r8.log" 2>&1 &
PID_ROGUE=$!
NODE_PIDS=("$PID0" "$PID1" "$PID2" "$PID3" "$PID_ROGUE")

if [[ "$P2P_BACKEND" == "tcp" || "$P2P_BACKEND" == "udp" ]]; then
  python3 - "$P2P_BACKEND" "$ADDR0" "$ADDR1" <<'PY'
import socket, struct, sys, time
backend, addr0_hex, addr1_hex = sys.argv[1:]
time.sleep(0.5)

def wrap_frame(kind, origin, seq, ttl, payload):
    return struct.pack(">HBBQQBH", 0xFE50, 1, kind, origin, seq, ttl, len(payload)) + payload

now_sec = int(time.time())
forged_prices = b"".join(struct.pack(">Q", 99999900000000) for _ in range(20))
quote_payload = (
    struct.pack(">BQQ", 0, 8, now_sec)
    + forged_prices
    + bytes.fromhex(addr0_hex[2:])
    + bytes([27])
    + (b"\x11" * 32)
    + (b"\x22" * 32)
)
sig_payload = (
    struct.pack(">BQQ", 1, 8, now_sec)
    + forged_prices
    + bytes.fromhex(addr1_hex[2:])
    + bytes([27])
    + (b"\x33" * 32)
    + (b"\x44" * 32)
)
f1 = wrap_frame(0x01, 0xBAD001, 1, 4, quote_payload)
f2 = wrap_frame(0x01, 0xBAD001, 2, 4, sig_payload)

for port in (7501, 7502, 7503, 7504):
    try:
        if backend == "tcp":
            hello = wrap_frame(0x20, 0xBAD001, 0, 1, struct.pack(">H", 17505))
            with socket.create_connection(("127.0.0.1", port), timeout=1.0) as s:
                s.sendall(hello + f1 + f2)
        else:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
                s.sendto(f1, ("127.0.0.1", port))
                s.sendto(f2, ("127.0.0.1", port))
    except OSError:
        pass
PY
fi

wait "$PID0"
wait "$PID1"
wait "$PID2"
wait "$PID3"
kill "$PID_ROGUE" 2>/dev/null || true
wait "$PID_ROGUE" 2>/dev/null || true
NODE_PIDS=()
kill "$EXTRA_FEEDS_PID" 2>/dev/null || true
wait "$EXTRA_FEEDS_PID" 2>/dev/null || true
EXTRA_FEEDS_PID=""

CUR_ROUND_8="$(cast call "$CONTRACT_ADDR" "currentRound()(uint256)" --rpc-url "$RPC_URL" | awk '{print $1}')"
BTC_RAW_8="$(cast call "$CONTRACT_ADDR" "latestPrice(uint256)(uint256,uint256)" 0 --rpc-url "$RPC_URL")"
python3 - "$RPC_URL" "$CONTRACT_ADDR" "$CUR_ROUND_8" "$BTC_RAW_8" <<'PY'
import json, sys, urllib.request
rpc_url, contract, cur_round, btc_raw = sys.argv[1:]
assert int(cur_round) == 9, f"Round 8 expected currentRound=9, got {cur_round}"
price = int([l.strip().split()[0] for l in btc_raw.strip().splitlines() if l.strip()][0])
assert price == 9245100000000, f"Round 8 forged/unauthorized quote leaked: {price}"

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
assert len(submit_txs) == 8, f"Round 8 expected submit_txs=8, got {len(submit_txs)}"
print(f"Verified Round 8 (Forged/Unauthorized Quote & Sig Rejection): currentRound=9, btc={price}, submit_txs=8")
PY
