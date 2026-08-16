#!/usr/bin/env bash
#
# setup-signing.sh: create + trust a STABLE self-signed code-signing identity so
# macOS keeps the Microphone / Input Monitoring / Accessibility grants across
# rebuilds. (Ad-hoc signing changes the cdhash every build, which resets them.)
#
# RUN ONCE ON YOUR MAC, IN YOUR OWN TERMINAL - the trust step prompts for your
# login password and cannot be completed over headless SSH. Idempotent: safe to
# re-run. Uses a dedicated keychain with a throwaway password (not your login
# keychain) for the key; trust is recorded in your login keychain.
set -euo pipefail

IDENTITY="${IDENTITY:-NockerlVoice Local}"
KEYCHAIN="$HOME/Library/Keychains/nockerl-signing.keychain-db"
KC_PASS="${NV_SIGNING_KC_PASS:-nockerl-signing}"
LOGIN_KC="$HOME/Library/Keychains/login.keychain-db"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

trusted()  { security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; }
imported() { security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY"; }

if trusted; then
  echo "'$IDENTITY' is already set up and valid. Nothing to do."
  exit 0
fi

if ! imported; then
  echo "==> Creating self-signed code-signing certificate"
  cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $IDENTITY
[v3]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF
  /usr/bin/openssl req -x509 -newkey rsa:2048 -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -days 3650 -nodes -config "$WORK/cert.cnf" >/dev/null 2>&1
  make_p12() {
    "$1" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
      -out "$WORK/id.p12" -passout pass:nv -name "$IDENTITY" "${@:2}" >/dev/null 2>&1
  }
  make_p12 /usr/bin/openssl || make_p12 openssl -legacy || make_p12 openssl

  echo "==> Importing the key into a dedicated keychain (throwaway password)"
  security create-keychain -p "$KC_PASS" "$KEYCHAIN" 2>/dev/null || true
  security set-keychain-settings "$KEYCHAIN"
  security unlock-keychain -p "$KC_PASS" "$KEYCHAIN"
  security import "$WORK/id.p12" -k "$KEYCHAIN" -P nv -T /usr/bin/codesign -A
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PASS" "$KEYCHAIN" >/dev/null 2>&1 || true

  # Add to the user search list, preserving existing entries.
  OLD=()
  while IFS= read -r line; do
    kc="$(printf '%s' "$line" | sed -E 's/^[[:space:]]*"(.*)"[[:space:]]*$/\1/')"
    [ -n "$kc" ] && OLD+=("$kc")
  done < <(security list-keychains -d user)
  case " ${OLD[*]} " in
    *" $KEYCHAIN "*) : ;;
    *) security list-keychains -d user -s "$KEYCHAIN" "${OLD[@]}" ;;
  esac
  security list-keychains -d user | grep -q "login.keychain-db" \
    || security list-keychains -d user -s "$KEYCHAIN" "$LOGIN_KC"
fi

echo "==> Trusting the certificate for code signing"
echo "    (macOS will prompt for your LOGIN PASSWORD, as expected.)"
security find-certificate -c "$IDENTITY" -p "$KEYCHAIN" > "$WORK/trust.pem"
security add-trusted-cert -r trustRoot -p codeSign -k "$LOGIN_KC" "$WORK/trust.pem"

if trusted; then
  echo "Stable signing identity ready:"
  security find-identity -v -p codesigning | grep "$IDENTITY"
  echo "Rebuild with ./scripts/build-and-install.sh. It auto-detects this identity."
else
  echo "Trust step did not complete (look for a password prompt and retry)." >&2
  exit 1
fi
