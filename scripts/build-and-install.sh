#!/usr/bin/env bash
#
# build-and-install.sh - build Nockerl Voice (Release) and install it to
# /Applications. Run on your Mac; the build host and the target are the same.
#
# Signing: use a STABLE identity so macOS keeps the Microphone / Input Monitoring
# / Accessibility grants across rebuilds. Override with CODE_SIGN_IDENTITY.
# (Default "-" is ad-hoc; run scripts/setup-signing.sh once for a stable identity.)
set -euo pipefail

SCHEME="${SCHEME:-NockerlVoice}"
CONFIG="${CONFIG:-Release}"
# Spaced, matching PRODUCT_NAME. Every use of it below is quoted.
APP="${APP:-Nockerl Voice.app}"
APP_NAME="${APP_NAME:-Nockerl Voice}"
DERIVED="${DERIVED:-$HOME/Library/Developer/Xcode/DerivedData/NockerlVoice-deploy}"

# Resolve the signing identity and unlock the signing keychain. Shared with build-dev.sh,
# because both builds need the same stable identity for the same reason: macOS ties
# Microphone / Input Monitoring / Accessibility grants (and Keychain item access) to the
# SIGNING IDENTITY, so every change of identity costs those grants once. Preferring
# Developer ID means local builds are signed with the same identity as the notarized
# release, so the grants held today survive the move to a public build instead of
# resetting on install day. Sets IDENTITY; override with CODE_SIGN_IDENTITY.
. "$(dirname "$0")/signing-identity.sh"

cd "$(dirname "$0")/.."

# Generate the Xcode project from project.yml (XcodeGen). The .xcodeproj is git-ignored.
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

# Stamp the build from git so two installs of the same MARKETING_VERSION are still
# distinguishable: the app shows this bottom-right on Settings. Passed as xcodebuild
# overrides rather than rewritten into project.yml, so a build never dirties the tree.
#   CFBundleVersion  = commit count (monotonic, so it always goes up)
#   GitCommit        = short sha, with "+" appended when the tree had uncommitted changes
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
GIT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo dev)"
if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
  GIT_SHA="${GIT_SHA}+"
fi
MARKETING="$(grep -m1 'MARKETING_VERSION:' project.yml | sed 's/.*"\(.*\)".*/\1/')"

echo "==> Building $SCHEME ($CONFIG) with identity '$IDENTITY'"
echo "==> Version $MARKETING ($BUILD_NUMBER) · $GIT_SHA"
xcodebuild \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  CODE_SIGN_STYLE=Manual \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  GIT_COMMIT="$GIT_SHA" \
  clean build

BUILT="$DERIVED/Build/Products/$CONFIG/$APP"
if [[ ! -d "$BUILT" ]]; then
  echo "error: build product not found at $BUILT" >&2
  exit 1
fi

echo "==> Installing to /Applications/$APP"
osascript -e "quit app \"$APP_NAME\"" 2>/dev/null || true
sleep 1
rm -rf "/Applications/$APP"
cp -R "$BUILT" "/Applications/$APP"

echo "==> Launching $APP_NAME"
open "/Applications/$APP"
echo "==> Done."
