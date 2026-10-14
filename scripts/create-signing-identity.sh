#!/bin/sh
# Creates "Panes Local Signing", a self-signed code-signing certificate in the login keychain.
# build-app.sh signs with it when present, so macOS keeps the Accessibility grant across
# rebuilds (an ad-hoc signature changes with every build and loses the grant).
# Remove it later with Keychain Access, or:
#   security delete-identity -c "Panes Local Signing" ~/Library/Keychains/login.keychain-db
set -eu
NAME="Panes Local Signing"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
    echo "\"$NAME\" already exists."
    exit 0
fi
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
PASS="$(openssl rand -hex 16)"
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
    -out "$WORK/id.p12" -passout "pass:$PASS"
# -T lets codesign use the key without a keychain prompt.
security import "$WORK/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign
echo "Created \"$NAME\". It shows as not trusted, which is expected and doesn't stop signing."
