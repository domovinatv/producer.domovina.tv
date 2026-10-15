#!/bin/bash
#
# build_app.sh — pakira Swift izvršnu datoteku u pravi .app bundle.
#
# Zašto je ovo potrebno: macOS TCC (Privatnost i sigurnost) dodjeljuje dopuštenja
# za mikrofon i kameru po aplikaciji, na temelju bundle identifiera i
# NS*UsageDescription ključeva u Info.plist. `swift run` nema bundle, pa se
# dopuštenja pripisuju Terminalu — radi za razvoj, ali je nepredvidivo.
# Za stvarno snimanje koristi ovaj bundle.
#
set -euo pipefail

CONFIGURATION="release"
INSTALL=false
for arg in "$@"; do
    case "$arg" in
        debug|release) CONFIGURATION="$arg" ;;
        --install)     INSTALL=true ;;
        --help|-h)     echo "Upotreba: $0 [debug|release] [--install]"; exit 0 ;;
        *)             echo "❌ Nepoznat argument: $arg"; exit 1 ;;
    esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$REPO_ROOT/PodcastProducer"
APP_NAME="DOMOVINA Studio"
BUILD_DIR="$REPO_ROOT/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
INSTALL_DIR="/Applications"
INSTALLED_BUNDLE="$INSTALL_DIR/$APP_NAME.app"
BUNDLE_ID="tv.domovina.studio"
ENTITLEMENTS="$PACKAGE_DIR/Resources/PodcastProducer.entitlements"
# Developer ID (ITalk) za SVAKI build, i lokalni: TCC pamti dozvolu za mikrofon
# i kameru po identifikatoru + timu, pa potpisan build zadržava dozvole iz
# builda u build. Ad-hoc potpis je hash binarnog, pa bi svaki build ponovno pitao.
# Bez certifikata u keychainu pada na ad-hoc (radi, ali Sparkle ga ne ažurira).
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: ITalk d.o.o. (6SCK58757K)}"
# Sparkle uspoređuje CFBundleVersion, pa mora rasti s repozitorijem: broj commitova.
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$REPO_ROOT" rev-list --count HEAD)}"

command -v swift >/dev/null 2>&1 || { echo "❌ Swift toolchain nije pronađen."; exit 1; }

echo "🔨 Build ($CONFIGURATION)…"
cd "$PACKAGE_DIR"
swift build -c "$CONFIGURATION"
BIN_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path)"
BINARY="$BIN_PATH/PodcastProducer"
[[ -f "$BINARY" ]] || { echo "❌ Izvršna datoteka nije pronađena: $BINARY"; exit 1; }

echo "📦 Pakiram ${APP_BUNDLE}…"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/PodcastProducer"
cp "$PACKAGE_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP_BUNDLE/Contents/Info.plist"
cp "$PACKAGE_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

# Post skripte idu u bundle: instalirana aplikacija ima cwd "/", pa ScriptLocator
# bez ove kopije ne bi našao ništa kad repozitorija nema. Repo kopija i dalje ima
# prednost — tijekom razvoja je novija od bundlane.
mkdir -p "$APP_BUNDLE/Contents/Resources/scripts"
cp "$REPO_ROOT/scripts/"*.sh "$REPO_ROOT/scripts/"*.py "$APP_BUNDLE/Contents/Resources/scripts/"
chmod +x "$APP_BUNDLE/Contents/Resources/scripts/"*.sh "$APP_BUNDLE/Contents/Resources/scripts/"*.py

# Sparkle.framework: Xcode bi ga sam ugradio, swift build ga samo stavi pored
# binarnog. ditto čuva simlinkove unutar frameworka (Versions/Current), cp -R ne
# uvijek. Binarni ga traži preko @rpath, a SwiftPM daje samo @loader_path
# (Contents/MacOS), pa dodajemo i Contents/Frameworks.
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
ditto "$BIN_PATH/Sparkle.framework" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BUNDLE/Contents/MacOS/PodcastProducer"

