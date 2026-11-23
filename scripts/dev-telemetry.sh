#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

BACKEND="${P2P_BACKEND:-libp2p}"
METRICS_PORT=9200
USE_MOCK_FEEDS=0

usage() {
  cat <<'EOF'
Build from source and launch a local 3-node Feracle devnet (Anvil + live feeds or --mock-feeds + WASM telemetry TUI)

Usage: dev-telemetry.sh [OPTIONS]

Options:
  --backend <libp2p|tcp|udp>  P2P backend (default: libp2p or $P2P_BACKEND)
  --metrics-port <PORT>       Prometheus/JSON HTTP port (default: 9200)
  --mock-feeds                Use local infra/mock_feeds.py instead of live exchange feeds via Caddy
  -h, --help                  Print help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backend)
      [[ $# -ge 2 ]] || { echo "error: --backend requires a value" >&2; exit 2; }
      BACKEND="$2"
      shift 2
      ;;
    --backend=*)
      BACKEND="${1#--backend=}"
      shift
      ;;
    --metrics-port)
      [[ $# -ge 2 ]] || { echo "error: --metrics-port requires a port" >&2; exit 2; }
      METRICS_PORT="$2"
      shift 2
      ;;
    --metrics-port=*)
      METRICS_PORT="${1#--metrics-port=}"
      shift
      ;;
    --mock-feeds)
      USE_MOCK_FEEDS=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option '$1'" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$BACKEND" in
  libp2p|tcp|udp) ;;
  *)
    echo "error: invalid --backend '$BACKEND' (expected libp2p, tcp, or udp)" >&2
    exit 2
    ;;
esac

# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/ensure-deps.sh"
ensure_fe
ensure_cargo
ensure_foundry
ensure_node
if [[ "$USE_MOCK_FEEDS" -eq 1 ]]; then
  ensure_python3
else
  ensure_caddy
fi

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

echo "Starting local Anvil on :8545..."
anvil --port 8545 --chain-id "$CHAIN_ID" >"$LOG_DIR/anvil.log" 2>&1 &
ANVIL_PID=$!
ANVIL_READY=0
for _ in $(seq 1 50); do
  if ! kill -0 "$ANVIL_PID" 2>/dev/null; then
    echo "error: anvil exited unexpectedly:" >&2
    cat "$LOG_DIR/anvil.log" >&2 || true
    exit 1
  fi
  if cast block-number --rpc-url "$RPC_URL" >/dev/null 2>&1; then
    ANVIL_READY=1
    break
  fi
  sleep 0.2
done
if [[ "$ANVIL_READY" -ne 1 ]]; then
  echo "error: anvil did not become ready on :8545:" >&2
  cat "$LOG_DIR/anvil.log" >&2 || true
  exit 1
fi

BYTECODE="0x$(tr -d '\r\n' < "$ROOT_DIR/ingots/evm/out/OffchainMedianOracle.bin")"
DEPLOY_JSON="$(cast send --rpc-url "$RPC_URL" --private-key "$PK0" --json --create "$BYTECODE")"
CONTRACT_ADDR="$(node -e 'const fs=require("fs"); console.log(JSON.parse(fs.readFileSync(0,"utf8")).contractAddress)' <<<"$DEPLOY_JSON")"
cast send "$CONTRACT_ADDR" "addOracle(address)" "$ADDR0" --rpc-url "$RPC_URL" --private-key "$PK0" >/dev/null
cast send "$CONTRACT_ADDR" "addOracle(address)" "$ADDR1" --rpc-url "$RPC_URL" --private-key "$PK0" >/dev/null
cast send "$CONTRACT_ADDR" "addOracle(address)" "$ADDR2" --rpc-url "$RPC_URL" --private-key "$PK0" >/dev/null

