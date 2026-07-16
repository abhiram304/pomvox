#!/usr/bin/env bash
#
# sparkle-tools.sh — fetch (once, cached) the Sparkle command-line tools
# (generate_keys, sign_update, generate_appcast) and print their bin dir.
# The version MUST match the SPM pin in Pomvox/project.yml so signatures
# are produced by the same code that verifies them.
#
# The downloaded tarball provides sign_update, which signs every shipped
# update — it is verified against a pinned sha256 before extraction so a
# compromised mirror/MITM can't slip in a malicious signer.
#
# Usage:  BIN="$(scripts/sparkle-tools.sh)" && "$BIN/sign_update" ...
set -euo pipefail

VERSION="${SPARKLE_TOOLS_VERSION:-2.9.4}"
CACHE="${SPARKLE_TOOLS_DIR:-$HOME/.cache/pomvox/sparkle-tools/$VERSION}"
# Pinned hash for Sparkle-2.9.4.tar.xz. Must be updated (recompute with
# `shasum -a 256`) whenever SPARKLE_TOOLS_VERSION changes; overridable via
# env for pinning a different version.
SPARKLE_TOOLS_SHA256="${SPARKLE_TOOLS_SHA256:-}"
if [ "$VERSION" = "2.9.4" ] && [ -z "$SPARKLE_TOOLS_SHA256" ]; then
  SPARKLE_TOOLS_SHA256="ce89daf967db1e1893ed3ebd67575ed82d3902563e3191ca92aaec9164fbdef9"
fi
[ -n "$SPARKLE_TOOLS_SHA256" ] || {
  echo "SPARKLE_TOOLS_VERSION=$VERSION has no pinned hash — set SPARKLE_TOOLS_SHA256 to proceed" >&2
  exit 1
}

if [ ! -x "$CACHE/bin/sign_update" ]; then
  mkdir -p "$CACHE"
  curl -fsSL -o "$CACHE/Sparkle.tar.xz" \
    "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz"
  if ! echo "$SPARKLE_TOOLS_SHA256  $CACHE/Sparkle.tar.xz" | shasum -a 256 -c - >/dev/null 2>&1; then
    ACTUAL="$(shasum -a 256 "$CACHE/Sparkle.tar.xz" | awk '{print $1}')"
    rm -f "$CACHE/Sparkle.tar.xz"
    echo "sparkle tools sha256 mismatch: expected $SPARKLE_TOOLS_SHA256, got $ACTUAL — refusing to extract" >&2
    exit 1
  fi
  tar -xf "$CACHE/Sparkle.tar.xz" -C "$CACHE"
fi
[ -x "$CACHE/bin/sign_update" ] || { echo "sparkle tools missing after extract" >&2; exit 1; }
echo "$CACHE/bin"
