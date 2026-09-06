#!/bin/bash
# Create a self-signed code-signing identity for Emojintel.
#
# WHY THIS EXISTS
#   Ad-hoc signing (`codesign --sign -`) pins the TCC record to the binary's cdhash.
#   Every rebuild changes the cdhash, so macOS silently revokes Accessibility with no
#   re-prompt -- the app just stops working until you remove and re-add it in System
#   Settings. Signing with a stable certificate makes the designated requirement
#     identifier "dev.renee.emojintel" and certificate leaf = H"<fixed hash>"
#   which does NOT change when you rebuild, so the grant survives.
#
# TWO THINGS LEARNED THE HARD WAY (both verified in an isolated keychain):
#   1. `security import` fails MAC verification on a PKCS12 with an EMPTY password.
#      A non-empty passphrase is required. It protects nothing here -- the key never
#      leaves this machine -- it just has to be non-empty.
#   2. The certificate does NOT need to be trusted. codesign signs happily with an
#      untrusted self-signed identity, and the designated requirement it produces is
#      exactly the one we want. So there is no `add-trusted-cert` step, no admin
#      password, and no Keychain Access detour.
#      (Side effect: `security find-identity -v` will report "0 valid identities".
#      That is cosmetic. Use `security find-identity` without -v to see it.)

set -euo pipefail

NAME="${1:-Emojintel Dev}"
P12PASS="emojintel-local"          # non-empty by necessity; not a secret
DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
    echo "✓ A certificate named '$NAME' already exists."
    security find-identity -p codesigning | grep "$NAME" || true
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
    -config "$DIR/openssl.cnf" -keyout "$DIR/key.pem" -out "$DIR/cert.pem" 2>/dev/null
openssl pkcs12 -export -inkey "$DIR/key.pem" -in "$DIR/cert.pem" \
    -out "$DIR/bundle.p12" -passout "pass:$P12PASS" -name "$NAME" 2>/dev/null

KEYCHAIN="$(security default-keychain | tr -d ' "')"
echo "  importing into $KEYCHAIN"
security import "$DIR/bundle.p12" -k "$KEYCHAIN" -P "$P12PASS" \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null

# Best effort: lets codesign use the key without a GUI prompt. Needs the keychain
# password, so it may prompt or fail -- harmless either way, see the note below.
security set-key-partition-list -S apple-tool:,apple: -s "$KEYCHAIN" >/dev/null 2>&1 || true

echo
if ! security find-identity -p codesigning | grep -q "$NAME"; then
    echo "✗ Import reported success but the identity is not visible. Something is off."
    exit 1
fi

# Prove it can actually sign, rather than assuming.
printf '#!/bin/sh\ntrue\n' > "$DIR/canary"
chmod +x "$DIR/canary"
if codesign --force --sign "$NAME" "$DIR/canary" 2>"$DIR/err"; then
    echo "✓ Identity works. Test signature's designated requirement:"
    codesign -d -r- "$DIR/canary" 2>&1 | tail -1 | sed 's/^/    /'
    echo
    echo "  That requirement stays identical across rebuilds — which is the whole point."
    echo "  Next:  make install"
else
    echo "⚠︎  Certificate imported, but the test signature failed:"
    sed 's/^/    /' "$DIR/err"
    echo
    echo "  If macOS shows a prompt asking to use the key, click \"Always Allow\"."
    echo "  Then run:  make install"
fi
