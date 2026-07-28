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

command -v swift >/dev/null 2>&1 || { echo "❌ Swift toolchain nije pronađen."; exit 1; }

echo "🔨 Build ($CONFIGURATION)…"
cd "$PACKAGE_DIR"
swift build -c "$CONFIGURATION"
BINARY="$(swift build -c "$CONFIGURATION" --show-bin-path)/PodcastProducer"
[[ -f "$BINARY" ]] || { echo "❌ Izvršna datoteka nije pronađena: $BINARY"; exit 1; }

echo "📦 Pakiram ${APP_BUNDLE}…"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/PodcastProducer"
cp "$PACKAGE_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$PACKAGE_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

# Post skripte idu u bundle: instalirana aplikacija ima cwd "/", pa ScriptLocator
# bez ove kopije ne bi našao ništa kad repozitorija nema. Repo kopija i dalje ima
# prednost — tijekom razvoja je novija od bundlane.
mkdir -p "$APP_BUNDLE/Contents/Resources/scripts"
cp "$REPO_ROOT/scripts/"*.sh "$REPO_ROOT/scripts/"*.py "$APP_BUNDLE/Contents/Resources/scripts/"
chmod +x "$APP_BUNDLE/Contents/Resources/scripts/"*.sh "$APP_BUNDLE/Contents/Resources/scripts/"*.py

# Ad-hoc potpis. Bez potpisa macOS ponekad odbije TCC zahtjev bez ikakve poruke,
# a dopuštenja se resetiraju pri svakom buildu.
echo "🔐 Ad-hoc potpisivanje…"
codesign --force --deep --sign - \
    --identifier "$BUNDLE_ID" \
    "$APP_BUNDLE" 2>&1 | sed 's/^/   /' || {
    echo "⚠️  Potpisivanje nije uspjelo — aplikacija će raditi, ali će macOS možda"
    echo "   tražiti dopuštenja pri svakom pokretanju."
}

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
echo "✅ Gotovo: $APP_BUNDLE"
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
