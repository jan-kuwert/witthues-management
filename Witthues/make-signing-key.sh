#!/bin/zsh
# Run once on any Mac: creates the certificate GitHub signs Witthüs with and stores it as the repository secret
# SIGNING_P12. With it every release has the same signature, so macOS keeps allowing the app to read the mail
# password from the keychain after an update. Running it again makes a new certificate (one more prompt after the
# next update). The key is only kept in the GitHub secret; nothing is written to the repository.
set -euo pipefail
REPO="jan-kuwert/witthues-management"
DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT
cd "$DIR"

cat > cert.cnf <<'EOF'
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=Witthues Signing
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 7300 -config cert.cnf 2>/dev/null
# The password only opens the file; the secret itself is what keeps it private. Same value in release.yml.
/usr/bin/openssl pkcs12 -export -inkey key.pem -in cert.pem -name "Witthues Signing" -out signing.p12 -passout pass:witthues
base64 -i signing.p12 > signing.b64

if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
    gh secret set SIGNING_P12 -R "$REPO" < signing.b64
    echo "Fertig: Secret SIGNING_P12 ist gespeichert. Die nächste Version wird damit signiert."
else
    pbcopy < signing.b64
    open "https://github.com/$REPO/settings/secrets/actions/new"
    echo "Der Schlüssel ist in der Zwischenablage. Auf der geöffneten GitHub-Seite:"
    echo "  Name: SIGNING_P12"
    echo "  Secret: einfügen (⌘V), dann „Add secret“."
fi
