#!/bin/zsh
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# Builds six Mac apps into dist/: FreeOffice (launcher, "Fo") + Writer Fw, Sheets Fs, Slides Fl, Poster Fp, Data Fd, Diagrams Fg, Planner Fm, Reader Fr, Math Fx
cd "$(dirname "$0")"
set -e
VERSION=${VERSION:-$(cat VERSION 2>/dev/null || echo 1.0.0)}
BUILD=${BUILD:-$(cat BUILD 2>/dev/null || echo 1)}
rm -rf dist build-tmp; mkdir -p dist build-tmp
swiftc -O -o build-tmp/icon tools/icon.swift
swiftc -O -swift-version 5 -parse-as-library -target $(uname -m)-apple-macosx26.0 -o build-tmp/FreeOfficeBin mac/*.swift

# key | bundle/display name | icon letter | FOApp key ('' = launcher showing everything)
APPS=(
  "launcher|FreeOffice|o|"
  "writer|FreeOffice Writer|w|writer"
  "sheets|FreeOffice Sheets|s|sheets"
  "slides|FreeOffice Slides|l|slides"
  "poster|FreeOffice Poster|p|poster"
  "data|FreeOffice Data|d|data"
  "diagrams|FreeOffice Diagrams|g|diagrams"
  "planner|FreeOffice Planner|m|planner"
  "reader|FreeOffice Reader|r|reader"
  "math|FreeOffice Math|x|math"
)
for spec in $APPS; do
  IFS='|' read -r key name letter foapp <<< "$spec"
  APP="dist/$name.app"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build-tmp/$key.iconset
  for s in 16 32 128 256 512; do
    build-tmp/icon build-tmp/$key.iconset/icon_${s}x${s}.png $s $letter
    build-tmp/icon build-tmp/$key.iconset/icon_${s}x${s}@2x.png $((s*2)) $letter
  done
  iconutil -c icns build-tmp/$key.iconset -o "$APP/Contents/Resources/FreeOffice.icns"
  cp build-tmp/$key.iconset/icon_512x512@2x.png "dist/icon-$key.png"
  cp build-tmp/FreeOfficeBin "$APP/Contents/MacOS/FreeOffice"
  urltypes=""; [ -z "$foapp" ] && urltypes='<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>FreeOffice document</string><key>CFBundleURLSchemes</key><array><string>freeoffice</string></array></dict></array>'
  doctypes=""; { [ -z "$foapp" ] || [ "$foapp" = "reader" ]; } && doctypes='<key>CFBundleDocumentTypes</key><array><dict><key>CFBundleTypeName</key><string>PDF Document</string><key>CFBundleTypeRole</key><string>Viewer</string><key>LSHandlerRank</key><string>Alternate</string><key>LSItemContentTypes</key><array><string>com.adobe.pdf</string></array></dict></array>'
  cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>$name</string><key>CFBundleDisplayName</key><string>$name</string>
<key>CFBundleIdentifier</key><string>local.freeoffice.$key</string><key>CFBundleExecutable</key><string>FreeOffice</string>
<key>CFBundleIconFile</key><string>FreeOffice</string>
<key>FOName</key><string>$name</string><key>FOApp</key><string>$foapp</string>
<key>CFBundlePackageType</key><string>APPL</string><key>CFBundleVersion</key><string>$BUILD</string><key>CFBundleShortVersionString</key><string>$VERSION</string>
$urltypes
$doctypes
<key>LSMinimumSystemVersion</key><string>26.0</string><key>NSHighResolutionCapable</key><true/>
</dict></plist>
PL
  codesign --force --deep -s - "$APP" 2>/dev/null
  echo "Built $APP"
done
rm -rf build-tmp
