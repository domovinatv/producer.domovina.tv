#!/bin/bash
#
# test_youtube_delivery.sh — provjerava YouTube isporuku na sintetičkom ulazu.
#
# Načelo iz LESSONS.md: ne "prošlo bez greške" nego egzaktni brojevi na gotovom
# produktu — glasnoća, kodek, poredak boxova, trajanje.
#
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/domovina_ytd_test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

FAILURES=0
check() {
    local name="$1" ok="$2"
    if [[ "$ok" == "0" ]]; then
        echo "  ✅ $name"
    else
        echo "  ❌ $name"
        FAILURES=$((FAILURES + 1))
    fi
}

echo "🧪 Sintetički ulaz: 20 s testsrc2 (h264) + sinus 997 Hz na niskoj razini…"
INPUT="$TMP_DIR/podcast_final.mov"
ffmpeg -v error \
    -f lavfi -i "testsrc2=duration=20:size=640x360:rate=30" \
    -f lavfi -i "sine=frequency=997:duration=20" \
    -filter:a "volume=-18dB" \
    -c:v libx264 -preset ultrafast -pix_fmt yuv420p \
    -c:a pcm_s16le -ar 48000 \
    -y "$INPUT" || { echo "❌ Ne mogu napraviti sintetički ulaz."; exit 1; }

IN_I="$(ffmpeg -hide_banner -nostats -i "$INPUT" -af ebur128 -f null - 2>&1 \
    | awk '/^ +I:/ {print $2}' | tail -1)"
echo "   ulazna glasnoća: $IN_I LUFS"

echo ""
echo "🧪 Pokrećem youtube_delivery.sh…"
"$REPO_ROOT/scripts/youtube_delivery.sh" --input "$INPUT" --output-dir "$TMP_DIR" \
    > "$TMP_DIR/delivery.log" 2>&1
check "skripta izlazi s 0" "$?"

OUT="$TMP_DIR/podcast_youtube.mp4"
[[ -f "$OUT" ]]; check "izlaz je podcast_youtube.mp4 (bez _final u imenu)" "$?"
[[ -f "$OUT" ]] || { echo ""; cat "$TMP_DIR/delivery.log"; exit 1; }

# 1. Video stream je kopiran, ne re-enkodiran.
OUT_VCODEC="$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$OUT")"
[[ "$OUT_VCODEC" == "h264" ]]; check "video kodek nepromijenjen (h264)" "$?"

# 2. Zvuk je AAC 48 kHz.
OUT_ACODEC="$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name,sample_rate -of csv=p=0 "$OUT")"
[[ "$OUT_ACODEC" == "aac,48000" ]]; check "zvuk je AAC na 48 kHz" "$?"

# 3. Glasnoća izlaza je na cilju (-14 LUFS ± 1).
OUT_I="$(ffmpeg -hide_banner -nostats -i "$OUT" -af ebur128 -f null - 2>&1 \
    | awk '/^ +I:/ {print $2}' | tail -1)"
python3 -c "import sys; sys.exit(0 if abs(($OUT_I) - (-14)) <= 1.0 else 1)"
check "izlaz je $OUT_I LUFS (cilj -14 ± 1)" "$?"

# 4. True peak ne prelazi -1 dBFS (limiter na -2 + AAC podizanje).
OUT_TP="$(ffmpeg -hide_banner -nostats -i "$OUT" -af ebur128=peak=true -f null - 2>&1 \
    | awk '/True peak:/{seen=1; next} seen && /Peak:/{print $2; exit}')"
if [[ -n "$OUT_TP" ]]; then
    python3 -c "import sys; sys.exit(0 if $OUT_TP <= -1.0 else 1)"
    check "true peak $OUT_TP dBFS (≤ -1.0)" "$?"
else
    echo "  ⚠️  true peak nije očitan iz ebur128 ispisa — preskačem"
fi

# 5. faststart: moov box dolazi prije mdat (YouTube može streamati tijekom uploada).
python3 - "$OUT" <<'PY'
import struct, sys

order = []
with open(sys.argv[1], "rb") as handle:
    while True:
        header = handle.read(8)
        if len(header) < 8:
            break
        size, kind = struct.unpack(">I4s", header)
        kind = kind.decode("latin1")
        order.append(kind)
        if size == 1:
            size = struct.unpack(">Q", handle.read(8))[0]
            handle.seek(size - 16, 1)
        elif size == 0:
            break
        else:
            handle.seek(size - 8, 1)

moov = order.index("moov") if "moov" in order else -1
mdat = order.index("mdat") if "mdat" in order else -1
sys.exit(0 if 0 <= moov < mdat else 1)
PY
check "moov prije mdat (faststart)" "$?"

# 6. Trajanje unutar 0,5 s od ulaza.
IN_D="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$INPUT")"
OUT_D="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT")"
python3 -c "import sys; sys.exit(0 if abs($OUT_D - $IN_D) < 0.5 else 1)"
check "trajanje ($OUT_D s) unutar 0,5 s od ulaza ($IN_D s)" "$?"

# 7. Dry-run ništa ne stvara.
rm -f "$TMP_DIR/dry_youtube.mp4"
"$REPO_ROOT/scripts/youtube_delivery.sh" --input "$INPUT" --output-dir "$TMP_DIR" \
    --name dry --dry-run > /dev/null 2>&1
RC="$?"
[[ "$RC" == "0" && ! -f "$TMP_DIR/dry_youtube.mp4" ]]; check "dry-run izlazi s 0 i ne piše ništa" "$?"

echo ""
if [[ $FAILURES -eq 0 ]]; then
    echo "✅ youtube_delivery: sve provjere prošle."
    exit 0
else
    echo "🛑 youtube_delivery: $FAILURES provjera palo. Log: $TMP_DIR/delivery.log"
    cat "$TMP_DIR/delivery.log" | tail -30
    exit 1
fi
