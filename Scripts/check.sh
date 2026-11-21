#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
if [ "$(uname -s)" != Darwin ]; then
    printf '%s\n' 'Damon checks require macOS.' >&2
    exit 1
fi

plutil -lint Packaging/Info.plist Packaging/Damon.entitlements
swift test
sh Packaging/build-app.sh
bundle=dist/Damon.app/Contents
"$bundle/MacOS/Damon" --help > /dev/null
cmp LICENSE "$bundle/Resources/LICENSE"
cmp NOTICE "$bundle/Resources/NOTICE"
