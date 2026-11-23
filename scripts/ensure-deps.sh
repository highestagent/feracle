#!/usr/bin/env bash
# Shared dependency bootstrap helpers for Feracle scripts and installed wrappers.
# Safe to source from scripts that use `set -euo pipefail` and own EXIT traps.

feracle_prepend_path() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  case ":$PATH:" in
    *":$dir:"*) ;;
    *) export PATH="$dir:$PATH" ;;
  esac
}

feracle_node_major() {
  command -v node >/dev/null 2>&1 || return 1
  local major
  major="$(node -p 'parseInt(process.versions.node.split(".")[0], 10)' 2>/dev/null || true)"
  [[ "$major" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$major"
}

feracle_has_node20() {
  local major
  major="$(feracle_node_major || true)"
  [[ -n "$major" ]] && (( major >= 20 ))
}

feracle_init_paths() {
  feracle_prepend_path "$HOME/.cargo/bin"
  feracle_prepend_path "$HOME/.fe/bin"
  feracle_prepend_path "$HOME/.foundry/bin"
  feracle_prepend_path "$HOME/.local/node/bin"
  feracle_prepend_path "$HOME/.local/bin"

  if ! feracle_has_node20; then
    local nvm_dir="${NVM_DIR:-$HOME/.nvm}/versions/node"
    if [[ -d "$nvm_dir" ]]; then
      local best_major=0 best_minor=0 best_patch=0 best_bin=""
      local d ver major minor patch
      for d in "$nvm_dir"/v*/bin; do
        [[ -x "$d/node" ]] || continue
        ver="$(basename "$(dirname "$d")")"
        ver="${ver#v}"
        IFS=. read -r major minor patch <<<"${ver%%-*}"
        major="${major:-0}"
        minor="${minor:-0}"
        patch="${patch:-0}"
        [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ && "$patch" =~ ^[0-9]+$ ]] || continue
        if (( major >= 20 )); then
          if (( major > best_major || (major == best_major && (minor > best_minor || (minor == best_minor && patch > best_patch))) )); then
            best_major=$major
            best_minor=$minor
            best_patch=$patch
            best_bin="$d"
          fi
        fi
      done
      if [[ -n "$best_bin" ]]; then
        feracle_prepend_path "$best_bin"
      fi
    fi
  fi
}

feracle_detect_os_arch() {
  case "$(uname -s)" in
    Linux) FERACLE_OS="linux" ;;
    Darwin) FERACLE_OS="darwin" ;;
    *)
      echo "error: unsupported OS $(uname -s)" >&2
      return 1
      ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64) FERACLE_ARCH="x86_64" ;;
    arm64|aarch64) FERACLE_ARCH="arm64" ;;
    *)
      echo "error: unsupported architecture $(uname -m)" >&2
      return 1
      ;;
  esac
}

ensure_fe() {
  feracle_init_paths
  if command -v fe >/dev/null 2>&1; then
    return 0
  fi
  command -v curl >/dev/null 2>&1 || {
    echo "error: curl is required to install Fe." >&2
    return 1
  }
  local fe_ver="${FE_VERSION:-v26.7.0}"
  echo "Installing Fe toolchain ($fe_ver)..."
  curl -fsSL https://raw.githubusercontent.com/argotorg/fe/master/feup/feup.sh \
    | bash -s -- --version "$fe_ver" --no-modify-path
  feracle_prepend_path "$HOME/.fe/bin"
  command -v fe >/dev/null 2>&1 || {
    echo "error: fe installation completed but fe is still not on PATH." >&2
    return 1
  }
}

ensure_cargo() {
  feracle_init_paths
  if command -v cargo >/dev/null 2>&1; then
    return 0
  fi
  command -v curl >/dev/null 2>&1 || {
    echo "error: curl is required to install Rust (cargo)." >&2
    return 1
  }
  echo "Installing Rust toolchain (rustup)..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --no-modify-path
  feracle_prepend_path "$HOME/.cargo/bin"
  command -v cargo >/dev/null 2>&1 || {
    echo "error: rustup finished but cargo is still not on PATH." >&2
    return 1
  }
}

