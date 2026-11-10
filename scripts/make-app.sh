#!/bin/zsh
# Builds "Bambuddy Cert Installer.app" into ./build, signed ad hoc.
set -euo pipefail
cd "${0:A:h}/.."
VERSION="${VERSION:-0.1.0}"
# UNIVERSAL=1 builds for Apple silicon and Intel, as releases do.
arch=()
[[ "${UNIVERSAL:-0}" == 1 ]] && arch=(--arch arm64 --arch x86_64)
swift build -c release --product BambuddyCertInstaller "${arch[@]}"
bin="$(swift build -c release "${arch[@]}" --show-bin-path)"
app="build/Bambuddy Cert Installer.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp LICENSE "$app/Contents/Resources/LICENSE"
cp "$bin/BambuddyCertInstaller" "$app/Contents/MacOS/BambuddyCertInstaller"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.fermium.bambuddy-cert-installer</string>
  <key>CFBundleName</key><string>Bambuddy Cert Installer</string>
  <key>CFBundleExecutable</key><string>BambuddyCertInstaller</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER:-1}</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 Fermium Ltd. MIT licence.</string>
  <key>NSLocalNetworkUsageDescription</key><string>Bambuddy Cert Installer looks for Bambuddy on your network to read its certificate.</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
codesign --force --sign - "$app"
echo "built $app"
