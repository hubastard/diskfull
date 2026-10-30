#!/bin/sh
# Builds ./diskfull, plus DiskFull.app on macOS (double-clickable, scans the whole disk).
set -e
cd "$(dirname "$0")"

odin build src -o:speed -out:diskfull

if [ "$(uname)" != "Darwin" ]; then
	echo "Built ./diskfull"
	exit 0
fi

APP=DiskFull.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp diskfull "$APP/Contents/MacOS/diskfull"
cp LICENSE README.md "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>DiskFull</string>
	<key>CFBundleExecutable</key><string>diskfull</string>
	<key>CFBundleIdentifier</key><string>local.diskfull</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleVersion</key><string>1.0</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>LSMinimumSystemVersion</key><string>12.0</string>
</dict>
</plist>
PLIST
# Ad-hoc signature so macOS remembers the Full Disk Access you grant it.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built ./diskfull and ./$APP"
