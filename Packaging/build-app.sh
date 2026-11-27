#!/bin/sh
# Usage: sh Packaging/build-app.sh
# Optional: DAMON_SIGN_IDENTITY="signing identity" sh Packaging/build-app.sh
# Build and sign dist/RateCue.app; version and build come from Packaging/Info.plist.
# The default local identity keeps development permission grants stable across rebuilds.
set -eu

cd "$(dirname "$0")/.."
swift build --configuration release
bin_dir="$(swift build --configuration release --show-bin-path)"
dist_dir=${RATECUE_BUILD_DIR:-dist}
mkdir -p "$dist_dir"
final_app="$dist_dir/RateCue.app"
stage="$(mktemp -d "$dist_dir/.RateCue-build.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
app="$stage/RateCue.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Packaging/Info.plist "$app/Contents/Info.plist"
cp LICENSE NOTICE "$app/Contents/Resources/"
iconwork="$stage/iconwork"
mkdir "$iconwork"
iconset="$iconwork/RateCue.iconset"
mkdir "$iconset"
for size in 16 32 128 256 512; do
    /usr/bin/sips -z "$size" "$size" Branding/RateCue-Icon-1024.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
done
for size in 16 32 128 256; do
    retina=$((size * 2))
    /usr/bin/sips -z "$retina" "$retina" Branding/RateCue-Icon-1024.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
cp Branding/RateCue-Icon-1024.png "$iconset/icon_512x512@2x.png"
/usr/bin/iconutil -c icns "$iconset" -o "$app/Contents/Resources/RateCue.icns"
cp -p "$bin_dir/RateCue" "$app/Contents/MacOS/RateCue"
cp -p "$bin_dir/RateCueMCP" "$app/Contents/MacOS/RateCueMCP"
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
codesign --force --options runtime --sign "$sign_identity" "$app/Contents/MacOS/RateCueMCP"
codesign --verify --strict "$app/Contents/MacOS/RateCueMCP"
codesign --force --options runtime --entitlements Packaging/Damon.entitlements --sign "$sign_identity" "$app"
codesign --verify --strict "$app"
codesign --verify --strict "$app/Contents/MacOS/RateCueMCP"
rm -rf "$final_app"
mv "$app" "$final_app"
printf 'Built %s\n' "$final_app"
