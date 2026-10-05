#!/usr/bin/env bash
# Crée, une seule fois, un certificat de signature local « Halo Developer » dans le trousseau de session.
# Signé avec lui, Halo garde la même identité d'une version à l'autre : macOS conserve alors
# l'autorisation Accessibilité après chaque mise à jour (avec une signature ad hoc, il l'oublie).
# Le certificat reste sur ce Mac ; il n'est pas « approuvé » par le système et n'en a pas besoin.
set -euo pipefail

NAME="Halo Developer"
if security find-identity -p codesigning | grep -q "\"$NAME\""; then
  echo "Le certificat « $NAME » existe déjà."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS="$(openssl rand -hex 16)"

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -subj "/CN=$NAME" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

/usr/bin/openssl pkcs12 -export -name "$NAME" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/cert.p12" -passout "pass:$PASS"

# -T : codesign peut utiliser la clé sans redemander.
security import "$TMP/cert.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign >/dev/null

echo "Certificat « $NAME » créé. ./scripts/build-app.sh signera Halo avec."