ensure_foundry() {
  feracle_init_paths
  if command -v anvil >/dev/null 2>&1 && command -v cast >/dev/null 2>&1; then
    return 0
  fi
  command -v curl >/dev/null 2>&1 || {
    echo "error: curl is required to install Foundry (anvil + cast)." >&2
    return 1
  }
  feracle_detect_os_arch

  local foundry_os="$FERACLE_OS"
  local foundry_arch
  case "$FERACLE_ARCH" in
    arm64) foundry_arch="arm64" ;;
    x86_64) foundry_arch="amd64" ;;
  esac

  local url_eff tag archive_name sha_name base_url
  url_eff="$(curl -fsSL -o /dev/null -w '%{url_effective}' https://github.com/foundry-rs/foundry/releases/latest)"
  tag="${url_eff##*/}"
  if [[ -z "$tag" || "$tag" == "$url_eff" ]]; then
    echo "error: failed to resolve latest Foundry release tag from $url_eff" >&2
    return 1
  fi

  archive_name="foundry_${tag}_${foundry_os}_${foundry_arch}.tar.gz"
  sha_name="foundry_${tag}_${foundry_os}_${foundry_arch}.sha256"
  base_url="https://github.com/foundry-rs/foundry/releases/download/${tag}"

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  echo "Installing Foundry ${tag} (${foundry_os}_${foundry_arch}) into $HOME/.foundry/bin..."
  if ! curl -fsSL "${base_url}/${archive_name}" -o "$tmp_dir/$archive_name"; then
    rm -rf "$tmp_dir"
    echo "error: failed to download Foundry archive ${base_url}/${archive_name}" >&2
    return 1
  fi
  if ! curl -fsSL "${base_url}/${sha_name}" -o "$tmp_dir/$sha_name"; then
    rm -rf "$tmp_dir"
    echo "error: failed to download Foundry checksum ${base_url}/${sha_name}" >&2
    return 1
  fi

  local expected_sha actual_sha=""
  expected_sha="$(awk '{print $1}' "$tmp_dir/$sha_name" | head -n 1 || true)"
  if command -v sha256sum >/dev/null 2>&1; then
    actual_sha="$(sha256sum "$tmp_dir/$archive_name" | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    actual_sha="$(shasum -a 256 "$tmp_dir/$archive_name" | awk '{print $1}')"
  else
    rm -rf "$tmp_dir"
    echo "error: sha256sum or shasum is required to verify Foundry archive" >&2
    return 1
  fi
  if [[ -z "$expected_sha" || "$actual_sha" != "$expected_sha" ]]; then
    rm -rf "$tmp_dir"
    echo "error: SHA-256 mismatch for $archive_name (expected $expected_sha, got $actual_sha)" >&2
    return 1
  fi

  mkdir -p "$HOME/.foundry/bin"
  if ! tar -xzf "$tmp_dir/$archive_name" -C "$HOME/.foundry/bin"; then
    rm -rf "$tmp_dir"
    echo "error: failed to extract $archive_name into $HOME/.foundry/bin" >&2
    return 1
  fi
  chmod +x "$HOME/.foundry/bin"/* 2>/dev/null || true
  if [[ "$FERACLE_OS" == "darwin" ]] && command -v xattr >/dev/null 2>&1; then
    xattr -d com.apple.quarantine "$HOME/.foundry/bin"/* 2>/dev/null || true
  fi
  rm -rf "$tmp_dir"

  feracle_prepend_path "$HOME/.foundry/bin"
  anvil --version >/dev/null 2>&1 && cast --version >/dev/null 2>&1 || {
    echo "error: Foundry installation completed but anvil/cast verification failed." >&2
    return 1
  }
}

ensure_node() {
  feracle_init_paths
  if feracle_has_node20; then
    return 0
  fi
  command -v curl >/dev/null 2>&1 || {
    echo "error: curl is required to install Node.js (>= 20)." >&2
    return 1
  }
  feracle_detect_os_arch

  local node_os="$FERACLE_OS"
  local node_arch
  case "$FERACLE_ARCH" in
    arm64) node_arch="arm64" ;;
    x86_64) node_arch="x64" ;;
  esac

  local tmp_dir
  tmp_dir="$(mktemp -d)"

  local shasums_url="https://nodejs.org/dist/latest-v22.x/SHASUMS256.txt"
  echo "Installing Node.js v22 LTS (${node_os}-${node_arch}) into $HOME/.local/node..."
  if ! curl -fsSL "$shasums_url" -o "$tmp_dir/SHASUMS256.txt"; then
    rm -rf "$tmp_dir"
    echo "error: failed to fetch Node.js checksums from $shasums_url" >&2
    return 1
  fi

  local sha_line expected_sha filename
  sha_line="$(grep -E " node-v22\.[0-9]+\.[0-9]+-${node_os}-${node_arch}\.tar\.gz$" "$tmp_dir/SHASUMS256.txt" | head -n 1 || true)"
  expected_sha="$(awk '{print $1}' <<<"$sha_line")"
  filename="$(awk '{print $2}' <<<"$sha_line")"
  if [[ -z "$expected_sha" || -z "$filename" ]]; then
    rm -rf "$tmp_dir"
    echo "error: could not locate Node.js v22 archive for ${node_os}-${node_arch}" >&2
    return 1
  fi

  if ! curl -fsSL "https://nodejs.org/dist/latest-v22.x/${filename}" -o "$tmp_dir/$filename"; then
    rm -rf "$tmp_dir"
    echo "error: failed to download Node.js archive $filename" >&2
    return 1
  fi

  local actual_sha=""
  if command -v sha256sum >/dev/null 2>&1; then
    actual_sha="$(sha256sum "$tmp_dir/$filename" | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    actual_sha="$(shasum -a 256 "$tmp_dir/$filename" | awk '{print $1}')"
  else
    rm -rf "$tmp_dir"
    echo "error: sha256sum or shasum is required to verify Node.js archive" >&2
    return 1
  fi

  if [[ "$actual_sha" != "$expected_sha" ]]; then
    rm -rf "$tmp_dir"
    echo "error: SHA-256 mismatch for $filename (expected $expected_sha, got $actual_sha)" >&2
    return 1
  fi

  rm -rf "$HOME/.local/node"
  mkdir -p "$HOME/.local/node" "$HOME/.local/bin"
  if ! tar -xzf "$tmp_dir/$filename" -C "$HOME/.local/node" --strip-components=1; then
    rm -rf "$tmp_dir"
    echo "error: failed to extract Node.js archive $filename" >&2
    return 1
  fi
  rm -rf "$tmp_dir"

  local tool
  for tool in node npm npx; do
    if [[ -x "$HOME/.local/node/bin/$tool" ]]; then
      ln -sf "$HOME/.local/node/bin/$tool" "$HOME/.local/bin/$tool"
    fi
  done

  feracle_prepend_path "$HOME/.local/node/bin"
  feracle_prepend_path "$HOME/.local/bin"
  feracle_has_node20 || {
    echo "error: Node.js (>= 20) installation completed but verification failed." >&2
    return 1
  }
}

ensure_caddy() {
  feracle_init_paths
  if command -v caddy >/dev/null 2>&1; then
    return 0
  fi
  command -v curl >/dev/null 2>&1 || {
    echo "error: curl is required to install Caddy." >&2
    return 1
  }
  feracle_detect_os_arch

  local caddy_os caddy_arch
  case "$FERACLE_OS" in
    darwin) caddy_os="mac" ;;
    linux) caddy_os="linux" ;;
  esac
  case "$FERACLE_ARCH" in
    arm64) caddy_arch="arm64" ;;
    x86_64) caddy_arch="amd64" ;;
  esac

  local url_eff ver asset_url
  url_eff="$(curl -fsSL -o /dev/null -w '%{url_effective}' https://github.com/caddyserver/caddy/releases/latest)"
  ver="${url_eff##*/v}"
  if [[ -z "$ver" || "$ver" == "$url_eff" ]]; then
    echo "error: failed to resolve latest Caddy release tag from $url_eff" >&2
    return 1
  fi

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  asset_url="https://github.com/caddyserver/caddy/releases/download/v${ver}/caddy_${ver}_${caddy_os}_${caddy_arch}.tar.gz"
  echo "Installing Caddy v${ver} (${caddy_os}_${caddy_arch}) into $HOME/.local/bin..."
  if ! curl -fsSL "$asset_url" -o "$tmp_dir/caddy.tar.gz"; then
    rm -rf "$tmp_dir"
    echo "error: failed to download Caddy from $asset_url" >&2
    return 1
  fi

  mkdir -p "$HOME/.local/bin"
  if ! tar -xzf "$tmp_dir/caddy.tar.gz" -C "$tmp_dir" caddy || [[ ! -f "$tmp_dir/caddy" ]]; then
    rm -rf "$tmp_dir"
    echo "error: failed to extract caddy binary from $asset_url" >&2
    return 1
  fi

  cp "$tmp_dir/caddy" "$HOME/.local/bin/caddy"
  chmod +x "$HOME/.local/bin/caddy"
  if [[ "$FERACLE_OS" == "darwin" ]] && command -v xattr >/dev/null 2>&1; then
    xattr -d com.apple.quarantine "$HOME/.local/bin/caddy" 2>/dev/null || true
  fi
  rm -rf "$tmp_dir"

  feracle_prepend_path "$HOME/.local/bin"
  caddy version >/dev/null 2>&1 || {
    echo "error: Caddy installation finished but 'caddy version' failed." >&2
    return 1
  }
}

