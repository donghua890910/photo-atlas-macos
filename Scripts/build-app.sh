#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bundle="${1:-$PWD/build/Photo Atlas 0.4.7.app}"
[[ "$bundle" = /* ]] || bundle="$PWD/$bundle"
executable="$bundle/Contents/MacOS/PhotoAtlasApp"
if [[ -f "$executable" ]] && /usr/sbin/lsof -t "$executable" >/dev/null 2>&1; then
    printf '%s\n' '目标应用正在运行。请指定另一构建路径。' >&2
    exit 1
fi
swift build -c release --product PhotoAtlasApp
swift build -c release --product PhotoAtlasWorker
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources" "$bundle/Contents/Helpers"
cp tools/people_index.py "$bundle/Contents/Resources/people_index.py"
cp Resources/PhotoAtlas.icns "$bundle/Contents/Resources/PhotoAtlas.icns"
cp .build/release/PhotoAtlasApp "$bundle/Contents/MacOS/PhotoAtlasApp"
cp .build/release/PhotoAtlasWorker "$bundle/Contents/Helpers/PhotoAtlasWorker"
codesign --force --sign - "$bundle/Contents/Helpers/PhotoAtlasWorker"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>PhotoAtlasApp</string>
<key>CFBundleIdentifier</key><string>local.photoatlas.next</string>
<key>CFBundleName</key><string>Photo Atlas</string>
<key>CFBundleDisplayName</key><string>Photo Atlas</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.4.7</string>
<key>CFBundleVersion</key><string>13</string>
<key>CFBundleIconFile</key><string>PhotoAtlas</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppleEventsUsageDescription</key><string>Photo Atlas 需要控制照片应用，以读取及写入您确认的照片元数据。</string>
<key>NSPhotoLibraryUsageDescription</key><string>Photo Atlas 需要读取照片图库，以显示统计并在您选择时整理照片。</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
codesign --force --deep --sign - "$bundle"
printf '%s\n' "$bundle"
