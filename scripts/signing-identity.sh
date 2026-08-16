#!/usr/bin/env bash
#
# signing-identity.sh - resolve the code-signing identity, shared by the production and
# dev build scripts. SOURCE this, do not execute it: it sets IDENTITY in the caller.
#
#   . "$(dirname "$0")/signing-identity.sh"
#
# WHY THIS IS SHARED. Both builds need the SAME resolution, and they need it for the same
# reason, so a second copy would drift. macOS ties Microphone / Input Monitoring /
# Accessibility grants to the CODE SIGNATURE, so an identity that changes between builds
# costs those grants every time.
#
# Identity preference, best first:
#   1. Developer ID Application  : the real thing; identical to what CI ships
#   2. NockerlVoice Local        : stable self-signed fallback (scripts/setup-signing.sh)
#   3. "-"                       : ad-hoc; signature changes every build, grants churn
#
# Ad-hoc is the last resort and never a default. Set CODE_SIGN_IDENTITY to override.

IDENTITY="${CODE_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  AVAILABLE="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  if grep -q "Developer ID Application" <<<"$AVAILABLE"; then
    # Take the full "Developer ID Application: NAME (TEAMID)" string, because codesign needs the
    # exact common name when more than one identity could match.
    IDENTITY="$(sed -n 's/.*"\(Developer ID Application[^"]*\)".*/\1/p' <<<"$AVAILABLE" | head -1)"
  elif grep -q "NockerlVoice Local" <<<"$AVAILABLE"; then
    IDENTITY="NockerlVoice Local"
  else
    IDENTITY="-"
  fi
fi

# Unlock + authorize the signing keychain so codesign never prompts for a password.
if [[ "$IDENTITY" != "-" ]]; then
  SIGN_KC="$HOME/Library/Keychains/nockerl-signing.keychain-db"
  SIGN_PASS="${NV_SIGNING_KC_PASS:-nockerl-signing}"
  if [[ -f "$SIGN_KC" ]]; then
    security unlock-keychain -p "$SIGN_PASS" "$SIGN_KC" 2>/dev/null || true
    security set-key-partition-list -S apple-tool:,apple: -s -k "$SIGN_PASS" "$SIGN_KC" >/dev/null 2>&1 || true
  fi
fi
