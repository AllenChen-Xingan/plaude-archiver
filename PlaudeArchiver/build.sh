#!/bin/zsh
# Build Plaude Archiver into a signed .app bundle.
# CoreBluetooth needs a bundle with NSBluetoothAlwaysUsageDescription and a
# code signature, or macOS kills the process on first Bluetooth use (TCC).
set -e
cd "$(dirname "$0")"

CONFIG=${1:-release}
echo "Building ($CONFIG)..."
swift build --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk -c "$CONFIG"
BIN="$(swift build --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk -c "$CONFIG" --show-bin-path)/PlaudeArchiver"

APP="Plaude Archiver CN.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PlaudeArchiver"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if [[ -f ../../../outputs/plaud-app/job.py ]]; then
  (cd ../../.. && pwd -P) > "$APP/Contents/Resources/RuntimeRoot.txt"
fi

# Ad-hoc sign with the Bluetooth entitlement so TCC lets it use the radio.
codesign --force --sign - --entitlements PlaudeArchiver.entitlements --options runtime "$APP" 2>/dev/null \
  || codesign --force --sign - --entitlements PlaudeArchiver.entitlements "$APP"

echo "Built $PWD/$APP"
echo "Run it with:  open \"$PWD/$APP\"   (look for the waveform icon in the menu bar)"
