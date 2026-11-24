#!/bin/sh
# Usage: sh Packaging/build-app.sh
# Optional: DAMON_SIGN_IDENTITY="signing identity" sh Packaging/build-app.sh
# Build and sign dist/RateCue.app; version and build come from Packaging/Info.plist.
# The default local identity keeps development permission grants stable across rebuilds.
set -eu

cd "$(dirname "$0")/.."
swift build --configuration release
bin="$(swift build --configuration release --show-bin-path)/RateCue"
app=dist/RateCue.app
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Packaging/Info.plist "$app/Contents/Info.plist"
cp LICENSE NOTICE "$app/Contents/Resources/"
staged="$(mktemp "$app/Contents/MacOS/.RateCue.XXXXXX")"
trap 'rm -f "$staged"' EXIT
cp -p "$bin" "$staged"
mv -f "$staged" "$app/Contents/MacOS/RateCue"
rm -f "$app/Contents/MacOS/Damon"
sign_identity=${DAMON_SIGN_IDENTITY:-RateCue Local Development}
if security find-identity -v -p codesigning 2>/dev/null | grep -F "\"$sign_identity\"" > /dev/null; then
    :
elif [ -n "${DAMON_SIGN_IDENTITY:-}" ]; then
    printf 'Missing signing identity "%s".\\n' "$sign_identity" >&2
    exit 1
else
    printf 'Stable signing identity unavailable; falling back to ad-hoc signing. Create RateCue Local Development to preserve permissions.\\n' >&2
    sign_identity=-
fi
codesign --force --options runtime --entitlements Packaging/Damon.entitlements --sign "$sign_identity" "$app"
codesign --verify --strict "$app"
printf 'Built %s\n' "$app"
