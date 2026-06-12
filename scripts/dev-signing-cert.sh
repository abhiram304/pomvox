#!/usr/bin/env bash
# Create a stable, free, self-signed "Murmur Dev" code-signing identity.
#
# Why: from M4 on, Murmur.app uses the Microphone, Input Monitoring, and
# Accessibility TCC permissions. macOS keys those grants to the app's *code
# identity*. An ad-hoc signature ("-") changes identity on every rebuild, so the
# grants reset each build — fatal for iterative engine work. A stable signing
# certificate keeps one identity across rebuilds, so you grant permissions once.
#
# This is the *development* identity. Distribution (Developer ID + notarization)
# is M7 and needs a paid Apple Developer Program account; this does not.
#
# Run once:  scripts/dev-signing-cert.sh
# It will ask for your login-keychain password / an auth prompt (expected).
set -euo pipefail

NAME="Murmur Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if security find-identity -v -p codesigning | grep -q "$NAME"; then
  echo "✓ A valid '$NAME' code-signing identity already exists. Nothing to do."
  security find-identity -v -p codesigning | grep "$NAME"
  exit 0
fi

echo "Generating a self-signed Code Signing certificate ($NAME)…"
cat > "$WORK/cert.conf" <<'EOF'
[ req ]
distinguished_name = dn
x509_extensions = v3
prompt = no
[ dn ]
CN = Murmur Dev
[ v3 ]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$WORK/dev.key" -out "$WORK/dev.crt" -days 3650 -config "$WORK/cert.conf"
# Two things trip up Apple's `security import`, both surfacing as the misleading
# "MAC verification failed (wrong password?)":
#  1. OpenSSL 3.x defaults to a SHA-256 PKCS#12 MAC Apple can't read — `-legacy`
#     restores the SHA-1/3DES format it expects (LibreSSL already uses it and
#     rejects the flag, so only pass it on OpenSSL 3.x).
#  2. An *empty* p12 password fails MAC verification on import — use a throwaway
#     non-empty one (it's only the transport password for the import).
LEGACY=""
if openssl version | grep -q "^OpenSSL 3"; then LEGACY="-legacy"; fi
P12PASS="murmur-dev"
openssl pkcs12 -export $LEGACY -inkey "$WORK/dev.key" -in "$WORK/dev.crt" \
  -out "$WORK/dev.p12" -passout "pass:$P12PASS" -name "$NAME"

echo "Importing into the login keychain (allowing codesign to use the key)…"
security import "$WORK/dev.p12" -k "$KEYCHAIN" -P "$P12PASS" -T /usr/bin/codesign -T /usr/bin/productsign

echo "Trusting the certificate for code signing (you may be prompted to authorize)…"
# User trust domain — no sudo. Makes the identity show as *valid* for codesign.
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$WORK/dev.crt" || {
  echo "!! Trust step failed. The cert is imported but may not be 'valid'." >&2
  echo "   Open Keychain Access → login → certificates → '$NAME' → Trust →" >&2
  echo "   'Code Signing: Always Trust', then re-run this script to verify." >&2
}

echo
echo "Verifying…"
if security find-identity -v -p codesigning | grep -q "$NAME"; then
  echo "✓ '$NAME' is ready:"
  security find-identity -v -p codesigning | grep "$NAME"
else
  echo "!! '$NAME' is not yet a *valid* codesigning identity. See the trust note above." >&2
  exit 1
fi
