#!/bin/sh
# Builds Tern (helper + app) and runs it, signed with your Apple Development certificate.
set -e
cd "$(dirname "$0")/.."
IDENTITY="${TERN_SIGN_IDENTITY:-Apple Development}"
sh scripts/build-ternd.sh
xcodegen generate >/dev/null
xcodebuild -project Tern.xcodeproj -scheme Tern -configuration Debug -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO build | grep -E "error:|BUILD" || true
APP=build/Build/Products/Debug/Tern.app
codesign --force --deep --options runtime --sign "$IDENTITY" \
  --entitlements Tern/Resources/Tern.entitlements "$APP"
pkill -f "$APP/Contents/MacOS/Tern" 2>/dev/null || true
open "$APP"
