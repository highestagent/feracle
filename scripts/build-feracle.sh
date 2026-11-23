#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

(cd p2p-shim && cargo build --release)

OS="$(uname -s)"
mkdir -p out

if [[ "$OS" == "Darwin" ]]; then
  SDK="$(xcrun --show-sdk-path)"
  fe build --backend native \
    --link "$ROOT_DIR/p2p-shim/target/release/libp2p_shim.a" \
    --link "$SDK/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation.tbd" \
    --link "$SDK/System/Library/Frameworks/SystemConfiguration.framework/SystemConfiguration.tbd" \
    --link-lib iconv \
    --out-dir out \
    ingots/feracle
else
  fe build --backend native \
    --link "$ROOT_DIR/p2p-shim/target/release/libp2p_shim.a" \
    --link-lib pthread \
    --link-lib dl \
    --link-lib m \
    --out-dir out \
    ingots/feracle
fi
