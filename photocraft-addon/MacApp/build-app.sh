#!/bin/zsh
# Builds "NVAI-open for PhotoCraft.app" (release, hardened runtime) and installs it – default: Desktop.
# On German systems the Finder shows "NVAI-open für PhotoCraft" (de.lproj/InfoPlist.strings).
#   ./build-app.sh [--sign <identity>] [target folder]
#   SIGN_IDENTITY=<identity> ./build-app.sh [target folder]
# Without an identity the app is signed ad hoc (development builds). With an identity such as
# "Developer ID Application: Name (TEAMID)" a secure timestamp is added; the app can then be
# notarized. It needs no entitlements: no sandbox, no JIT, no third-party libraries, no Apple Events.
# It only speaks HTTP/TCP and launches PhotoCraft via NSWorkspace.
# Expects PhotoCraftKit next to it (../PhotoCraftKit), as in the repository.
set -euo pipefail
cd "${0:A:h}"

APP="NVAI-open for PhotoCraft"
IDENTITY="${SIGN_IDENTITY:--}"
while (( $# )); do
  case "$1" in
    --sign) IDENTITY="${2:?--sign needs an identity}"; shift 2 ;;
    --sign=*) IDENTITY="${1#--sign=}"; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    -*) print -u2 "Unknown option: $1"; exit 2 ;;
    *) break ;;
  esac
done
DEST="${1:-$HOME/Desktop}"

swift build -c release --product NVAIPhotoCraft
BIN="$(swift build -c release --show-bin-path)/NVAIPhotoCraft"

mkdir -p build
if [[ ! -f build/AppIcon.icns || tools/make-icon.swift -nt build/AppIcon.icns ]]; then
  rm -rf build/AppIcon.iconset
  swift tools/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi

BUNDLE="build/$APP.app"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN" "$BUNDLE/Contents/MacOS/NVAIPhotoCraft"
cp Resources/Info.plist "$BUNDLE/Contents/Info.plist"
cp build/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"
for lproj in Resources/*.lproj; do
  ditto "$lproj" "$BUNDLE/Contents/Resources/${lproj:t}"
  plutil -lint -s "$BUNDLE/Contents/Resources/${lproj:t}/InfoPlist.strings"
done

# Hardened Runtime immer, auch ad hoc: Entwicklungs-Builds verhalten sich so wie die verteilte App.
if [[ "$IDENTITY" == "-" ]]; then
  codesign --force --options runtime --timestamp=none --sign - "$BUNDLE"
else
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$BUNDLE"
fi
codesign --verify --strict --verbose=2 "$BUNDLE"
codesign --display --verbose=2 "$BUNDLE" 2>&1 | grep -E '^(Authority|TeamIdentifier|Timestamp|CodeDirectory)' || true

if pgrep -xq NVAIPhotoCraft; then
  echo "Note: the app is running – please reopen it after it has been replaced."
fi
mkdir -p "$DEST"
rm -rf "$DEST/$APP.app"
ditto "$BUNDLE" "$DEST/$APP.app"
touch "$DEST/$APP.app"  # Finder zeigt sonst noch das alte Symbol
echo "Done: $DEST/$APP.app"
