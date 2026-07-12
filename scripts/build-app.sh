#!/bin/zsh
set -euo pipefail

cd "${0:A:h}/.."
swift build -c release

APP="$PWD/.build/AgentPiP.app"
BIN="$PWD/.build/release/AgentPiP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AgentPiP"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if [[ -d Sources/AgentPiP/ProviderIcons ]]; then cp -R Sources/AgentPiP/ProviderIcons "$APP/Contents/Resources/ProviderIcons"; fi
codesign --force --sign - "$APP"
echo "$APP"
