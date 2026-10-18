#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
cd "$script_dir"

swift build -c release --arch arm64 --arch x86_64
release_bin_dir="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

bundle="$script_dir/dist/WhatsCrânio.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$release_bin_dir/WhatsCranio" "$bundle/Contents/MacOS/WhatsCranio"
cp "$script_dir/Resources/Info.plist" "$bundle/Contents/Info.plist"
icon="$script_dir/Resources/AppIcon.icns"
if [[ ! -f "$icon" ]]; then
    "$script_dir/scripts/generate-app-icon.sh" "$script_dir/.build/AppIcon.icns" >/dev/null
    icon="$script_dir/.build/AppIcon.icns"
fi
cp "$icon" "$bundle/Contents/Resources/AppIcon.icns"
xattr -cr "$bundle"
codesign \
    --force \
    --deep \
    --sign - \
    --requirements '=designated => identifier "dev.taleslima.whatscranio"' \
    "$bundle"

echo "$bundle"
