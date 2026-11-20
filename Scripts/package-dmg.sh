#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

bundle="${1:-$PWD/build/Photo Atlas 0.4.7.app}"
output="${2:-$PWD/build/Photo Atlas 0.4.7.dmg}"
[[ "$bundle" = /* ]] || bundle="$PWD/$bundle"
[[ "$output" = /* ]] || output="$PWD/$output"
if [[ -e "$output" || -L "$output" ]]; then
    printf '%s\n' '目标安装包已存在。请指定另一输出路径。' >&2
    exit 1
fi

/usr/bin/codesign --verify --deep --strict "$bundle"
mkdir -p "$(dirname "$output")"
work="$(mktemp -d "$(dirname "$output")/.photoatlas-dmg.XXXXXX")"
mounted=0
cleanup() {
    if [[ "$mounted" == 1 ]]; then
        /usr/bin/hdiutil detach "$work/mount" >/dev/null || return
    fi
    rm -rf "$work"
}
trap cleanup EXIT

mkdir "$work/staging" "$work/mount"
/usr/bin/ditto "$bundle" "$work/staging/Photo Atlas.app"
cp 'docs/候选版安装说明.txt' "$work/staging/安装说明.txt"
ln -s /Applications "$work/staging/Applications"
/usr/bin/hdiutil create -quiet -volname "Photo Atlas Candidate" -srcfolder "$work/staging" -format UDZO "$work/package.dmg"
/usr/bin/hdiutil verify -quiet "$work/package.dmg"
/usr/bin/hdiutil attach -quiet -readonly -nobrowse -mountpoint "$work/mount" "$work/package.dmg"
mounted=1
/usr/bin/codesign --verify --deep --strict "$work/mount/Photo Atlas.app"
cmp "$bundle/Contents/MacOS/PhotoAtlasApp" "$work/mount/Photo Atlas.app/Contents/MacOS/PhotoAtlasApp"
cmp 'docs/候选版安装说明.txt' "$work/mount/安装说明.txt"
/usr/bin/hdiutil detach -quiet "$work/mount"
mounted=0
# A hard link publishes the verified image without replacing an existing file.
ln "$work/package.dmg" "$output"
printf '%s\n' "$output"
