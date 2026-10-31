#!/bin/zsh
# Builds the tester DMG: NVAI-open.app (+ the optional PhotoCraft add-on app), Getting Started,
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

# 1) NVAI-open.app
cd $ROOT
SIGN=${IDENTITY:--}
# A timestamp needs a real identity; ad hoc has none.
TS_FLAG=""
[[ -n "$IDENTITY" ]] && TS_FLAG="--timestamp"
# CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO: otherwise Xcode adds get-task-allow even in Release,
# and Apple rejects the notarization ("requests the com.apple.security.get-task-allow
# entitlement", measured on 2026-10-20).
xcodebuild -project NVAIMac.xcodeproj -scheme NVAIMac -configuration Release \
  -derivedDataPath $ROOT/dd -clonedSourcePackagesDirPath $ROOT/SourcePackages \
  -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation -skipMacroValidation \
  CODE_SIGN_IDENTITY="$SIGN" CODE_SIGN_STYLE=Manual ENABLE_HARDENED_RUNTIME=YES \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  OTHER_CODE_SIGN_FLAGS="$TS_FLAG" build > $ROOT/release-build.log 2>&1 \
  || { grep -E "error:|errSec" $ROOT/release-build.log | head -20 || true
       echo "Build failed (log: $ROOT/release-build.log)"; exit 1; }
# "|| true": under set -e and pipefail a grep without matches ended the script silently,
# before the message; that is how an errSecInternalComponent went unnoticed on 2026-10-19.
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
  $ROOT/dd/Build/Products/Release/NVAI-open.app/Contents/Info.plist)

rm -rf $OUT && mkdir -p $OUT/dmg
ditto $ROOT/dd/Build/Products/Release/NVAI-open.app "$OUT/dmg/NVAI-open.app"

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
NVAI-open for Mac: Getting Started

1. Drag "NVAI-open" (and the PhotoCraft add-on app, if included) into the Applications folder.
2. Open NVAI-open. Under "Models", download FLUX.2 Klein (about 9 to 11 GB, once).
   With 24 GB of memory or more pick the 8-bit version, otherwise the 4-bit version.
3. Under "Generate", enter a prompt. The first image takes longer because the model loads.
4. Only a few words? Click "✨ Expand prompt": the text encoder of FLUX.2 Klein writes a full
   image description from them. Read it and delete what was invented; "Back to my prompt" restores yours.
5. Old photos: under "Generate", switch to "Restore photo", pick the photo or drag it in, and choose
   "Remove damage" and/or "Colorize". Known colors in the hints make colorizing more accurate.
   "Automatic" (needs Qwen3.5 4B, 3 GB, under "Models" > Add-ons) picks thorough or gentle; "Sharpen and
   enlarge" needs SeedVR2 3B (4.7 GB). On a Mac with 8 GB, sharpening a 1 MP photo to twice its size
   takes about 9 minutes.
6. LoRAs: under "Models" > LoRAs, download a style (pixel art, sprite sheet, anime, ...), tick it under
   "Generate" > LoRAs and put its trigger word into the prompt.
7. Music and sounds: under "Models", download Stable Audio 3 Medium (3.8 GB), then "Generate" >
   "Music and sounds". 30 seconds take about 13 seconds on an M1.
8. Video: under "Models", download the video model recommended for your Mac, then "Generate" > "Video", from
   text or a start image. Below 16 GB that is LTX-Video 2B (about 9 GB, no sound; 2 seconds at 768 x 512 take
   about 95 seconds on an M1 with 8 GB), from 16 GB LTX-Video 13B, from 32 GB LTX-2.3 and from 64 GB LTX-2.5,
   both with sound (macOS 26.3 or later).
9. Studio (the first tab): whole videos from scenes. Compose scenes with a prompt at the top (double-click
   a lane), "Generate scenes" makes the clips, images and music, "Conform" puts them into the edit below,
   where you cut, add transitions and export (YouTube, Shorts, ProRes). Projects open on Windows too.

Language: follows the system; switch under Settings > Language (the menu bar follows after a restart).

PhotoCraft add-on
- Needs PhotoCraft 0.10.0 or later:
  https://github.com/storytold/photocraft/releases/latest
- The add-on starts NVAI-open when needed; both run locally only.

Feedback
- In NVAI-open under Settings > "Report a problem", describe what happened and click
  "Report on GitHub". NVAI-open saves an anonymized report (no names, no prompts, no images)
  and opens a prefilled issue; drag the saved file into it.

Models: FLUX.2 Klein 4B (Black Forest Labs, Apache-2.0), Z-Image Turbo (Alibaba, Apache-2.0), Qwen3.5 4B
(Alibaba, Apache-2.0), SeedVR2 3B (ByteDance, Apache-2.0), Stable Audio 3 Medium (Stability AI Community
License: commercial use below US$1M annual revenue), LTX-Video 2B and 13B (Lightricks, LTX-Video Open Weights
License: free below US$10M annual revenue, mark distributed videos as AI-generated), LTX-2.3 and LTX-2.5 (Lightricks,
LTX-2 Community License: free below US$10M annual revenue). NVAI-open itself: MIT License.
Third-party components: see "Third-Party Notices.txt" or NVAI-open > Licenses.
TXT
cat > "$OUT/dmg/Erste Schritte.txt" <<'TXT'
NVAI-open für Mac: Erste Schritte

