#!/usr/bin/env bash
#
# build-dev.sh - build the side-by-side DEV app (NockerlVoiceDev.app) under the
# `Dev` build configuration, WITHOUT touching the production Nockerl Voice install.
#
# WHAT THIS IS FOR
#   The Dev config overrides PRODUCT_BUNDLE_IDENTIFIER to
#   com.dizyx.nockerlvoice.dev and PRODUCT_NAME to NockerlVoiceDev, so this builds
#   a SEPARATE installable app. The new bundle id gets its OWN UserDefaults, Keychain,
#   Application Support/Recordings, Logs, and fresh TCC grants (Microphone / Input
#   Monitoring / Accessibility are all keyed on bundle id) - so a genuine macOS
#   first-run can be tested without wiping the grants or data on the real
#   production install.
#
# ⚠️  HISTORY-STORE ISOLATION IS A PRECONDITION FOR RUNNING THIS BUILD
#   The app is non-sandboxed, so SwiftData's DEFAULT history store is NOT inside a
#   per-bundle-id container: every build that opens the default store opens the SAME
#   transcription history. Without per-id routing the dev app would therefore open the
#   production history, and a "Delete All" in it would destroy the real transcripts.
#   HistoryStore routes through AppPaths.historyStoreURL, which hands any non-production
#   bundle id its OWN namespaced store and keeps the default store only for production,
#   so this dev build is isolated. If that routing is ever removed, do not run this app.
#
# ⚠️  DO NOT RUN THE DEV AND PRODUCTION APPS AT THE SAME TIME
#   Both apps register the SAME global Right-Cmd double-tap hotkey - a system-wide
#   resource (CGEventTap), not keyed on bundle id. If both run, they fight over the
#   hotkey: the second registration fails or the taps interfere. For first-run testing,
#   quit the production app first and run the dev app alone.
#
# ⚠️  THIS SCRIPT NEVER INSTALLS OR LAUNCHES
#   It only compiles and leaves the built .app in DerivedData. It NEVER writes to
#   /Applications/NockerlVoice.app and never auto-launches anything. To run the dev app,
#   `open` the built path printed below - or install it manually to
#   /Applications/NockerlVoiceDev.app.
#
# ⚠️  THE SIGNING IDENTITY MUST BE STABLE. DO NOT PUT IT BACK TO AD-HOC.
#   This script used to default to ad-hoc ("-"), and that made the dev build useless for
#   the one thing it exists to test. macOS keys TCC grants on the CODE SIGNATURE, and an
#   ad-hoc signature's cdhash changes on EVERY build, so the system has no stable identity
#   to remember or to list. The result: pressing Grant for Input Monitoring opened the
#   right System Settings pane, but neither app was listed there, so the permission could
#   never be granted and the first-run gate could never be satisfied.
#
#   The failure is silent and looks like an app bug rather than a signing one, which is
#   exactly why this comment is here. It now defaults to the same identity the production
#   script resolves (see scripts/signing-identity.sh, shared by both).
#
#   This changes ONLY the signature. The bundle id stays com.dizyx.nockerlvoice.dev, so
#   UserDefaults, Keychain service, Application Support, Logs, the history store and TCC
#   records all stay in the dev namespace and the production install is still untouched.
set -euo pipefail

SCHEME="${SCHEME:-NockerlVoice-Dev}"
CONFIG="${CONFIG:-Dev}"
# SEPARATE DerivedData from production (production uses .../NockerlVoice-deploy) so
# the two builds never share build artifacts or clobber each other's products.
DERIVED="${DERIVED:-$HOME/Library/Developer/Xcode/DerivedData/NockerlVoiceDev-deploy}"

# Same resolution as the production script, deliberately: a stable identity is what makes
# the dev app appear in the System Settings permission panes at all. See the warning above.
. "$(dirname "$0")/signing-identity.sh"

cd "$(dirname "$0")/.."

# Generate the Xcode project from project.yml (XcodeGen). The .xcodeproj is git-ignored
# and the Dev config + NockerlVoice-Dev scheme only exist after generation.
if [[ -f project.yml ]]; then
  if command -v xcodegen >/dev/null 2>&1; then
    echo "==> xcodegen generate"
    xcodegen generate --quiet
  elif ! ls ./*.xcodeproj >/dev/null 2>&1; then
    echo "error: project.yml present but xcodegen is not installed. Run: brew install xcodegen" >&2
    exit 1
  fi
fi

if ! ls ./*.xcodeproj >/dev/null 2>&1 && ! ls ./*.xcworkspace >/dev/null 2>&1; then
  echo "error: no Xcode project/workspace found." >&2
  exit 1
fi

# Stamp the dev build from git so it is distinguishable from production (same
# marketing version, but a different build number / commit / DEV product name).
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
GIT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo dev)"
if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
  GIT_SHA="${GIT_SHA}+"
fi

echo "==> Building $SCHEME ($CONFIG) with identity '$IDENTITY'"
echo "==> DEV build - does NOT touch /Applications/NockerlVoice.app"
xcodebuild \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  CODE_SIGN_STYLE=Manual \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  GIT_COMMIT="$GIT_SHA" \
  build

BUILT="$DERIVED/Build/Products/$CONFIG/NockerlVoiceDev.app"
if [[ ! -d "$BUILT" ]]; then
  echo "error: dev build product not found at $BUILT" >&2
  exit 1
fi

echo "==> Dev build complete (NOT installed, NOT launched):"
echo "    $BUILT"
echo "==> Reminder: do NOT run alongside the production Nockerl Voice (shared hotkey)."
echo "==> Done."
