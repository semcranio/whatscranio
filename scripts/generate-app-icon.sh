#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
source_svg="$project_dir/Resources/AppIcon.svg"
output_icns="${1:-$project_dir/Resources/AppIcon.icns}"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/whatscranio-icon.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

mkdir -p "${output_icns:h}"
qlmanage -t -s 1024 -o "$work_dir" "$source_svg" >/dev/null 2>&1
base_png="$work_dir/AppIcon.svg.png"
iconset="$work_dir/AppIcon.iconset"
mkdir -p "$iconset"

typeset -A sizes=(
    icon_16x16.png 16
    icon_16x16@2x.png 32
    icon_32x32.png 32
    icon_32x32@2x.png 64
    icon_128x128.png 128
    icon_128x128@2x.png 256
    icon_256x256.png 256
    icon_256x256@2x.png 512
    icon_512x512.png 512
    icon_512x512@2x.png 1024
)

for name size in ${(kv)sizes}; do
    sips -z "$size" "$size" "$base_png" --out "$iconset/$name" >/dev/null
done

iconutil -c icns "$iconset" -o "$output_icns"
echo "$output_icns"
