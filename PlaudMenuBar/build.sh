#!/bin/zsh
# Build Plaud Menu Bar into a signed .app bundle.
# CoreBluetooth needs a bundle with NSBluetoothAlwaysUsageDescription and a
# code signature, or macOS kills the process on first Bluetooth use (TCC).
set -e
cd "$(dirname "$0")"

CONFIG=${1:-release}
echo "Building ($CONFIG)..."
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/PlaudMenuBar"

APP="PlaudMenuBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PlaudMenuBar"
cp Info.plist "$APP/Contents/Info.plist"

# Ad-hoc sign with the Bluetooth entitlement so TCC lets it use the radio.
codesign --force --sign - --entitlements PlaudMenuBar.entitlements --options runtime "$APP" 2>/dev/null \
  || codesign --force --sign - --entitlements PlaudMenuBar.entitlements "$APP"

echo "Built $PWD/$APP"
echo "Run it with:  open \"$PWD/$APP\"   (look for the waveform icon in the menu bar)"
