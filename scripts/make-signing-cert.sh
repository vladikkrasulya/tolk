#!/bin/bash
# Creates a self-signed code-signing certificate "Tolk Local Signing" in the login keychain,
# so rebuilt Tolk.app keeps the same signature identity and Accessibility permission survives.
# macOS may ask for your login password (keychain trust settings). Run once.
set -euo pipefail

NAME="${TOLK_SIGN_ID:-Tolk Local Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -qF "\"$NAME\""; then
    echo "Identity \"$NAME\" already exists and is valid — nothing to do."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"

# System LibreSSL writes PKCS#12 in a format `security import` accepts.
OPENSSL=/usr/bin/openssl

cat > cert.cnf <<CNF
[ req ]
distinguished_name = dn
prompt             = no
x509_extensions    = ext
[ dn ]
CN = $NAME
[ ext ]
basicConstraints       = critical, CA:false
keyUsage               = critical, digitalSignature
extendedKeyUsage       = critical, codeSigning
subjectKeyIdentifier   = hash
CNF

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout key.pem -out cert.pem -config cert.cnf

P12_PASS="tolk-$$-$RANDOM"
P12_ARGS=()
# OpenSSL 3+ defaults to algorithms the macOS keychain can't read.
if "$OPENSSL" version | grep -q '^OpenSSL [3-9]'; then P12_ARGS+=(-legacy); fi
"$OPENSSL" pkcs12 -export ${P12_ARGS[@]+"${P12_ARGS[@]}"} -inkey key.pem -in cert.pem \
    -name "$NAME" -out tolk.p12 -passout "pass:$P12_PASS"

echo "==> importing into login keychain (codesign allowed to use the key)"
security import tolk.p12 -k "$KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign

echo "==> trusting the certificate for code signing (may ask for your password)"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" cert.pem

security find-identity -v -p codesigning | grep -F "\"$NAME\"" \
    && echo "Done. Rebuild with scripts/build-app.sh, then grant Accessibility once more (last time)."
