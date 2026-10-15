#!/bin/bash
#
# youtube_delivery.sh — pretvara finalnu snimku (npr. *_final.mov iz
# finalize_session.sh) u datoteku spremnu za upload na YouTube.
#
# Ovo je namjerno odvojen, jeftin prolaz: finalize skripte rješavaju sinkron i
# miks (skupo, satima materijala), a ovdje se rješava samo isporuka — glasnoća,
# AAC i faststart. Video se NIKAD ne renderira (-c:v copy), pa prolaz traje
# minute, ne sate, i može se ponoviti bez rizika za sliku.
#
# Recept za zvuk je isti kao u finalize_backup.sh, provjeren na epizodi
# 2026-07-28: konstantno pojačanje + eksplicitni limiter, NE dynamic loudnorm —
# dynamic stisne LRA (izmjereno 8.0 → 4.2 LU), linearno je ostavi netaknutu.
# Limiter na -2 dBFS, ne -1: AAC enkoder podiže true peak NAKON limitera
# (~0.7 dB izmjereno).
#
set -uo pipefail

INPUT=""
OUTPUT_DIR=""
NAME=""
LOUD_TARGET=-14      # YouTube referenca; katalog u fetch.domovina.tv vozi -16
LOUD_TP=-2           # headroom za AAC enkoder
DRY_RUN=false

usage() {
    cat <<'EOF'
Upotreba:
  ./scripts/youtube_delivery.sh \
    --input <finalna_snimka.mov> \
    [--output-dir <mapa>] [--name <naziv>] \
    [--loudness-target <LUFS>] [--dry-run] [--help]

  --input            Gotova snimka sa slikom i zvukom (npr. *_final.mov).
  --output-dir       Zadano: mapa u kojoj je ulazna datoteka.
  --name             Osnova naziva izlaza. Zadano: naziv ulaza bez nastavka.
  --loudness-target  Cilj u LUFS. Zadano: -14 (YouTube).
  --dry-run          Izmjeri i ispiši sve, ali ne stvaraj ništa.
EOF
    exit "${1:-1}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --input)           INPUT="${2:-}"; shift 2 ;;
        --output-dir)      OUTPUT_DIR="${2:-}"; shift 2 ;;
        --name)            NAME="${2:-}"; shift 2 ;;
        --loudness-target) LOUD_TARGET="${2:-}"; shift 2 ;;
        --dry-run)         DRY_RUN=true; shift ;;
        --help|-h)         usage 0 ;;
        *) echo "❌ Nepoznat argument: $1"; usage ;;
    esac
done

[[ -n "$INPUT" ]] || { echo "❌ --input je obavezan."; usage; }
[[ -f "$INPUT" ]] || { echo "❌ Datoteka ne postoji: $INPUT"; exit 1; }

for tool in ffmpeg ffprobe python3; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "❌ Nedostaje '$tool'.  brew install ffmpeg"; exit 1
    }
done

[[ -n "$OUTPUT_DIR" ]] || OUTPUT_DIR="$(cd "$(dirname "$INPUT")" && pwd)"
[[ -n "$NAME" ]] || { NAME="$(basename "$INPUT")"; NAME="${NAME%.*}"; }
# _final u imenu ulaza nema smisla u imenu izlaza (podcast_final_youtube.mp4).
NAME="${NAME%_final}"
FINAL_OUT="$OUTPUT_DIR/${NAME}_youtube.mp4"
mkdir -p "$OUTPUT_DIR"

# --- 1. ŠTO JE ULAZ ---
VCODEC="$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$INPUT" | head -1)"
ACODEC="$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of csv=p=0 "$INPUT" | head -1)"
DURATION="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$INPUT" | head -1)"

[[ -n "$VCODEC" ]] || { echo "❌ Ulaz nema video zapis."; exit 1; }
[[ -n "$ACODEC" ]] || { echo "❌ Ulaz nema zvučni zapis."; exit 1; }

echo "🎬 Ulaz:  $INPUT"
echo "   video: $VCODEC (kopira se bez renderiranja)   zvuk: $ACODEC → AAC 384k"
echo ""

