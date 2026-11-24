#!/usr/bin/env bash
set -euo pipefail

FERACLE_REPO="${FERACLE_REPO:-highestagent/feracle}"
FE_VERSION="${FE_VERSION:-v26.7.0}"
PREFIX="${FERACLE_PREFIX:-$HOME/.local}"
RELEASE_VERSION="latest"
MODE="auto"
ARCHIVE_PATH=""
PACKAGE_OUT=""
INSTALL_FOUNDRY=0
INSTALL_DEPS=0

usage() {
  cat <<'EOF'
Feracle installer and packager (native oracle node + WASM telemetry)

Usage:
  install.sh [OPTIONS]

Options:
  --prefix <DIR>        Install destination prefix (default: $HOME/.local)
  --from-source         Build and install from source instead of release archives
  --archive <PATH>      Install from a local feracle-<os>-<arch>.tar.gz archive
  --version <TAG>       GitHub release tag to install when downloading (default: latest)
  --package <PATH>      Build from local source and emit a relocatable .tar.gz bundle
  --install-foundry     Install Foundry (anvil/cast) via foundryup if missing
  --install-deps        Install runtime dependencies (Foundry, Node.js >= 20, Caddy) if missing
  -h, --help            Print help

Environment variables:
  FERACLE_REPO          GitHub repository slug (default: highestagent/feracle)
  FERACLE_PREFIX        Default install prefix if --prefix is omitted
  FE_VERSION            Fe toolchain version for source builds (default: v26.7.0)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)
      [[ $# -ge 2 ]] || { echo "error: --prefix requires a directory argument" >&2; exit 2; }
      PREFIX="$2"
      shift 2
      ;;
    --prefix=*)
      PREFIX="${1#--prefix=}"
      shift
      ;;
    --from-source)
      MODE="source"
      shift
      ;;
    --archive)
      [[ $# -ge 2 ]] || { echo "error: --archive requires a file path" >&2; exit 2; }
      MODE="archive"
      ARCHIVE_PATH="$2"
      shift 2
      ;;
    --archive=*)
      MODE="archive"
      ARCHIVE_PATH="${1#--archive=}"
      shift
      ;;
    --version)
      [[ $# -ge 2 ]] || { echo "error: --version requires a tag" >&2; exit 2; }
      RELEASE_VERSION="$2"
      shift 2
      ;;
    --version=*)
      RELEASE_VERSION="${1#--version=}"
      shift
      ;;
    --package)
      [[ $# -ge 2 ]] || { echo "error: --package requires an output .tar.gz path" >&2; exit 2; }
      MODE="package"
      PACKAGE_OUT="$2"
      shift 2
      ;;
    --package=*)
      MODE="package"
      PACKAGE_OUT="${1#--package=}"
      shift
      ;;
    --install-foundry)
      INSTALL_FOUNDRY=1
      shift
      ;;
    --install-deps)
      INSTALL_DEPS=1
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

abs_path() {
  local target="$1"
  local dir base
  dir="$(dirname "$target")"
  base="$(basename "$target")"
  mkdir -p "$dir"
  echo "$(cd "$dir" && pwd)/$base"
}

abs_existing_file() {
  local target="$1"
  [[ -f "$target" ]] || { echo "error: file not found: $target" >&2; exit 1; }
  local dir base
  dir="$(cd "$(dirname "$target")" && pwd)"
  base="$(basename "$target")"
  echo "$dir/$base"
}

detect_target() {
  local os arch
  case "$(uname -s)" in
    Linux) os="linux" ;;
    Darwin) os="darwin" ;;
    *) echo "error: unsupported OS $(uname -s)" >&2; exit 1 ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64) arch="x86_64" ;;
    arm64|aarch64) arch="arm64" ;;
    *) echo "error: unsupported architecture $(uname -m)" >&2; exit 1 ;;
  esac
  echo "${os}-${arch}"
}

