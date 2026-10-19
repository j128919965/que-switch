#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
cd "$project_dir"
mkdir -p .build/module-cache
swift build --product NativeSwitch -c release --disable-sandbox \
  --cache-path .build/cache --config-path .build/config --security-path .build/security \
  -Xswiftc -module-cache-path -Xswiftc .build/module-cache
app_dir="$project_dir/dist/NativeSwitch.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp .build/release/NativeSwitch "$app_dir/Contents/MacOS/NativeSwitch"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
swift -module-cache-path .build/module-cache scripts/MakeIcon.swift .build/AppIcon.iconset
iconutil -c icns .build/AppIcon.iconset -o "$app_dir/Contents/Resources/AppIcon.icns"
codesign --force --sign - --identifier com.que.NativeSwitch "$app_dir"
codesign --verify --strict "$app_dir"
echo "Built: $app_dir"
