#!/bin/sh
# Usage: sh Packaging/build-app.sh
# Optional: DAMON_SIGN_IDENTITY="signing identity" sh Packaging/build-app.sh
# Build and sign dist/RateCue.app; version and build come from Packaging/Info.plist.
# Without DAMON_SIGN_IDENTITY, the bundle is ad-hoc signed.
set -eu

cd "$(dirname "$0")/.."
swift build --configuration release
bin="$(swift build --configuration release --show-bin-path)/Damon"
app=dist/RateCue.app
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Packaging/Info.plist "$app/Contents/Info.plist"
cp LICENSE NOTICE "$app/Contents/Resources/"
staged="$(mktemp "$app/Contents/MacOS/.Damon.XXXXXX")"
trap 'rm -f "$staged"' EXIT
cp -p "$bin" "$staged"
mv -f "$staged" "$app/Contents/MacOS/Damon"
codesign --force --options runtime --entitlements Packaging/Damon.entitlements --sign "${DAMON_SIGN_IDENTITY:--}" "$app"
codesign --verify --strict "$app"
printf 'Built %s\n' "$app"
