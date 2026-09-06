#!/bin/bash
# Create a self-signed code-signing identity for Emojintel.
#
# WHY THIS EXISTS
#   Ad-hoc signing (`codesign --sign -`) pins the TCC record to the binary's cdhash.
#   Every rebuild changes the cdhash, so macOS silently revokes Accessibility with no
#   re-prompt -- the app just stops working until you remove and re-add it in System
#   Settings. A stable certificate makes the designated requirement identifier+cert
#   based, so the grant survives rebuilds.
#
# This touches your login keychain and may prompt for your password. Run it once.

set -euo pipefail

NAME="${1:-Emojintel Dev}"
DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
    echo "✓ A certificate named '$NAME' already exists in your keychain."
    echo "  Nothing to do. Delete it in Keychain Access first if you want to recreate it."
    exit 0
fi

echo "Creating self-signed code-signing certificate: $NAME"

cat > "$DIR/openssl.cnf" <<CNF
[ req ]
distinguished_name = dn
prompt             = no
x509_extensions    = ext
[ dn ]
CN = $NAME
[ ext ]
basicConstraints       = critical,CA:false
keyUsage               = critical,digitalSignature
extendedKeyUsage       = critical,codeSigning
subjectKeyIdentifier   = hash
CNF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "$DIR/openssl.cnf" \
    -keyout "$DIR/key.pem" -out "$DIR/cert.pem" 2>/dev/null

openssl pkcs12 -export -legacy \
    -inkey "$DIR/key.pem" -in "$DIR/cert.pem" \
    -out "$DIR/bundle.p12" -passout pass: -name "$NAME" 2>/dev/null \
  || openssl pkcs12 -export \
    -inkey "$DIR/key.pem" -in "$DIR/cert.pem" \
    -out "$DIR/bundle.p12" -passout pass: -name "$NAME" 2>/dev/null

KEYCHAIN="$(security default-keychain | tr -d ' "')"
echo "  importing into $KEYCHAIN"
security import "$DIR/bundle.p12" -k "$KEYCHAIN" -P "" \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null

# Let codesign use the key without prompting on every build.
security set-key-partition-list -S apple-tool:,apple: -s -k "" "$KEYCHAIN" >/dev/null 2>&1 \
  || echo "  (note: could not set partition list; codesign may prompt for your password)"

# Trust it for code signing so it shows up as a valid identity.
security add-trusted-cert -d -r trustRoot -p codeSign -k "$KEYCHAIN" "$DIR/cert.pem" 2>/dev/null \
  || echo "  (note: could not auto-trust; see the Keychain Access fallback below)"

echo
if security find-identity -v -p codesigning | grep -q "$NAME"; then
    echo "✓ Identity is valid and ready:"
    security find-identity -v -p codesigning | grep "$NAME"
    echo
    echo "  Now run:  make install"
else
    cat <<'FALLBACK'
⚠︎  The certificate was imported but is not yet trusted for code signing.

    Fix it in the GUI (30 seconds):
      1. Open Keychain Access → login keychain → Certificates
      2. Double-click "Emojintel Dev"
      3. Expand "Trust", set "Code Signing" to "Always Trust"
      4. Close the window and enter your password

    Then re-run:  security find-identity -v -p codesigning
FALLBACK
fi
