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

CONFIGURATION="${1:-release}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$REPO_ROOT/PodcastProducer"
APP_NAME="DOMOVINA Studio"
BUILD_DIR="$REPO_ROOT/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

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

# Ad-hoc potpis. Bez potpisa macOS ponekad odbije TCC zahtjev bez ikakve poruke,
# a dopuštenja se resetiraju pri svakom buildu.
echo "🔐 Ad-hoc potpisivanje…"
codesign --force --deep --sign - \
    --identifier "tv.domovina.studio" \
    "$APP_BUNDLE" 2>&1 | sed 's/^/   /' || {
    echo "⚠️  Potpisivanje nije uspjelo — aplikacija će raditi, ali će macOS možda"
    echo "   tražiti dopuštenja pri svakom pokretanju."
}

echo ""
echo "✅ Gotovo: $APP_BUNDLE"
echo ""
echo "Pokretanje:"
echo "  open \"$APP_BUNDLE\""
echo ""
echo "Ako macOS ne pita za mikrofon/kameru, resetiraj dopuštenja:"
echo "  tccutil reset Microphone tv.domovina.studio"
echo "  tccutil reset Camera tv.domovina.studio"
