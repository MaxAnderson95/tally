#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
npm --prefix web ci
npm --prefix web run build
swift build -c release --arch arm64
app="$PWD/build/Tally.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/arm64-apple-macosx/release/Tally "$app/Contents/MacOS/Tally"
cp -R .build/arm64-apple-macosx/release/Tally_TallyApp.bundle "$app/Contents/Resources/"
rm -rf "$app/Contents/Resources/Web"
cp -R web/dist "$app/Contents/Resources/Web"
revision="$(git rev-parse --short HEAD)"
cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>net.maxanderson.tally</string>
<key>CFBundleName</key><string>Tally</string>
<key>CFBundleExecutable</key><string>Tally</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>$revision</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
EOF
codesign --force --sign - "$app"
printf '%s\n' "$app"
