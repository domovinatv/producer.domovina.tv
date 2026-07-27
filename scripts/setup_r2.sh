#!/bin/bash
#
# setup_r2.sh — spoji Domovina Studio na Cloudflare R2.
#
# Zapiše konfiguraciju u istu domenu postavki koju čita aplikacija, spremi secret
# u Keychain, i onda pravim krugom (PUT/GET/DELETE) provjeri da sve doista radi
# prije nego se osloniš na to usred snimanja.
#
# Bucket se stvara zasebno, jednom:
#   CLOUDFLARE_ACCOUNT_ID=<account> wrangler r2 bucket create <bucket> --location eeur
#
# Pristupni ključevi NISU wranglerov posao — R2 S3 kredencijali se rade u
# dashboardu: R2 → API → Manage API Tokens → Create API Token, Object Read & Write,
# ograničeno na ovaj bucket. Dobiješ Access Key ID i Secret Access Key.
#
set -euo pipefail

APP_DOMAIN="tv.domovina.studio"
KEYCHAIN_SERVICE="tv.domovina.studio.r2"

ACCOUNT_ID="7dc7167b7e2e00923bfa7cd697df14e4"      # D.O.M.
BUCKET="domovina-studio-sessions"
PREFIX="sessions"
LIBRARY="/Volumes/DOMOVINA2TB/podcast_producer_output"
UPLOAD_DURING_RECORDING=true
UPLOAD_MASTERS_AFTER_STOP=false
VERIFY_ONLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --account) ACCOUNT_ID="$2"; shift 2 ;;
        --bucket) BUCKET="$2"; shift 2 ;;
        --prefix) PREFIX="$2"; shift 2 ;;
        --library) LIBRARY="$2"; shift 2 ;;
        --upload-masters) UPLOAD_MASTERS_AFTER_STOP=true; shift ;;
        --verify-only) VERIFY_ONLY=true; shift ;;
        -h|--help)
            sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
            echo "Zastavice: --account --bucket --prefix --library --upload-masters --verify-only"
            exit 0 ;;
        *) echo "❌ Nepoznat argument: $1"; exit 2 ;;
    esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCES="$REPO_ROOT/PodcastProducer/Sources"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

command -v swiftc >/dev/null 2>&1 || { echo "❌ swiftc nije pronađen."; exit 1; }

if pgrep -x "PodcastProducer" >/dev/null 2>&1; then
    echo "❌ Domovina Studio je pokrenut. Zatvori ga — inače će prebrisati postavke"
    echo "   koje ovaj skript upiše (cfprefsd ih drži u memoriji dok app radi)."
    exit 1
fi

if [[ "$VERIFY_ONLY" == false ]]; then
    # ── Lokalna strana: gdje master snimke ostaju ────────────────────────────
    if [[ ! -d "$LIBRARY" ]]; then
        echo "⚠️  $LIBRARY ne postoji — stvaram."
        mkdir -p "$LIBRARY"
    fi
    defaults write "$APP_DOMAIN" "studio.library" -string "$LIBRARY"
    echo "📁 Lokalna biblioteka: $LIBRARY"

    # ── Kredencijali ────────────────────────────────────────────────────────
    echo ""
    echo "R2 API token (dashboard → R2 → API → Manage API Tokens, Object Read & Write):"
    read -r -p "  Access Key ID: " ACCESS_KEY_ID
    [[ -n "$ACCESS_KEY_ID" ]] || { echo "❌ Access Key ID je obavezan."; exit 1; }
    # -s: ne ispisuj u terminal i ne ostavljaj u povijesti ljuske.
    read -r -s -p "  Secret Access Key: " SECRET_ACCESS_KEY
    echo ""
    [[ -n "$SECRET_ACCESS_KEY" ]] || { echo "❌ Secret Access Key je obavezan."; exit 1; }

    # -U prebriše postojeći unos. -A dopušta čitanje bez upita za dopuštenje:
    # aplikacija konstruira R2Client u trenutku pokretanja snimanja, a dijalog
    # Keychaina koji tada iskoči i čeka klik je gori problem od same postavke.
    security add-generic-password \
        -U -A \
        -s "$KEYCHAIN_SERVICE" \
        -a "$ACCESS_KEY_ID" \
        -w "$SECRET_ACCESS_KEY" \
        -l "Domovina Studio — R2" \
        2>/dev/null
    unset SECRET_ACCESS_KEY
    echo "🔐 Secret spremljen u Keychain (servis $KEYCHAIN_SERVICE)"

    # ── Konfiguracija ───────────────────────────────────────────────────────
    # R2Configuration je Codable struct spremljen kao JSON Data, pa `defaults`
    # traži heksadecimalni zapis.
    CONFIG_HEX="$(ACCOUNT_ID="$ACCOUNT_ID" BUCKET="$BUCKET" PREFIX="$PREFIX" \
        ACCESS_KEY_ID="$ACCESS_KEY_ID" DURING="$UPLOAD_DURING_RECORDING" \
        MASTERS="$UPLOAD_MASTERS_AFTER_STOP" python3 - <<'PY'
import json, os
config = {
    "accountID": os.environ["ACCOUNT_ID"],
    "bucket": os.environ["BUCKET"],
    "accessKeyID": os.environ["ACCESS_KEY_ID"],
    "prefix": os.environ["PREFIX"],
    "isEnabled": True,
    "uploadDuringRecording": os.environ["DURING"] == "true",
    "uploadMastersAfterStop": os.environ["MASTERS"] == "true",
}
print(json.dumps(config, separators=(",", ":")).encode().hex())
PY
)"
    defaults write "$APP_DOMAIN" "r2.configuration" -data "$CONFIG_HEX"
    echo "⚙️  Konfiguracija upisana u $APP_DOMAIN"
fi

# ── Provjera pravim krugom ──────────────────────────────────────────────────
echo ""
echo "🔨 Gradim provjeru…"
swiftc -O -target arm64-apple-macosx14.0 -o "$BUILD_DIR/r2live" \
    "$SOURCES/Upload/R2Credentials.swift" \
    "$SOURCES/Upload/SigV4.swift" \
    "$SOURCES/Upload/R2Client.swift" \
    "$REPO_ROOT/tests/r2_live/main.swift"

"$BUILD_DIR/r2live"
