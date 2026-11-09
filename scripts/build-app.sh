#!/bin/bash
# Builds build/Tolk.app (release) and signs it.
# Signing identity: $TOLK_SIGN_ID (default "Tolk Local Signing", see make-signing-cert.sh);
# falls back to ad-hoc signing if that identity is not in the keychain.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SIGN_ID="${TOLK_SIGN_ID:-Tolk Local Signing}"
APP="$ROOT/build/Tolk.app"

# App icon: generated once by make-icon.sh (Resources/AppIcon.icns, referenced by CFBundleIconFile).
if [ ! -f "$ROOT/Resources/AppIcon.icns" ]; then
    echo "==> generating app icon"
    "$ROOT/scripts/make-icon.sh" "$ROOT/Resources/AppIcon.icns"
fi

echo "==> swift build -c release"
swift build -c release --product Tolk
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Tolk" "$APP/Contents/MacOS/Tolk"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
# Everything in Resources/ besides Info.plist (AppIcon.icns etc.) goes to Contents/Resources.
find "$ROOT/Resources" -mindepth 1 -maxdepth 1 ! -name Info.plist -exec cp -R {} "$APP/Contents/Resources/" \;
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Version: VERSION file is the single source of truth. Build number = commit count (always grows),
# TolkGitCommit = short hash (+ "-dirty" with uncommitted changes) — shown in Settings and crash reports.
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
BUILD="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 0)"
COMMIT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]; then COMMIT="$COMMIT-dirty"; fi
PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"
/usr/libexec/PlistBuddy -c "Delete :TolkGitCommit" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :TolkGitCommit string $COMMIT" "$PLIST"
echo "==> version $VERSION (build $BUILD, $COMMIT)"

if security find-identity -v -p codesigning | grep -qF "\"$SIGN_ID\""; then
    echo "==> signing with \"$SIGN_ID\""
    codesign --force --deep --options runtime --sign "$SIGN_ID" "$APP"
else
    echo "WARNING: signing identity \"$SIGN_ID\" not found in keychain — using ad-hoc signature." >&2
    echo "WARNING: macOS will reset the Accessibility permission after every rebuild." >&2
    echo "WARNING: run scripts/make-signing-cert.sh once to fix this." >&2
    codesign --force --deep --sign - "$APP"
fi

codesign --verify --strict "$APP"
echo "==> done: $APP"