# --- 2. GLASNOĆA ---
# Mjeri se uvijek; ~20 s po satu materijala. Pojačanje je konstantno, pa jedno
# mjerenje cijele datoteke daje točan broj.
echo "🔉 Mjerim glasnoću…"
LN_JSON="$(ffmpeg -hide_banner -nostats -i "$INPUT" \
    -af loudnorm=I=-14:TP=-1.5:LRA=11:print_format=json -f null - 2>&1 | awk '/^\{/,/^\}/')"

MEASURED_I=""
if [[ -n "$LN_JSON" ]]; then
    MEASURED_I="$(python3 - <<PY
import json
try:
    print(json.loads('''$LN_JSON''')["input_i"])
except Exception:
    pass
PY
)"
fi
[[ -n "$MEASURED_I" ]] || { echo "❌ Mjerenje glasnoće nije uspjelo."; exit 1; }

GAIN_DB="$(python3 -c "print(round($LOUD_TARGET - ($MEASURED_I), 1))")"
LIMIT="$(python3 -c "print(round(10 ** ($LOUD_TP / 20.0), 4))")"
printf "   izmjereno %s LUFS → pojačanje %+s dB na %s LUFS, limiter na %s dBFS\n" \
    "$MEASURED_I" "$GAIN_DB" "$LOUD_TARGET" "$LOUD_TP"
echo ""

AFILTER="volume=${GAIN_DB}dB,alimiter=limit=${LIMIT}:level=disabled"

if [[ "$DRY_RUN" == true ]]; then
    echo "🧪 DRY RUN — ništa nije zapisano."
    echo "   izlaz bi bio: $FINAL_OUT"
    exit 0
fi

# --- 3. PROSTOR NA DISKU ---
NEEDED_KB=$(( $(stat -f%z "$INPUT") / 1024 * 105 / 100 ))
AVAIL_KB="$(df -k "$OUTPUT_DIR" | awk 'NR==2 {print $4}')"
if [[ -n "$AVAIL_KB" ]] && (( AVAIL_KB < NEEDED_KB )); then
    echo "❌ Nema dovoljno prostora: treba ~$((NEEDED_KB/1024/1024)) GB, slobodno $((AVAIL_KB/1024/1024)) GB."
    exit 1
fi

# --- 4. ISPORUKA ---
echo "🎬 Pišem ${FINAL_OUT}…"
ffmpeg -v warning -stats -i "$INPUT" \
    -map 0:v:0 -map 0:a:0 \
    -c:v copy \
    -filter:a:0 "$AFILTER" -c:a aac -b:a 384k -ar 48000 \
    -movflags +faststart \
    -y "$FINAL_OUT" || { echo "❌ Isporuka nije uspjela."; exit 1; }
echo ""

# --- 5. PROVJERA IZLAZA ---
# Broj koji izlazi mora biti broj koji je tražen — mjeri se gotov produkt, ne ulaz.
OUT_VCODEC="$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$FINAL_OUT" | head -1)"
OUT_DURATION="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$FINAL_OUT" | head -1)"
[[ "$OUT_VCODEC" == "$VCODEC" ]] || {
    echo "❌ Video kodek se promijenio ($VCODEC → $OUT_VCODEC) — copy nije prošao."
    exit 1
}
DELTA="$(python3 -c "print(abs($OUT_DURATION - $DURATION))")"
python3 -c "import sys; sys.exit(0 if $DELTA < 0.5 else 1)" || {
    echo "⚠️  Trajanje izlaza odstupa $DELTA s od ulaza — provjeri prije uploada."
}

echo "🔉 Glasnoća izlaza (ono što će čuti gledatelj):"
ffmpeg -hide_banner -nostats -i "$FINAL_OUT" -af ebur128=peak=true -f null - 2>&1 \
    | grep -E "^ +(I|Peak):" | sed 's/^/   /'
echo ""

echo "✅ Za upload: $FINAL_OUT"
ls -lh "$FINAL_OUT"
echo "🏁 Gotovo."
command -v afplay >/dev/null 2>&1 && afplay /System/Library/Sounds/Glass.aiff &
osascript -e 'display notification "YouTube datoteka je spremna." with title "DOMOVINA Studio"' 2>/dev/null
