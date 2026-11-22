#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

fe build --out-dir "$ROOT_DIR/out" "$ROOT_DIR/ingots/wasm"
