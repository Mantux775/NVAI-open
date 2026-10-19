#!/bin/zsh
# Builds the tester DMG: NV-AI.app (+ the optional PhotoCraft add-on app), Getting Started,
# Erste Schritte and the Third-Party Notices.
#
#   zsh scripts/release.sh                                   # without certificate: ad hoc
#   NOTARY_KEY=~/keys/AuthKey_XXXX.p8 NOTARY_KEY_ID=XXXX NOTARY_ISSUER=<uuid> zsh scripts/release.sh
#   echo "$KEYCHAIN_PASSWORD" | zsh scripts/release.sh --unlock-from-stdin
#   echo "$KEYCHAIN_PASSWORD" | zsh scripts/release.sh --unlock-from-stdin --allow-codesign
#                (once after a new certificate: lets codesign use the key without a dialog)
#
# With a "Developer ID Application" certificate in the keychain the apps are signed (hardened
# runtime, timestamp), notarized and stapled, then the DMG the same way. Without one, an ad-hoc
# signed DMG is built for internal tests only: Gatekeeper blocks it on other Macs.
#
# Environment:
#   NOTARY_KEY, NOTARY_KEY_ID, NOTARY_ISSUER   App Store Connect API key for notarytool
#   NOTARY_FALLBACK_SCRIPT                     optional private script that defines KEY= and ISS=
#   ADDON_DIR                                  folder with the PhotoCraft add-on's build-app.sh
#   ROOT                                       build folder (default ~/NVAIMac)
set -e
setopt pipefail

UNLOCK=0
ALLOW_CODESIGN=0
for arg in "$@"; do
  [[ "$arg" == "--unlock-from-stdin" ]] && UNLOCK=1
  # Once after creating the certificate: codesign may use the private key without asking.
  # Without it, codesign over SSH fails with errSecInternalComponent because macOS wants to
  # ask in a dialog (measured on 2026-10-19).
  [[ "$arg" == "--allow-codesign" ]] && ALLOW_CODESIGN=1
done

ROOT=${ROOT:-$HOME/NVAIMac}
OUT=$ROOT/release
ADDON_DIR=${ADDON_DIR:-}

IDENTITY=$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)
if [[ -n "$IDENTITY" ]]; then
  echo "Signing with: $IDENTITY"
  if (( UNLOCK )); then
    read -r PW || true
    PW=${PW%$'\r'}
    if ! security unlock-keychain -p "$PW" ~/Library/Keychains/login.keychain-db >/dev/null 2>&1; then
      unset PW
      echo "ERROR: could not unlock the keychain. Do not retry blindly; check the password."
      exit 1
    fi
    echo "Keychain unlocked."
    if (( ALLOW_CODESIGN )); then
      security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" \
        ~/Library/Keychains/login.keychain-db >/dev/null 2>&1 \
        && echo "codesign may now use the signing key without asking." \
        || { unset PW; echo "ERROR: granting codesign access failed."; exit 1; }
    fi
    unset PW
  fi
else
  echo "WARNING: no \"Developer ID Application\" certificate. The DMG is only signed ad hoc"
  echo "         and not notarized: for internal tests only, not for testers."
fi

# 1) NV-AI.app
cd $ROOT
SIGN=${IDENTITY:--}
# A timestamp needs a real identity; ad hoc has none.
TS_FLAG=""
[[ -n "$IDENTITY" ]] && TS_FLAG="--timestamp"
xcodebuild -project NVAIMac.xcodeproj -scheme NVAIMac -configuration Release \
  -derivedDataPath $ROOT/dd -clonedSourcePackagesDirPath $ROOT/SourcePackages \
  -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation -skipMacroValidation \
  CODE_SIGN_IDENTITY="$SIGN" CODE_SIGN_STYLE=Manual ENABLE_HARDENED_RUNTIME=YES \
  OTHER_CODE_SIGN_FLAGS="$TS_FLAG" build > $ROOT/release-build.log 2>&1 \
  || { grep -E "error:|errSec" $ROOT/release-build.log | head -20 || true
       echo "Build failed (log: $ROOT/release-build.log)"; exit 1; }
# "|| true": under set -e and pipefail a grep without matches ended the script silently,
# before the message; that is how an errSecInternalComponent went unnoticed on 2026-10-19.
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
  $ROOT/dd/Build/Products/Release/NV-AI.app/Contents/Info.plist)

rm -rf $OUT && mkdir -p $OUT/dmg
ditto $ROOT/dd/Build/Products/Release/NV-AI.app "$OUT/dmg/NV-AI.app"