ensure_python3() {
  feracle_init_paths
  if command -v python3 >/dev/null 2>&1; then
    return 0
  fi

  echo "Installing Python 3..."
  case "$(uname -s)" in
    Darwin)
      if command -v brew >/dev/null 2>&1; then
        brew install python
      fi
      ;;
    Linux)
      local sudo_cmd=""
      if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
          sudo_cmd="sudo -n"
        fi
      fi
      if [[ "${EUID:-$(id -u)}" -eq 0 || -n "$sudo_cmd" ]]; then
        if command -v apt-get >/dev/null 2>&1; then
          $sudo_cmd apt-get update && $sudo_cmd apt-get install -y python3
        elif command -v dnf >/dev/null 2>&1; then
          $sudo_cmd dnf install -y python3
        elif command -v yum >/dev/null 2>&1; then
          $sudo_cmd yum install -y python3
        elif command -v pacman >/dev/null 2>&1; then
          $sudo_cmd pacman -Sy --noconfirm python
        elif command -v apk >/dev/null 2>&1; then
          $sudo_cmd apk add --no-cache python3
        fi
      fi
      ;;
  esac

  command -v python3 >/dev/null 2>&1 || {
    echo "error: python3 is required for mock feeds / E2E checks and could not be installed automatically." >&2
    return 1
  }
}