# Potpis iznutra prema van, bez --deep (Apple ga ne preporučuje: svemu da iste
# entitlemente). Redoslijed za Sparkle je iz njegove dokumentacije za Developer ID.
# Hardened runtime (-o runtime) i --timestamp traži notarizacija.
SPARKLE="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
if security find-identity -v -p codesigning | grep -qF "$SIGN_IDENTITY"; then
    echo "🔐 Potpisujem: $SIGN_IDENTITY"
    sign() { codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$@"; }
    sign "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
    sign --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
    sign "$SPARKLE/Versions/B/Autoupdate"
    sign "$SPARKLE/Versions/B/Updater.app"
    sign "$SPARKLE"
    sign --identifier "$BUNDLE_ID" --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"
    codesign --verify --strict --deep "$APP_BUNDLE"
else
    echo "⚠️  Nema certifikata \"$SIGN_IDENTITY\" — ad-hoc potpis."
    echo "   Aplikacija radi, ali macOS će nakon svakog builda opet pitati za"
    echo "   mikrofon/kameru, a Sparkle je neće moći ažurirati."
    codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP_BUNDLE"
fi

# --- Instalacija u /Applications ---------------------------------------------
# Bez ovoga se kopija u /Applications tiho razilazi od repozitorija: rebuild ide
# u build/, a ti otvaraš onu drugu i gledaš staru verziju.
if [[ "$INSTALL" == true ]]; then
    if pgrep -x "PodcastProducer" >/dev/null 2>&1; then
        echo "❌ $APP_NAME je pokrenut. Zatvori ga prije instalacije —"
        echo "   zamjena bundlea ispod žive aplikacije prekida snimanje u tijeku."
        exit 1
    fi

    # Prije brisanja provjeri da je na odredištu doista naša aplikacija, a ne
    # nešto tuđe što slučajno nosi isto ime.
    if [[ -e "$INSTALLED_BUNDLE" ]]; then
        EXISTING_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" \
            "$INSTALLED_BUNDLE/Contents/Info.plist" 2>/dev/null || echo "")"
        [[ "$EXISTING_ID" == "$BUNDLE_ID" ]] || {
            echo "❌ $INSTALLED_BUNDLE postoji, ali nije $BUNDLE_ID (nego '${EXISTING_ID:-nepoznato}')."
            echo "   Ne diram ga — makni ga ručno pa ponovi."
            exit 1
        }
        rm -rf "$INSTALLED_BUNDLE"
    fi

    # ${} obavezno: znak … odmah do imena varijable inače postane dio imena.
    echo "📥 Instaliram u ${INSTALL_DIR}…"
    cp -R "$APP_BUNDLE" "$INSTALLED_BUNDLE"

    # macOS pamti ikonu po putanji bundlea. Bez ovoga nova putanja pokazuje
    # generičku ikonu iako je .icns na mjestu.
    LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
    [[ -x "$LSREGISTER" ]] && "$LSREGISTER" -f "$INSTALLED_BUNDLE"
fi

echo ""
echo "✅ Gotovo: $APP_BUNDLE (build $BUILD_NUMBER)"
if [[ "$INSTALL" == true ]]; then
    echo "✅ Instalirano: $INSTALLED_BUNDLE"
fi
echo ""
echo "Pokretanje:"
if [[ "$INSTALL" == true ]]; then
    echo "  open -a \"$APP_NAME\""
else
    echo "  open \"$APP_BUNDLE\""
    echo "  (ili ./scripts/build_app.sh --install pa iz Launchpada / Spotlighta)"
fi
echo ""
echo "Ako macOS ne pita za mikrofon/kameru, resetiraj dopuštenja:"
echo "  tccutil reset Microphone tv.domovina.studio"
echo "  tccutil reset Camera tv.domovina.studio"
