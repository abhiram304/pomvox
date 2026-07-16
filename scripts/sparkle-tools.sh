#!/usr/bin/env bash
#
# sparkle-tools.sh — fetch (once, cached) the Sparkle command-line tools
# (generate_keys, sign_update, generate_appcast) and print their bin dir.
# The version MUST match the SPM pin in Pomvox/project.yml so signatures
# are produced by the same code that verifies them.
#
# Usage:  BIN="$(scripts/sparkle-tools.sh)" && "$BIN/sign_update" ...
set -euo pipefail

VERSION="${SPARKLE_TOOLS_VERSION:-2.9.4}"
CACHE="${SPARKLE_TOOLS_DIR:-$HOME/.cache/pomvox/sparkle-tools/$VERSION}"

if [ ! -x "$CACHE/bin/sign_update" ]; then
  mkdir -p "$CACHE"
  curl -fsSL -o "$CACHE/Sparkle.tar.xz" \
    "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz"
  tar -xf "$CACHE/Sparkle.tar.xz" -C "$CACHE"
fi
[ -x "$CACHE/bin/sign_update" ] || { echo "sparkle tools missing after extract" >&2; exit 1; }
echo "$CACHE/bin"