if [[ "${BASH_SOURCE[0]:-}" == "$0" ]]; then
  set -euo pipefail
  if [[ $# -eq 0 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    cat <<'EOF'
Usage: ensure-deps.sh <dep>...

Supported targets:
  fe       Install Fe toolchain if missing
  cargo    Install Rust toolchain (cargo) if missing
  foundry  Install Foundry (anvil + cast) if missing
  node     Install Node.js (>= 20) if missing or older
  caddy    Install Caddy reverse proxy if missing
  python3  Install Python 3 if missing
  runtime  Install runtime devnet dependencies (foundry, node, caddy)
  all      Install build, runtime, and test dependencies
EOF
    exit 0
  fi
  for target in "$@"; do
    case "$target" in
      fe) ensure_fe ;;
      cargo) ensure_cargo ;;
      foundry) ensure_foundry ;;
      node) ensure_node ;;
      caddy) ensure_caddy ;;
      python3) ensure_python3 ;;
      runtime)
        ensure_foundry
        ensure_node
        ensure_caddy
        ;;
      all)
        ensure_fe
        ensure_cargo
        ensure_foundry
        ensure_node
        ensure_caddy
        ensure_python3
        ;;
      *)
        echo "error: unknown dependency target '$target'" >&2
        exit 2
        ;;
    esac
  done
fi
