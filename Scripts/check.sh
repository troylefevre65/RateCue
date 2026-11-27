#!/bin/sh
# Usage: sh Scripts/check.sh
# Validate, test, and rebuild dist/RateCue.app (or RATECUE_BUILD_DIR/RateCue.app).
# Version and build come from Packaging/Info.plist.
set -eu

cd "$(dirname "$0")/.."
if [ "$(uname -s)" != Darwin ]; then
    printf '%s\n' 'RateCue checks require macOS.' >&2
    exit 1
fi

plutil -lint Packaging/Info.plist Packaging/Damon.entitlements
swift test
python3 -m unittest discover -s Tests -p 'test_local_agent.py'
sh Packaging/build-app.sh
bundle="${RATECUE_BUILD_DIR:-dist}/RateCue.app/Contents"
test -x "$bundle/MacOS/RateCueMCP"
"$bundle/MacOS/RateCue" --help > /dev/null
name=$(plutil -extract CFBundleName raw -o - "$bundle/Info.plist")
version=$(plutil -extract CFBundleShortVersionString raw -o - "$bundle/Info.plist")
build=$(plutil -extract CFBundleVersion raw -o - "$bundle/Info.plist")
test "$("$bundle/MacOS/RateCue" --version)" = "$name $version (build $build)"
cmp LICENSE "$bundle/Resources/LICENSE"
cmp NOTICE "$bundle/Resources/NOTICE"
