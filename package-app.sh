#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# Keep the signing identity stable so rebuilt apps retain Keychain access.
identity="${STRATA_SIGNING_IDENTITY:-E99809CA692566E9CF5C0E57218CF71868ECD33F}"
swift build -c release
bundle=".build/Strata.app"
mkdir -p "$bundle/Contents/MacOS"
cp Resources/Info.plist "$bundle/Contents/Info.plist"
cp .build/release/Strata "$bundle/Contents/MacOS/Strata"
codesign --force --sign "$identity" "$bundle"
codesign --verify --deep --strict "$bundle"
printf 'Packaged and verified: %s/%s\n' "$PWD" "$bundle"