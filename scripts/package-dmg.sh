#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
bundle="$project_dir/dist/WhatsCrânio.app"
dmg="$project_dir/dist/WhatsCranio-macOS.dmg"
staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/whatscranio-dmg.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT

"$project_dir/build-app.sh" >/dev/null
ditto "$bundle" "$staging_dir/WhatsCrânio.app"
ln -s /Applications "$staging_dir/Applications"

rm -f "$dmg" "$dmg.sha256"
hdiutil create \
    -volname "WhatsCrânio" \
    -srcfolder "$staging_dir" \
    -ov \
    -format UDZO \
    "$dmg" >/dev/null

(cd "$project_dir/dist" && shasum -a 256 "${dmg:t}") > "$dmg.sha256"
echo "$dmg"
