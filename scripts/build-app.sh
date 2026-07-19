#!/bin/zsh
set -euo pipefail

cd "${0:A:h}/.."
swift build -c release

APP="$PWD/.build/AgentPiP.app"
BIN="$PWD/.build/release/AgentPiP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mkdir -p "$APP/Contents/Helpers"
cp "$BIN" "$APP/Contents/MacOS/AgentPiP"
cp "$PWD/.build/release/AgentPiPHook" "$APP/Contents/Helpers/AgentPiPHook"
chmod 755 "$APP/Contents/Helpers/AgentPiPHook"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if [[ -d Sources/AgentPiP/ProviderIcons ]]; then cp -R Sources/AgentPiP/ProviderIcons "$APP/Contents/Resources/ProviderIcons"; fi

# Keep the app's designated requirement stable across rebuilds so Keychain
# continues to recognize it as the same application. Ad-hoc signatures default
# to a changing cdhash requirement and trigger a new access prompt every build.
SIGN_IDENTITY="${AGENTPIP_CODE_SIGN_IDENTITY:-$(
  security find-identity -v -p codesigning 2>/dev/null \
    | awk '/Apple Development:|Developer ID Application:/{print $2; exit}'
)}"
if [[ -n "$SIGN_IDENTITY" ]]; then
  codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP"
else
  codesign --force --sign - \
    --requirements '=designated => identifier "local.agentpip.app"' "$APP"
fi
echo "$APP"
