#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
cd "$script_dir"

swift build -c release

bundle="$script_dir/dist/WhatsCrânio.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$script_dir/.build/release/WhatsCranio" "$bundle/Contents/MacOS/WhatsCranio"
cp "$script_dir/Resources/Info.plist" "$bundle/Contents/Info.plist"
if [[ -f "$script_dir/Resources/AppIcon.icns" ]]; then
    cp "$script_dir/Resources/AppIcon.icns" "$bundle/Contents/Resources/AppIcon.icns"
else
    rm -f "$bundle/Contents/Resources/AppIcon.icns"
fi
xattr -cr "$bundle"
codesign \
    --force \
    --deep \
    --sign - \
    --requirements '=designated => identifier "dev.taleslima.whatscranio"' \
    "$bundle"

echo "$bundle"