find_local_repo() {
  local script_path="${BASH_SOURCE[0]:-}"
  if [[ -n "$script_path" && -f "$script_path" ]]; then
    local script_dir root
    script_dir="$(cd "$(dirname "$script_path")" && pwd)"
    root="$(cd "$script_dir/.." && pwd)"
    if [[ -f "$root/ingots/feracle/fe.toml" && -f "$root/ingots/wasm/fe.toml" ]]; then
      echo "$root"
      return 0
    fi
  fi
  if [[ -f "$PWD/ingots/feracle/fe.toml" && -f "$PWD/ingots/wasm/fe.toml" ]]; then
    echo "$PWD"
    return 0
  fi
  return 1
}

write_wrappers() {
  local dest="$1"

  cat >"$dest/bin/feracle-telemetry" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARE_DIR="$(cd "$BIN_DIR/../share/feracle" && pwd)"

# shellcheck disable=SC1091
source "$SHARE_DIR/scripts/ensure-deps.sh"
ensure_node

exec node "$SHARE_DIR/telemetry/host.mjs" \
  --wasm "$SHARE_DIR/out/telemetry_wasm.wasm" \
  "$@"
EOF
  chmod +x "$dest/bin/feracle-telemetry"

  cat >"$dest/bin/feracle-demo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARE_DIR="$(cd "$BIN_DIR/../share/feracle" && pwd)"
BACKEND="${P2P_BACKEND:-libp2p}"
METRICS_PORT=9200
USE_MOCK_FEEDS=0

usage() {
  cat <<'HELP'
Launch a local 4-node Feracle devnet (Anvil + live feeds or --mock-feeds + WASM telemetry TUI)

Usage: feracle-demo [OPTIONS]

Options:
  --backend <libp2p|tcp|udp>  P2P backend (default: libp2p or $P2P_BACKEND)
  --metrics-port <PORT>       Prometheus/JSON HTTP port (default: 9200)
  --mock-feeds                Use local infra/mock_feeds.py instead of live exchange feeds via Caddy
  -h, --help                  Print help
HELP
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
source "$SHARE_DIR/scripts/ensure-deps.sh"
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
ADDR3="0x90F79bf6EB2c4f870365E785982E1f101E93b906"
PK3="0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6"

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

BYTECODE="0x$(tr -d '\r\n' < "$SHARE_DIR/ingots/evm/out/OffchainMedianOracle.bin")"
DEPLOY_JSON="$(cast send --rpc-url "$RPC_URL" --private-key "$PK0" --json --create "$BYTECODE")"
CONTRACT_ADDR="$(node -e 'const fs=require("fs"); console.log(JSON.parse(fs.readFileSync(0,"utf8")).contractAddress)' <<<"$DEPLOY_JSON")"
cast send "$CONTRACT_ADDR" "addOracle(address)" "$ADDR0" --rpc-url "$RPC_URL" --private-key "$PK0" >/dev/null
cast send "$CONTRACT_ADDR" "addOracle(address)" "$ADDR1" --rpc-url "$RPC_URL" --private-key "$PK0" >/dev/null
cast send "$CONTRACT_ADDR" "addOracle(address)" "$ADDR2" --rpc-url "$RPC_URL" --private-key "$PK0" >/dev/null
cast send "$CONTRACT_ADDR" "addOracle(address)" "$ADDR3" --rpc-url "$RPC_URL" --private-key "$PK0" >/dev/null

if [[ "$USE_MOCK_FEEDS" -eq 1 ]]; then
  FEEDS_MODE="mock"
  echo "Starting local mock feeds on :9001..:9003..."
  python3 "$SHARE_DIR/infra/mock_feeds.py" >"$LOG_DIR/feeds.log" 2>&1 &
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
  caddy run --config "$SHARE_DIR/infra/Caddyfile" --adapter caddyfile >"$LOG_DIR/feeds.log" 2>&1 &
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

FERACLE_PRIVKEY_HEX="$PK0" "$BIN_DIR/feracle" \
  --node-id 0 --p2p-backend "$BACKEND" --p2p-port 7001 --telemetry-port 9101 \
  --sources "hyperliquid=127.0.0.1:9001,binance=127.0.0.1:9002" \
  --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 0 --round-timeout-secs 25 \
  >"$LOG_DIR/node0.log" 2>&1 &
PID0=$!

sleep 0.3
FERACLE_PRIVKEY_HEX="$PK1" "$BIN_DIR/feracle" \
  --node-id 1 --p2p-backend "$BACKEND" --p2p-port 7002 --telemetry-port 9102 \
  --bootstrap "/ip4/127.0.0.1/tcp/7001" \
  --sources "binance=127.0.0.1:9002,coinbase=127.0.0.1:9003" \
  --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 0 --round-timeout-secs 25 \
  >"$LOG_DIR/node1.log" 2>&1 &
PID1=$!

FERACLE_PRIVKEY_HEX="$PK2" "$BIN_DIR/feracle" \
  --node-id 2 --p2p-backend "$BACKEND" --p2p-port 7003 --telemetry-port 9103 \
  --bootstrap "/ip4/127.0.0.1/tcp/7001,/ip4/127.0.0.1/tcp/7002" \
  --sources "hyperliquid=127.0.0.1:9001,coinbase=127.0.0.1:9003" \
  --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 0 --round-timeout-secs 25 \
  >"$LOG_DIR/node2.log" 2>&1 &
PID2=$!

FERACLE_PRIVKEY_HEX="$PK3" "$BIN_DIR/feracle" \
  --node-id 3 --p2p-backend "$BACKEND" --p2p-port 7004 --telemetry-port 9104 \
  --bootstrap "/ip4/127.0.0.1/tcp/7001,/ip4/127.0.0.1/tcp/7002,/ip4/127.0.0.1/tcp/7003" \
  --sources "hyperliquid=127.0.0.1:9001,binance=127.0.0.1:9002,coinbase=127.0.0.1:9003" \
  --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
  --contract "$CONTRACT_ADDR" --rounds 0 --round-timeout-secs 25 \
  >"$LOG_DIR/node3.log" 2>&1 &
PID3=$!
NODE_PIDS=("$PID0" "$PID1" "$PID2" "$PID3")

echo "Launching Feracle WASM telemetry TUI (feeds=$FEEDS_MODE, backend=$BACKEND, metrics http://127.0.0.1:$METRICS_PORT/metrics). Press Ctrl-C to stop."
"$BIN_DIR/feracle-telemetry" \
  --rpc-url "$RPC_URL" \
  --contract "$CONTRACT_ADDR" \
  --oracles "$ADDR0,$ADDR1,$ADDR2,$ADDR3" \
  --nodes "http://127.0.0.1:9101,http://127.0.0.1:9102,http://127.0.0.1:9103,http://127.0.0.1:9104" \
  --metrics-port "$METRICS_PORT" \
  --mode tui
EOF
  chmod +x "$dest/bin/feracle-demo"
}

stage_from_source() {
  local src_dir="$1"
  local stage_dir="$2"

  # shellcheck disable=SC1091
  source "$src_dir/scripts/ensure-deps.sh"
  ensure_fe
  ensure_cargo

  echo "Building Feracle targets (EVM, WASM, Native)..."
  fe build --emit abi,bytecode --out-dir "$src_dir/ingots/evm/out" "$src_dir/ingots/evm"
  "$src_dir/scripts/build-wasm.sh"
  "$src_dir/scripts/build-feracle.sh"

  mkdir -p \
    "$stage_dir/bin" \
    "$stage_dir/share/feracle/out" \
    "$stage_dir/share/feracle/ingots/evm/out" \
    "$stage_dir/share/feracle/telemetry" \
    "$stage_dir/share/feracle/infra" \
    "$stage_dir/share/feracle/scripts"

  cp "$src_dir/out/feracle" "$stage_dir/bin/feracle"
  chmod +x "$stage_dir/bin/feracle"

  cp "$src_dir/out/telemetry_wasm.wasm" "$stage_dir/share/feracle/out/"
  cp "$src_dir/out/telemetry_wasm.manifest.json" "$stage_dir/share/feracle/out/"
  cp "$src_dir/ingots/evm/out/OffchainMedianOracle.bin" "$stage_dir/share/feracle/ingots/evm/out/"
  cp "$src_dir/ingots/evm/out/OffchainMedianOracle.abi.json" "$stage_dir/share/feracle/ingots/evm/out/"
  cp "$src_dir/telemetry/host.mjs" "$stage_dir/share/feracle/telemetry/"
  cp "$src_dir/telemetry/cli.mjs" "$stage_dir/share/feracle/telemetry/"
  cp "$src_dir/telemetry/indexer.mjs" "$stage_dir/share/feracle/telemetry/"
  cp "$src_dir/telemetry/wasm_bridge.mjs" "$stage_dir/share/feracle/telemetry/"
  cp "$src_dir/infra/mock_feeds.py" "$stage_dir/share/feracle/infra/"
  cp "$src_dir/infra/Caddyfile" "$stage_dir/share/feracle/infra/"
  cp "$src_dir/scripts/ensure-deps.sh" "$stage_dir/share/feracle/scripts/"
  chmod +x "$stage_dir/share/feracle/scripts/ensure-deps.sh"

  write_wrappers "$stage_dir"
}

install_stage_dir() {
  local stage_dir="$1"
  local prefix="$2"

  mkdir -p "$prefix/bin" "$prefix/share/feracle"
  cp -R "$stage_dir/bin/." "$prefix/bin/"
  cp -R "$stage_dir/share/feracle/." "$prefix/share/feracle/"
  chmod +x "$prefix/bin/feracle" "$prefix/bin/feracle-telemetry" "$prefix/bin/feracle-demo"
  if [[ -f "$prefix/share/feracle/scripts/ensure-deps.sh" ]]; then
    chmod +x "$prefix/share/feracle/scripts/ensure-deps.sh"
  fi
}

extract_and_install_archive() {
  local archive="$1"
  local prefix="$2"
  local work_dir="$3"
  local tmp_extract="$work_dir/extract"
  rm -rf "$tmp_extract"
  mkdir -p "$tmp_extract"
  tar -xzf "$archive" -C "$tmp_extract"
  [[ -x "$tmp_extract/bin/feracle" && -f "$tmp_extract/share/feracle/out/telemetry_wasm.wasm" ]] || {
    echo "error: invalid Feracle archive layout in $archive" >&2
    exit 1
  }
  install_stage_dir "$tmp_extract" "$prefix"
}

try_download_release() {
  local target="$1"
  local out_archive="$2"
  local token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
  if [[ -n "$token" ]]; then
    local api_url rel_json asset_url
    if [[ "$RELEASE_VERSION" == "latest" ]]; then
      api_url="https://api.github.com/repos/$FERACLE_REPO/releases/latest"
    else
      api_url="https://api.github.com/repos/$FERACLE_REPO/releases/tags/${RELEASE_VERSION}"
    fi
    echo "Checking GitHub release API $api_url for feracle-${target}.tar.gz..."
    rel_json="$(curl -fsSL \
      -H "Authorization: Bearer $token" \
      -H "Accept: application/vnd.github+json" \
      "$api_url")" || return 1
    asset_url="$(printf '%s' "$rel_json" | awk -v target="feracle-${target}.tar.gz" '
      BEGIN { RS="{" }
      $0 ~ "\"name\"[[:space:]]*:[[:space:]]*\"" target "\"" {
        if (match($0, /https:\/\/api\.github\.com\/repos\/[^"]+\/releases\/assets\/[0-9]+/)) {
          print substr($0, RSTART, RLENGTH)
          exit
        }
      }
    ')"
    [[ -n "$asset_url" ]] || return 1
    echo "Downloading release asset feracle-${target}.tar.gz..."
    curl -fsSL \
      -H "Authorization: Bearer $token" \
      -H "Accept: application/octet-stream" \
      "$asset_url" \
      -o "$out_archive"
    return $?
  fi

  local url
  if [[ "$RELEASE_VERSION" == "latest" ]]; then
    url="https://github.com/$FERACLE_REPO/releases/latest/download/feracle-${target}.tar.gz"
  else
    url="https://github.com/$FERACLE_REPO/releases/download/${RELEASE_VERSION}/feracle-${target}.tar.gz"
  fi
  echo "Checking release archive $url..."
  curl -fsSL "$url" -o "$out_archive"
}

main() {
  local work_tmp
  work_tmp="$(mktemp -d)"
  trap 'rm -rf "${work_tmp:-}"' EXIT

  if [[ "$MODE" == "package" ]]; then
    local local_repo
    local_repo="$(find_local_repo)" || {
      echo "error: --package must be run inside a Feracle source checkout" >&2
      exit 1
    }
    local out_tar
    out_tar="$(abs_path "$PACKAGE_OUT")"
    stage_from_source "$local_repo" "$work_tmp/stage"
    tar -C "$work_tmp/stage" -czf "$out_tar" bin share
    echo "Packaged release archive: $out_tar"
    return 0
  fi

  if [[ "$MODE" == "archive" ]]; then
    local archive_abs
    archive_abs="$(abs_existing_file "$ARCHIVE_PATH")"
    extract_and_install_archive "$archive_abs" "$PREFIX" "$work_tmp"
  elif [[ "$MODE" == "auto" ]]; then
    if [[ "$RELEASE_VERSION" == "latest" ]] && local_repo="$(find_local_repo 2>/dev/null)"; then
      stage_from_source "$local_repo" "$work_tmp/stage"
      install_stage_dir "$work_tmp/stage" "$PREFIX"
    else
      local target archive_dl
      target="$(detect_target)"
      archive_dl="$work_tmp/feracle-${target}.tar.gz"
      if try_download_release "$target" "$archive_dl"; then
        extract_and_install_archive "$archive_dl" "$PREFIX" "$work_tmp"
      else
        echo "No prebuilt archive for $target; falling back to source build..."
        git clone --depth 1 "https://github.com/$FERACLE_REPO.git" "$work_tmp/src"
        stage_from_source "$work_tmp/src" "$work_tmp/stage"
        install_stage_dir "$work_tmp/stage" "$PREFIX"
      fi
    fi
  else
    # --from-source
    if local_repo="$(find_local_repo 2>/dev/null)"; then
      stage_from_source "$local_repo" "$work_tmp/stage"
      install_stage_dir "$work_tmp/stage" "$PREFIX"
    else
      git clone --depth 1 "https://github.com/$FERACLE_REPO.git" "$work_tmp/src"
      stage_from_source "$work_tmp/src" "$work_tmp/stage"
      install_stage_dir "$work_tmp/stage" "$PREFIX"
    fi
  fi

  if [[ -f "$PREFIX/share/feracle/scripts/ensure-deps.sh" ]]; then
    # shellcheck disable=SC1091
    source "$PREFIX/share/feracle/scripts/ensure-deps.sh"
    feracle_init_paths
    if [[ "$INSTALL_DEPS" -eq 1 || "$INSTALL_FOUNDRY" -eq 1 ]]; then
      ensure_foundry
      if [[ "$INSTALL_DEPS" -eq 1 ]]; then
        ensure_node
        ensure_caddy
      fi
    fi
  fi

  echo ""
  echo "Installed Feracle to $PREFIX:"
  echo "  - $PREFIX/bin/feracle"
  echo "  - $PREFIX/bin/feracle-telemetry"
  echo "  - $PREFIX/bin/feracle-demo"
  echo "  - $PREFIX/share/feracle/"
  echo ""
  echo "Smoke check:"
  "$PREFIX/bin/feracle" --version
  if declare -F feracle_has_node20 >/dev/null 2>&1 && feracle_has_node20; then
    "$PREFIX/bin/feracle-telemetry" --help | grep -q "Feracle WASM Telemetry Host"
    echo "feracle-telemetry OK"
  else
    echo "note: feracle-telemetry and feracle-demo will auto-install missing dependencies on first run (or pass --install-deps)"
  fi
  "$PREFIX/bin/feracle-demo" --help >/dev/null
  echo "feracle-demo OK"
  echo ""
  case ":$PATH:" in
    *":$PREFIX/bin:"*) ;;
    *)
      echo "Add to your shell PATH:"
      echo "  export PATH=\"$PREFIX/bin:\$PATH\""
      echo ""
      ;;
  esac
  echo "Try it out:"
  echo "  feracle                         # show node CLI help"
  echo "  feracle-telemetry --help        # inspect WASM telemetry host options"
  echo "  feracle-demo                    # launch local Anvil + 4 nodes + live feeds + TUI"
  echo "  feracle-demo --mock-feeds       # run offline with deterministic mock feeds"
}

main