if [[ "$USE_MOCK_FEEDS" -eq 1 ]]; then
  FEEDS_MODE="mock"
  echo "Starting local mock feeds on :9001..:9003..."
  python3 "$ROOT_DIR/infra/mock_feeds.py" >"$LOG_DIR/feeds.log" 2>&1 &
  FEEDS_PID=$!
  READY=0
  for _ in $(seq 1 50); do
    if ! kill -0 "$FEEDS_PID" 2>/dev/null; then
      echo "error: mock_feeds.py exited unexpectedly:" >&2
      cat "$LOG_DIR/feeds.log" >&2 || true
      exit 1
    fi
    if curl -sf http://127.0.0.1:9003/products/BTC-USD/ticker >/dev/null 2>&1; then
      READY=1
      break
    fi
    sleep 0.2
  done
  if [[ "$READY" -ne 1 ]]; then
    echo "error: mock_feeds.py did not become ready on :9001..:9003:" >&2
    cat "$LOG_DIR/feeds.log" >&2 || true
    exit 1
  fi
else
  FEEDS_MODE="live"
  echo "Starting Caddy live-feed TLS proxy on :9001..:9003..."
  caddy run --config "$ROOT_DIR/infra/Caddyfile" --adapter caddyfile >"$LOG_DIR/feeds.log" 2>&1 &
  FEEDS_PID=$!
  READY=0
  for _ in $(seq 1 50); do
    if ! kill -0 "$FEEDS_PID" 2>/dev/null; then
      echo "error: caddy exited unexpectedly:" >&2
      cat "$LOG_DIR/feeds.log" >&2 || true
      exit 1
    fi
    if node -e '
      const net = require("node:net");
      Promise.all([9001, 9002, 9003].map((port) => new Promise((res, rej) => {
        const s = net.createConnection({ host: "127.0.0.1", port }, () => { s.destroy(); res(); });
        s.on("error", rej);
      }))).then(() => process.exit(0)).catch(() => process.exit(1));
    ' 2>/dev/null; then
      READY=1
      break
    fi
    sleep 0.2
  done
  if [[ "$READY" -ne 1 ]]; then
    echo "error: Caddy proxy did not become ready on :9001..:9003:" >&2
    cat "$LOG_DIR/feeds.log" >&2 || true
    exit 1
  fi
fi

"$ROOT_DIR/out/feracle" \
  --node-id 0 --p2p-backend "$BACKEND" --p2p-port 7001 --telemetry-port 9101 \
  --sources "hyperliquid=127.0.0.1:9001,binance=127.0.0.1:9002" \
  --privkey-hex "$PK0" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 0 --round-timeout-secs 25 \
  >"$LOG_DIR/node0.log" 2>&1 &
PID0=$!

sleep 0.3
"$ROOT_DIR/out/feracle" \
  --node-id 1 --p2p-backend "$BACKEND" --p2p-port 7002 --telemetry-port 9102 \
  --bootstrap "/ip4/127.0.0.1/tcp/7001" \
  --sources "binance=127.0.0.1:9002,coinbase=127.0.0.1:9003" \
  --privkey-hex "$PK1" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 0 --round-timeout-secs 25 \
  >"$LOG_DIR/node1.log" 2>&1 &
PID1=$!

"$ROOT_DIR/out/feracle" \
  --node-id 2 --p2p-backend "$BACKEND" --p2p-port 7003 --telemetry-port 9103 \
  --bootstrap "/ip4/127.0.0.1/tcp/7001,/ip4/127.0.0.1/tcp/7002" \
  --sources "hyperliquid=127.0.0.1:9001,coinbase=127.0.0.1:9003" \
  --privkey-hex "$PK2" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 0 --round-timeout-secs 25 \
  >"$LOG_DIR/node2.log" 2>&1 &
PID2=$!
NODE_PIDS=("$PID0" "$PID1" "$PID2")

echo "Launching Fe WASM telemetry TUI (feeds=$FEEDS_MODE, backend=$BACKEND, metrics http://127.0.0.1:$METRICS_PORT/metrics). Press Ctrl-C to stop."
node "$ROOT_DIR/telemetry/host.mjs" \
  --rpc-url "$RPC_URL" \
  --contract "$CONTRACT_ADDR" \
  --oracles "$ADDR0,$ADDR1,$ADDR2" \
  --nodes "http://127.0.0.1:9101,http://127.0.0.1:9102,http://127.0.0.1:9103" \
  --metrics-port "$METRICS_PORT" \
  --mode tui
