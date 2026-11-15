#!/bin/bash
# Makes a self-signed code signing certificate, "Pocket XR Dev", in the login keychain, once. Builds signed with it keep
# the same identity, so macOS remembers Pocket XR's Screen Recording permission between builds. For testing only:
# releases are signed with a Developer ID and notarized.
#
# If this fails, make it by hand: Keychain Access, Certificate Assistant, Create a Certificate. Name "Pocket XR Dev",
# Identity Type "Self Signed Root", Certificate Type "Code Signing".
set -euo pipefail
NAME="Pocket XR Dev"
if security find-identity -v -p codesigning | grep -q "$NAME"; then
  echo "$NAME already exists."
  exit 0
fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem"
# macOS's security tool reads only the older PKCS#12 encryption; LibreSSL (macOS's openssl) writes it by default.
PASS="pocketxr"
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/cert.p12" -passout "pass:$PASS" 2>/dev/null \
  || openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/cert.p12" -passout "pass:$PASS"
security import "$TMP/cert.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign
# Trusted for code signing, so codesign accepts it (asks for your Mac's password once).
security add-trusted-cert -r trustRoot -p codeSign -k "$HOME/Library/Keychains/login.keychain-db" "$TMP/cert.pem"
security find-identity -v -p codesigning | grep "$NAME"
echo "Made $NAME."
