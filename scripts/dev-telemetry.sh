#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

RPC_URL="http://127.0.0.1:8545"
CHAIN_ID="31337"
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
  for pid in "${NODE_PIDS[@]:-}"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  for pid in "$FEEDS_PID" "$ANVIL_PID"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  rm -rf "$LOG_DIR"
}
trap cleanup EXIT INT TERM

echo "Building evm, feracle, and telemetry wasm..."
fe build --emit abi,bytecode --out-dir "$ROOT_DIR/ingots/evm/out" "$ROOT_DIR/ingots/evm"
"$ROOT_DIR/scripts/build-feracle.sh"
"$ROOT_DIR/scripts/build-wasm.sh"

anvil --port 8545 --chain-id "$CHAIN_ID" >"$LOG_DIR/anvil.log" 2>&1 &
ANVIL_PID=$!
for _ in $(seq 1 50); do
  if cast block-number --rpc-url "$RPC_URL" >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done

BYTECODE="0x$(tr -d '\r\n' < "$ROOT_DIR/ingots/evm/out/OffchainMedianOracle.bin")"
DEPLOY_JSON="$(cast send --rpc-url "$RPC_URL" --private-key "$PK0" --json --create "$BYTECODE")"
CONTRACT_ADDR="$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["contractAddress"])' <<<"$DEPLOY_JSON")"
cast send "$CONTRACT_ADDR" "addOracle(address)" "$ADDR0" --rpc-url "$RPC_URL" --private-key "$PK0" >/dev/null
cast send "$CONTRACT_ADDR" "addOracle(address)" "$ADDR1" --rpc-url "$RPC_URL" --private-key "$PK0" >/dev/null
cast send "$CONTRACT_ADDR" "addOracle(address)" "$ADDR2" --rpc-url "$RPC_URL" --private-key "$PK0" >/dev/null

python3 "$ROOT_DIR/infra/mock_feeds.py" >"$LOG_DIR/feeds.log" 2>&1 &
FEEDS_PID=$!

"$ROOT_DIR/out/feracle" \
  --node-id 0 --p2p-port 7001 --telemetry-port 9101 \
  --sources "hyperliquid=127.0.0.1:9001,binance=127.0.0.1:9002" \
  --privkey-hex "$PK0" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 0 --round-timeout-secs 15 \
  >"$LOG_DIR/node0.log" 2>&1 &
PID0=$!

sleep 0.3
"$ROOT_DIR/out/feracle" \
  --node-id 1 --p2p-port 7002 --telemetry-port 9102 \
  --bootstrap "/ip4/127.0.0.1/tcp/7001" \
  --sources "binance=127.0.0.1:9002,coinbase=127.0.0.1:9003" \
  --privkey-hex "$PK1" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 0 --round-timeout-secs 15 \
  >"$LOG_DIR/node1.log" 2>&1 &
PID1=$!

"$ROOT_DIR/out/feracle" \
  --node-id 2 --p2p-port 7003 --telemetry-port 9103 \
  --bootstrap "/ip4/127.0.0.1/tcp/7001,/ip4/127.0.0.1/tcp/7002" \
  --sources "hyperliquid=127.0.0.1:9001,coinbase=127.0.0.1:9003" \
  --privkey-hex "$PK2" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 0 --round-timeout-secs 15 \
  >"$LOG_DIR/node2.log" 2>&1 &
PID2=$!
NODE_PIDS=("$PID0" "$PID1" "$PID2")

echo "Launching Fe WASM telemetry TUI (metrics on http://127.0.0.1:9200/metrics). Press Ctrl-C to stop."
node "$ROOT_DIR/telemetry/host.mjs" \
  --rpc-url "$RPC_URL" \
  --contract "$CONTRACT_ADDR" \
  --oracles "$ADDR0,$ADDR1,$ADDR2" \
  --nodes "http://127.0.0.1:9101,http://127.0.0.1:9102,http://127.0.0.1:9103" \
  --metrics-port 9200 \
  --mode tui
