#!/usr/bin/env bash
# release.sh — DOMOVINA Studio za druge Macove: Developer ID potpis ->
# notarizacija -> staple -> zip + dmg, i po želji objava za Sparkle.
#
# Po uzoru na adria-brainstormer/mac/scripts/release.sh. Razlika: Studio nije
# Xcode projekt, pa bundle slaže i potpisuje build_app.sh (Sparkle.framework,
# hardened runtime, entitlementi), a ovdje ide samo notarizacija i objava.
#
#   ./scripts/release.sh                 # build + notarizacija + zip + dmg
#   ./scripts/release.sh --publish       # ... + appcast + upload u R2 (svi dobiju update)
#   ./scripts/release.sh --no-notarize   # samo build + zip (lokalna provjera)
#
# Sparkle: instalacije čitaju appcast.xml s javnog R2 bucketa
# domovina-studio-releases (račun D.O.M.) i same ponude novu verziju.
# generate_appcast potpiše zip privatnim EdDSA ključem iz keychaina (račun
# "domovina-studio", kopija na vanjskom disku); upload ide wranglerom iz multicam/relay (isti račun).
# Prvu instalaciju na novom Macu radi se ručno iz DMG-a, sve sljedeće dolaze same.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

NOTARIZE=1
PUBLISH=0
for arg in "$@"; do
    case "$arg" in
        --no-notarize) NOTARIZE=0 ;;
        --publish)     PUBLISH=1 ;;
        *) echo "Nepoznat argument: $arg" >&2; exit 2 ;;
    esac
done

APP_NAME="DOMOVINA Studio"
APP="$REPO_ROOT/build/$APP_NAME.app"
FILES="${FILES:-/Volumes/DOMOVINA2TB/domovina_studio_build_files}"
# Zipovi u vlastitoj mapi: generate_appcast čita CIJELU mapu i radi stavku za
# svaki arhiv u njoj, pa DMG pored zipa iste verzije znači dvostruku stavku.
MACDIST="$FILES/dist/mac"
DMGDIST="$FILES/dist/mac-dmg"
TOOLS="$REPO_ROOT/PodcastProducer/.build/artifacts/sparkle/Sparkle/bin"
# Privatni EdDSA ključ: original je u keychainu (račun "domovina-studio"), ali
# generate_appcast je drugi binarni od generate_keys i keychain bi ga pitao
# dijalogom koji nitko ne vidi. Kopija na vanjskom disku čita se bez pitanja.
KEY_FILE="$FILES/credentials/sparkle-eddsa-private.key"
RELEASES_BUCKET="domovina-studio-releases"
RELEASES_URL="https://pub-3688cad79e324f92a17a1e66f96bd923.r2.dev"
WRANGLER_DIR="$REPO_ROOT/multicam/relay"
export CLOUDFLARE_ACCOUNT_ID="7dc7167b7e2e00923bfa7cd697df14e4"   # D.O.M.

# ASC ključ ITalk tima (6SCK58757K), isti kao u brainstormeru, za notarytool.
ASC_KEY_ID="${ASC_KEY_ID:-25KYCN22QD}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-69a6de85-f7cc-47e3-e053-5b8c7c11a4d1}"
ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}"

[[ -d "$(dirname "$FILES")" ]] || { echo "❌ Vanjski disk nije montiran: $(dirname "$FILES")" >&2; exit 1; }
mkdir -p "$MACDIST" "$DMGDIST"

if [[ "$PUBLISH" == 1 ]]; then
    [[ "$NOTARIZE" == 1 ]] || { echo "❌ --publish traži notarizaciju: Sparkle instalira samo ono što Gatekeeper prihvaća." >&2; exit 1; }
    # Broj builda je broj commitova, pa objavljeni build mora biti točno taj commit.
    git diff --quiet HEAD -- PodcastProducer scripts || {
        echo "❌ Necommitane promjene u PodcastProducer/ ili scripts/ — commitaj prije objave." >&2; exit 1; }
fi

