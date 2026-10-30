#!/bin/sh
# Builds ./diskfull, plus DiskFull.app on macOS (double-clickable, scans the whole disk).
set -e
cd "$(dirname "$0")"

# Version from git: "0.1.1" on a release tag, "0.1.1-3-gabc1234" after it.
version=$(git describe --tags --always --dirty 2>/dev/null || echo dev)
version=${version#v}

odin build src -o:speed -out:diskfull -define:VERSION="$version"

if [ "$(uname)" != "Darwin" ]; then
	echo "Built ./diskfull $version"
	exit 0
fi

# macOS wants plain numbers here.
case "$version" in
[0-9]*) bundle_version=${version%%-*} ;;
*) bundle_version=0.0.0 ;;
esac

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
	<key>CFBundleVersion</key><string>$bundle_version</string>
	<key>CFBundleShortVersionString</key><string>$bundle_version</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>LSMinimumSystemVersion</key><string>12.0</string>
</dict>
</plist>
PLIST
# Ad-hoc signature so macOS remembers the Full Disk Access you grant it.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built ./diskfull and ./$APP $version"
