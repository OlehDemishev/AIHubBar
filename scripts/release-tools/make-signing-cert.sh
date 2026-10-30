#!/bin/bash
# A self-signed code signing certificate for release builds, made once and kept as files (not in the login keychain).
# The same certificate on every release keeps macOS permissions (Terminal automation, notifications) and lets
# Sparkle accept updates. It is not an Apple Developer ID: the first launch still needs «Открыть всё равно».
# Files go to $CLAUDEPULT_RELEASE_DIR (default ~/Library/Application Support/ClaudePult-release). Back them up.
set -euo pipefail
DIR="${CLAUDEPULT_RELEASE_DIR:-$HOME/Library/Application Support/ClaudePult-release}"
mkdir -p "$DIR" && chmod 700 "$DIR"
if [[ -e "$DIR/codesign.p12" ]]; then
  echo "A certificate already exists in $DIR; not overwriting." >&2
  exit 1
fi
CONF="$(mktemp)"
trap 'rm -f "$CONF"' EXIT
cat > "$CONF" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = ClaudePult Release
O = Oleh Demishev
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF
umask 077
openssl req -x509 -newkey rsa:3072 -nodes -days 3650 -config "$CONF" -keyout "$DIR/codesign.key" -out "$DIR/codesign.crt" 2>/dev/null
openssl rand -base64 24 > "$DIR/codesign.pass"
openssl pkcs12 -export -inkey "$DIR/codesign.key" -in "$DIR/codesign.crt" -name "ClaudePult Release" \
  -passout "file:$DIR/codesign.pass" -out "$DIR/codesign.p12"
rm "$DIR/codesign.key"
echo "Certificate: $(openssl x509 -in "$DIR/codesign.crt" -noout -subject -enddate | tr '\n' ' ')"
