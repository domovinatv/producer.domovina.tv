#!/bin/bash
#
# test_hardware.sh — jedini test u ovom repozitoriju koji dira stvarni hardver.
#
# Otvara oba PodMic USB uređaja i Elgato capture, snima pravu sesiju, pa je
# provjeri dvaput: iznutra (manifest, brojači koje je aplikacija sama vodila) i
# izvana (ffprobe nad datotekama, neovisno o AVFoundationu koji ih je napisao).
#
# Test sam proizvede zvuk kroz zvučnike Maca, jer se sinkronizacija ne može
# izmjeriti u tihoj sobi. Glasnoća se privremeno podigne i vrati na kraju.
#
# NE pokretati tijekom snimanja — uređaji su ekskluzivni.
#
set -euo pipefail

OUTPUT_DIR="/Volumes/DOMOVINA2TB/podcast_producer_output"
SECONDS_TO_RECORD=75
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output) OUTPUT_DIR="$2"; shift 2 ;;
        --seconds) SECONDS_TO_RECORD="$2"; shift 2 ;;
        --no-tone) EXTRA_ARGS+=("--no-tone"); shift ;;
        -h|--help)
            echo "Uporaba: $0 [--output DIR] [--seconds N] [--no-tone]"
            exit 0 ;;
        *) echo "❌ Nepoznat argument: $1"; exit 2 ;;
    esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCES="$REPO_ROOT/PodcastProducer/Sources"
BUILD_DIR="$(mktemp -d)"

command -v swiftc >/dev/null 2>&1 || { echo "❌ swiftc nije pronađen."; exit 1; }
command -v ffprobe >/dev/null 2>&1 || { echo "❌ ffprobe nije pronađen (brew install ffmpeg)"; exit 1; }

# Glasnoća se vraća i ako test padne ili ga netko prekine.
ORIGINAL_VOLUME="$(osascript -e 'output volume of (get volume settings)' 2>/dev/null || echo "")"
restore() {
    [[ -n "$ORIGINAL_VOLUME" ]] && osascript -e "set volume output volume $ORIGINAL_VOLUME" 2>/dev/null || true
    rm -rf "$BUILD_DIR"
}
trap restore EXIT

echo "🔨 Gradim testni program…"
swiftc -O -target arm64-apple-macosx14.0 -o "$BUILD_DIR/hardware" \
    "$SOURCES/Core/HostClock.swift" \
    "$SOURCES/Core/LevelMeter.swift" \
    "$SOURCES/Capture/AudioDeviceEnumerator.swift" \
    "$SOURCES/Capture/AudioTrackRecorder.swift" \
    "$SOURCES/Capture/VideoCaptureController.swift" \
    "$SOURCES/Capture/LipSyncMonitor.swift" \
    "$SOURCES/Capture/ClapCalibrator.swift" \
    "$SOURCES/Session/SessionManifest.swift" \
    "$SOURCES/Session/SessionStore.swift" \
    "$SOURCES/Session/HealthMonitor.swift" \
    "$SOURCES/Upload/R2Credentials.swift" \
    "$SOURCES/Upload/SigV4.swift" \
    "$SOURCES/Upload/R2Client.swift" \
    "$SOURCES/Upload/UploadQueue.swift" \
    "$SOURCES/Studio/StudioViewModel.swift" \
    "$REPO_ROOT/tests/hardware/main.swift"

if [[ -n "$ORIGINAL_VOLUME" ]]; then
    echo "🔊 Podižem glasnoću na 80 (bila $ORIGINAL_VOLUME) za testni signal…"
    osascript -e 'set volume output volume 80' 2>/dev/null || true
fi

set +e
# Bash 3.2 (macOS) tretira praznu ekspanziju polja kao nepostavljenu varijablu
# pod `set -u`, pa expanzija mora imati zadanu vrijednost.
"$BUILD_DIR/hardware" --output "$OUTPUT_DIR" --seconds "$SECONDS_TO_RECORD" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
SWIFT_STATUS=$?
set -e

# ── Neovisna provjera datoteka ───────────────────────────────────────────────
#
# Manifest tvrdi što je aplikacija mislila da je zapisala. ffprobe čita ono što
# je doista na disku — jedina provjera koja bi uhvatila pokvarene zaglavlja.

SESSION="$(find "$OUTPUT_DIR" -maxdepth 1 -type d -name '20*' -print0 2>/dev/null \
    | xargs -0 -I{} stat -f '%m %N' {} 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"

if [[ -z "$SESSION" ]]; then
    echo "❌ Nije pronađena nijedna mapa sesije u $OUTPUT_DIR"
    exit 1
fi

echo ""
echo "── ffprobe nad datotekama ────────────────────────────────────────────"
echo "   \$SESSION = $SESSION"
PROBE_STATUS=0

probe() {
    local file="$1" label="$2"
    if [[ ! -f "$file" ]]; then
        echo "  ❌ $label — datoteka ne postoji"
        PROBE_STATUS=1
        return
    fi
    local duration
    duration="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$file" 2>/dev/null || echo "")"
    if [[ -z "$duration" || "$duration" == "N/A" ]]; then
        echo "  ❌ $label — ffprobe ne može pročitati trajanje (oštećeno zaglavlje?)"
        PROBE_STATUS=1
        return
    fi
    local streams
    streams="$(ffprobe -v error -show_entries stream=codec_type,codec_name,sample_rate,channels,bits_per_raw_sample,width,height,r_frame_rate \
        -of csv=p=0 "$file" 2>/dev/null | tr '\n' ' ')"
    printf "  ✅ %-28s %6.1f s  %s\n" "$label" "$duration" "$streams"
}

for wav in "$SESSION"/audio/*.wav; do
    [[ -e "$wav" ]] || continue
    probe "$wav" "$(basename "$wav")"
done
probe "$SESSION/video/camera-proxy.mov" "camera-proxy.mov"

# Zvuk mora doista biti u datoteci, a ne samo ispravno zaglavlje nad tišinom.
for wav in "$SESSION"/audio/*.wav; do
    [[ -e "$wav" ]] || continue
    # volumedetect javlja na razini `info`, pa `-v error` proguta rezultat.
    # Razina je pretposljednje polje: "... max_volume: -12.3 dB".
    peak="$(ffmpeg -v info -i "$wav" -af volumedetect -f null - 2>&1 | awk '/max_volume/ {print $(NF-1)}')"
    if [[ -n "$peak" ]] && awk "BEGIN{exit !($peak > -50)}"; then
        printf "  ✅ %-28s max %s dB\n" "$(basename "$wav") ima signal" "$peak"
    else
        printf "  ❌ %-28s max %s dB — tišina\n" "$(basename "$wav") ima signal" "${peak:-?}"
        PROBE_STATUS=1
    fi
done

# exFAT nema proširene atribute, pa macOS uz svaku datoteku ostavlja `._`
# sidecar. Broje se kao datoteke i udvostručili bi ispis.
SEGMENT_COUNT="$(find "$SESSION/segments" -type f ! -name '._*' 2>/dev/null | wc -l | tr -d ' ')"
echo "  ℹ️  segmenata na disku: $SEGMENT_COUNT"
echo "  ℹ️  ukupno: $(du -sh "$SESSION" 2>/dev/null | cut -f1)"

echo ""
if [[ $SWIFT_STATUS -eq 0 && $PROBE_STATUS -eq 0 ]]; then
    echo "✅ Hardverski test prošao."
    exit 0
fi
echo "❌ Hardverski test pao (program: $SWIFT_STATUS, ffprobe: $PROBE_STATUS)."
exit 1