1. „NVAI-open“ (und, falls enthalten, „NVAI-open für PhotoCraft“) in den Ordner „Programme“ ziehen.
2. NVAI-open öffnen. Unter „Modelle“ FLUX.2 Klein laden (rund 9 bis 11 GB, einmalig).
   Ab 24 GB Arbeitsspeicher die 8-Bit-Fassung wählen, darunter die 4-Bit-Fassung.
3. Unter „Generieren“ einen Prompt eingeben. Das erste Bild dauert länger, weil das
   Modell geladen wird.
4. Nur ein paar Worte? „✨ Prompt ausbauen“ klicken: Der Text-Encoder von FLUX.2 Klein schreibt
   daraus eine volle Bildbeschreibung. Lesen und Erfundenes streichen; „Zurück zum eigenen Prompt“ holt deinen
   Text zurück.
5. Alte Fotos: unter „Generieren“ auf „Foto restaurieren“ umschalten, das Foto wählen oder hineinziehen und
   „Schäden entfernen“ und/oder „Einfärben“ wählen. Bekannte Farben in den Hinweisen machen das Einfärben genauer.
   „Automatisch“ (braucht Qwen3.5 4B, 3 GB, unter „Modelle“ > Zusätze) wählt gründlich oder schonend;
   „Schärfen und vergrößern“ braucht SeedVR2 3B (4,7 GB). Auf einem Mac mit 8 GB dauert das Doppelte eines
   1-MP-Fotos rund 9 Minuten.
6. LoRAs: unter „Modelle“ > LoRAs einen Stil laden (Pixel-Art, Sprite-Sheet, Anime …), unter „Generieren“ >
   LoRAs anhaken und das Auslösewort in den Prompt schreiben.
7. Musik und Klänge: unter „Modelle“ Stable Audio 3 Medium laden (3,8 GB), dann „Generieren“ >
   „Musik und Klänge“. 30 Sekunden dauern auf einem M1 rund 13 Sekunden.
8. Video: unter „Modelle“ das für den Mac empfohlene Videomodell laden, dann „Generieren“ > „Video“, aus Text
   oder einem Startbild. Unter 16 GB ist das LTX-Video 2B (rund 9 GB, ohne Ton; 2 Sekunden in 768 x 512 dauern
   auf einem M1 mit 8 GB rund 95 Sekunden), ab 16 GB LTX-Video 13B, ab 32 GB LTX-2.3 und ab 64 GB LTX-2.5,
   beide mit Ton (ab macOS 26.3).
9. Studio (der erste Reiter): ganze Videos aus Szenen. Oben Szenen mit Prompt anlegen (Doppelklick auf eine
   Bahn), „Szenen erzeugen“ macht Clips, Bilder und Musik, „Übernehmen“ legt sie in den Schnitt darunter,
   dort schneiden, Übergänge setzen und exportieren (YouTube, Shorts, ProRes). Projekte öffnen sich auch unter Windows.

Sprache: folgt dem System; umstellen unter Einstellungen > Sprache (die Menüleiste folgt nach einem Neustart).

PhotoCraft-Add-on
- Braucht PhotoCraft ab Version 0.10.0:
  https://github.com/storytold/photocraft/releases/latest
- „NVAI-open für PhotoCraft“ startet NVAI-open bei Bedarf selbst; beide laufen nur lokal.

Rückmeldung
- In NVAI-open unter „Einstellungen“ → „Problem melden“ beschreiben, was passiert ist, und
  „Auf GitHub melden“ klicken. NVAI-open speichert einen anonymisierten Bericht (keine Namen,
  keine Prompts, keine Bilder) und öffnet ein vorausgefülltes Issue; die Datei dort hineinziehen.

Modelle: FLUX.2 Klein 4B (Black Forest Labs, Apache-2.0), Z-Image Turbo (Alibaba, Apache-2.0), Qwen3.5 4B
(Alibaba, Apache-2.0), SeedVR2 3B (ByteDance, Apache-2.0), Stable Audio 3 Medium (Stability AI Community
License: kommerziell bis 1 Mio. US-$ Jahresumsatz), LTX-Video 2B und 13B (Lightricks, LTX-Video Open Weights
License: kostenlos unter 10 Mio. US-$ Jahresumsatz, Weitergegebenes als KI-erzeugt kennzeichnen), LTX-2.3 und LTX-2.5
(Lightricks, LTX-2 Community License: kostenlos unter 10 Mio. US-$ Jahresumsatz). NVAI-open selbst: MIT-Lizenz.
Komponenten von Dritten: siehe „Third-Party Notices.txt“ oder NVAI-open > Lizenzen.
TXT
cp "$ROOT/Resources/Third-Party-Notices.txt" "$OUT/dmg/Third-Party Notices.txt"
ln -s /Applications "$OUT/dmg/Applications"
DMG="$OUT/NVAI-open-$VERSION.dmg"
hdiutil create -volname "NVAI-open $VERSION" -srcfolder "$OUT/dmg" -ov -format UDZO "$DMG" >/dev/null
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