echo "==> build"
"$REPO_ROOT/scripts/build_app.sh" release 2>&1 | grep -E "^(🔨|📦|🔐|⚠️|✅|❌)"

BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
ZIP="$MACDIST/domovina-studio-$VERSION-$BUILD_NUMBER.zip"
DMG="$DMGDIST/domovina-studio-$VERSION-$BUILD_NUMBER.dmg"

echo "==> potpis (verzija $VERSION, build $BUILD_NUMBER)"
# Ispis u varijablu: `codesign | grep -q` uz pipefail pada kad grep zatvori cijev rano.
SIGNATURE="$(codesign -dvv "$APP" 2>&1)"
grep -E "Authority=Developer ID|TeamIdentifier" <<<"$SIGNATURE" || {
    echo "❌ Aplikacija NIJE potpisana Developer ID certifikatom." >&2; exit 1; }
grep -q "(runtime)" <<<"$SIGNATURE" || {
    echo "❌ Nema hardened runtimea — notarizacija bi pala." >&2; exit 1; }

if [[ "$NOTARIZE" == 1 ]]; then
    echo "==> notarizacija (može trajati nekoliko minuta)"
    TMPZIP="$FILES/notarize-$BUILD_NUMBER.zip"
    ditto -c -k --keepParent "$APP" "$TMPZIP"
    xcrun notarytool submit "$TMPZIP" \
        --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait
    rm -f "$TMPZIP"
    echo "==> staple"
    xcrun stapler staple "$APP"
    spctl -a -vv -t exec "$APP" 2>&1 | grep -E "accepted|rejected|source="
fi

# ditto čuva potpis i resource fork; plain zip ih zna pokvariti.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "==> $ZIP"

# DMG: aplikacija + prečac na /Applications, instalira se povlačenjem.
# Potpisuje se istim Developer ID Application certifikatom kao i aplikacija.
STAGE="$FILES/dmg-$BUILD_NUMBER"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGE"
codesign --sign "Developer ID Application: ITalk d.o.o. (6SCK58757K)" --timestamp "$DMG"
if [[ "$NOTARIZE" == 1 ]]; then
    echo "==> notarizacija DMG-a"
    xcrun notarytool submit "$DMG" \
        --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait
    xcrun stapler staple "$DMG"
fi
echo "==> $DMG"

if [[ "$PUBLISH" == 1 ]]; then
    echo "==> appcast (Sparkle)"
    # Bez delta: cijeli zip je par MB, a delte bi tražile čuvanje svih starih verzija.
    "$TOOLS/generate_appcast" \
        --ed-key-file "$KEY_FILE" \
        --download-url-prefix "$RELEASES_URL/" \
        --maximum-deltas 0 \
        -o "$MACDIST/appcast.xml" \
        "$MACDIST"
    grep -c "<item>" "$MACDIST/appcast.xml" | sed 's/^/   stavki u appcastu: /'

    echo "==> upload u R2 ($RELEASES_BUCKET)"
    put() { (cd "$WRANGLER_DIR" && npx wrangler r2 object put "$RELEASES_BUCKET/$1" --file "$2" --remote \
        --content-type "$3" --cache-control "$4" 2>&1 | grep -E "Upload complete|rror" ); }
    put "$(basename "$ZIP")" "$ZIP" "application/zip" "public, max-age=31536000, immutable"
    put "$(basename "$DMG")" "$DMG" "application/x-apple-diskimage" "public, max-age=31536000, immutable"
    # Manifest se ne smije zalijepiti u cache: to je jedina datoteka koja se mijenja.
    put "appcast.xml" "$MACDIST/appcast.xml" "application/xml" "no-cache, max-age=0"
    # Stalni link za prvu instalaciju na novom Macu.
    put "DOMOVINA-Studio.dmg" "$DMG" "application/x-apple-diskimage" "no-cache, max-age=0"
    echo "==> $RELEASES_URL/appcast.xml"
    echo "==> prva instalacija: $RELEASES_URL/DOMOVINA-Studio.dmg"
fi
