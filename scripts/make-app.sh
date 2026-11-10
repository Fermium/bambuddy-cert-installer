#!/bin/zsh
# Builds "Bambuddy Cert Installer.app" into ./build, signed ad hoc.
set -euo pipefail
cd "${0:A:h}/.."
VERSION="${VERSION:-0.1.0}"
swift build -c release --product BambuddyCertInstaller
app="build/Bambuddy Cert Installer.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp LICENSE "$app/Contents/Resources/LICENSE"
cp .build/release/BambuddyCertInstaller "$app/Contents/MacOS/BambuddyCertInstaller"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.fermium.bambuddy-cert-installer</string>
  <key>CFBundleName</key><string>Bambuddy Cert Installer</string>
  <key>CFBundleExecutable</key><string>BambuddyCertInstaller</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 Fermium Ltd. MIT licence.</string>
  <key>NSLocalNetworkUsageDescription</key><string>Bambuddy Cert Installer looks for Bambuddy on your network to read its certificate.</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
codesign --force --sign - "$app"
echo "built $app"