# 2) Optional: the PhotoCraft add-on app (its own build script, same identity)
if [[ -n "$ADDON_DIR" && -x "$ADDON_DIR/build-app.sh" ]]; then
  ( cd "$ADDON_DIR" && if [[ -n "$IDENTITY" ]]; then ./build-app.sh --sign "$IDENTITY" "$OUT/addon"; else ./build-app.sh "$OUT/addon"; fi ) \
    > $OUT/addon-build.log 2>&1 || { tail -20 $OUT/addon-build.log; echo "Add-on build failed"; exit 1; }
  ADDON_APP=$(ls -d $OUT/addon/*.app | head -1)
  ditto "$ADDON_APP" "$OUT/dmg/$(basename "$ADDON_APP")"
else
  echo "Note: ADDON_DIR not set (or no build-app.sh there): DMG without the PhotoCraft add-on."
fi

# 3) Notarize (only with a certificate). The API key comes from NOTARY_KEY / NOTARY_KEY_ID /
#    NOTARY_ISSUER; a private script with KEY= and ISS= lines works as a fallback. Never printed.
notary_credentials() {
  if [[ -n "$NOTARY_KEY" && -n "$NOTARY_KEY_ID" && -n "$NOTARY_ISSUER" ]]; then
    KEY_PATH=${NOTARY_KEY/#\~/$HOME}; KEY_ID=$NOTARY_KEY_ID; ISSUER=$NOTARY_ISSUER
    return 0
  fi
  local fallback=${NOTARY_FALLBACK_SCRIPT:-$HOME/build/nvai_release.sh}
  if [[ -f "$fallback" ]]; then
    KEY_PATH=$(grep -m1 '^KEY=' "$fallback" | cut -d= -f2- | sed "s|\$HOME|$HOME|")
    ISSUER=$(grep -m1 '^ISS=' "$fallback" | cut -d= -f2-)
    KEY_ID=$(basename "$KEY_PATH" .p8 | sed 's/^AuthKey_//')
    [[ -n "$KEY_PATH" && -n "$ISSUER" ]] && return 0
  fi
  echo "No notarization credentials: set NOTARY_KEY, NOTARY_KEY_ID and NOTARY_ISSUER."
  return 1
}

notarize() {
  local file=$1
  xcrun notarytool submit "$file" --key "$KEY_PATH" --key-id "$KEY_ID" --issuer "$ISSUER" --wait \
    > "$OUT/notary-$(basename "$file").log" 2>&1
  grep -E "status: (Accepted|Invalid|Rejected)" "$OUT/notary-$(basename "$file").log" | tail -1
  grep -q "status: Accepted" "$OUT/notary-$(basename "$file").log"
}

if [[ -n "$IDENTITY" ]]; then
  notary_credentials
  for app in "$OUT"/dmg/*.app; do
    codesign --verify --deep --strict "$app"
    ditto -c -k --keepParent "$app" "$OUT/$(basename "$app" .app).zip"
    echo "Notarizing $(basename "$app") …"
    notarize "$OUT/$(basename "$app" .app).zip"
    xcrun stapler staple "$app" >/dev/null
  done
fi

# 4) Texts: Getting Started (English), Erste Schritte (German), Third-Party Notices
cat > "$OUT/dmg/Getting Started.txt" <<'TXT'
NV-AI for Mac: Getting Started

1. Drag "NV-AI" (and the PhotoCraft add-on app, if included) into the Applications folder.
2. Open NV-AI. Under "Models", download FLUX.2 Klein (about 9 to 11 GB, once).
   With 24 GB of memory or more pick the 8-bit version, otherwise the 4-bit version.
3. Under "Generate", enter a prompt. The first image takes longer because the model loads.

Language: English by default; switch to German under Settings > Language.

PhotoCraft add-on
- Needs PhotoCraft 0.10.0 or later:
  https://github.com/storytold/photocraft/releases/latest
- The add-on starts NV-AI when needed; both run locally only.

Feedback
- In NV-AI under Settings, save the test report and send it along, together with
  ~/Library/Logs/NV-AI/nvai.log. The report lists the Mac, memory, duration and memory use
  per image; it contains no prompts and no images.

Models: FLUX.2 Klein 4B (Black Forest Labs, Apache-2.0). NV-AI itself: MIT License.
Third-party components: see "Third-Party Notices.txt" or NV-AI > Licenses.
TXT
cat > "$OUT/dmg/Erste Schritte.txt" <<'TXT'
NV-AI für Mac: Erste Schritte

1. „NV-AI“ (und, falls enthalten, „NV-AI für PhotoCraft“) in den Ordner „Programme“ ziehen.
2. NV-AI öffnen. Unter „Modelle“ FLUX.2 Klein laden (rund 9 bis 11 GB, einmalig).
   Ab 24 GB Arbeitsspeicher die 8-Bit-Fassung wählen, darunter die 4-Bit-Fassung.
3. Unter „Generieren“ einen Prompt eingeben. Das erste Bild dauert länger, weil das
   Modell geladen wird.

Sprache: Standard ist Englisch; auf Deutsch umstellen unter Einstellungen > Sprache.

PhotoCraft-Add-on
- Braucht PhotoCraft ab Version 0.10.0:
  https://github.com/storytold/photocraft/releases/latest
- „NV-AI für PhotoCraft“ startet NV-AI bei Bedarf selbst; beide laufen nur lokal.

Rückmeldung
- In NV-AI unter „Einstellungen“ den Messbericht speichern und mitschicken, dazu
  ~/Library/Logs/NV-AI/nvai.log. Der Bericht enthält Mac, Arbeitsspeicher, Dauer und
  Speicherbedarf je Bild, keine Prompts und keine Bilder.

Modelle: FLUX.2 Klein 4B (Black Forest Labs, Apache-2.0). NV-AI selbst: MIT-Lizenz.
Komponenten von Dritten: siehe „Third-Party Notices.txt“ oder NV-AI > Lizenzen.
TXT
cp "$ROOT/Resources/Third-Party-Notices.txt" "$OUT/dmg/Third-Party Notices.txt"
ln -s /Applications "$OUT/dmg/Applications"
DMG="$OUT/NV-AI-$VERSION.dmg"
hdiutil create -volname "NV-AI $VERSION" -srcfolder "$OUT/dmg" -ov -format UDZO "$DMG" >/dev/null
if [[ -n "$IDENTITY" ]]; then
  codesign --sign "$IDENTITY" --timestamp "$DMG"
  echo "Notarizing DMG …"
  notarize "$DMG"
  xcrun stapler staple "$DMG" >/dev/null
  spctl -a -t open --context context:primary-signature -v "$DMG" 2>&1 | tail -1
fi
echo "Done: $DMG ($(du -h "$DMG" | cut -f1))"
[[ -z "$IDENTITY" ]] && echo "Note: signed ad hoc, not notarized: do not give to testers."
exit 0
