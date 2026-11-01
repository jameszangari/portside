#!/bin/bash
set -euo pipefail
umask 077

name="Portside Local Development"
state="$HOME/Library/Application Support/com.james.portside/signing"
root="$(cd "$(dirname "$0")/.." && pwd)"
ensure_access="$root/scripts/ensure-codesign-key-access.sh"

if [ -f "$state/identity.sha1" ]; then
    saved_identity="$(tr -d '[:space:]' < "$state/identity.sha1")"
    if ! [[ "$saved_identity" =~ ^[[:xdigit:]]{40}$ ]]; then
        echo "setup-signing: the saved signing fingerprint is invalid. Restore identity.sha1 from your backup; no identity was changed." >&2
        exit 1
    fi
    identities="$(security find-identity -v -p codesigning)"
    if ! printf '%s\n' "$identities" | awk -v fingerprint="$saved_identity" '$2 == fingerprint { found = 1 } END { exit !found }'; then
        echo "setup-signing: the saved signing identity is unavailable. Unlock your keychain or restore its certificate and private key; no identity was changed." >&2
        exit 1
    fi
    echo "Reusing the saved Portside signing identity."
    "$ensure_access"
    exit 0
fi

keychain="$(security default-keychain -d user | sed -E 's/^[[:space:]]*"(.*)"$/\1/')"

identities="$(security find-identity -v -p codesigning "$keychain")"
matches="$(printf '%s\n' "$identities" | awk -v name="\"$name\"" 'index($0, name) { print $2 }')"
if [ -n "$matches" ]; then
    if [ "$(printf '%s\n' "$matches" | wc -l | tr -d ' ')" != 1 ]; then
        echo "setup-signing: multiple '$name' identities found. Resolve the duplicates in Keychain Access first." >&2
        exit 1
    fi
    mkdir -p "$state"
    printf '%s\n' "$matches" > "$state/identity.sha1.tmp"
    mv "$state/identity.sha1.tmp" "$state/identity.sha1"
    echo "Reusing '$name' from your default keychain."
    "$ensure_access"
    exit 0
fi

if security find-certificate -c "$name" "$keychain" >/dev/null 2>&1; then
    echo "setup-signing: the existing Portside signing identity is unavailable or untrusted." >&2
    echo "Unlock your keychain and check '$name' in Keychain Access. Its private key and Code Signing trust must be available. No replacement was created." >&2
    exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cat > "$work/certificate.conf" <<'CERTIFICATE'
[req]
distinguished_name = subject
x509_extensions = signing
prompt = no
[subject]
CN = Portside Local Development
[signing]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CERTIFICATE

echo "==> Creating a local Portside code signing certificate (valid for 10 years)"
/usr/bin/openssl req -new -newkey rsa:3072 -x509 -sha256 -nodes -days 3650 \
    -config "$work/certificate.conf" -keyout "$work/key.pem" -out "$work/certificate.pem" \
    2> "$work/openssl.log" || { cat "$work/openssl.log" >&2; exit 1; }
/usr/bin/openssl rand -base64 32 > "$work/password"
/usr/bin/openssl pkcs12 -export -name "$name" \
    -inkey "$work/key.pem" -in "$work/certificate.pem" \
    -out "$work/identity.p12" -passout "file:$work/password"

echo "==> Importing into your default keychain; only codesign is granted key access"
security import "$work/identity.p12" -k "$keychain" -f pkcs12 -x \
    -P "$(cat "$work/password")" -T /usr/bin/codesign
echo "==> Trusting this certificate for code signing in your user account"
security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$work/certificate.pem"

fingerprint="$(/usr/bin/openssl x509 -in "$work/certificate.pem" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':')"
if ! security find-identity -v -p codesigning "$keychain" | grep -Fq "$fingerprint"; then
    echo "setup-signing: macOS has not accepted the identity. Check its Code Signing trust in Keychain Access, then run this script again." >&2
    exit 1
fi

mkdir -p "$state"
printf '%s\n' "$fingerprint" > "$state/identity.sha1.tmp"
mv "$state/identity.sha1.tmp" "$state/identity.sha1"

# -T alone is not enough on modern macOS. Widen the partition list via GUI if needed.
"$ensure_access"
echo "Ready. scripts/build-app.sh will reuse this identity on future builds."
