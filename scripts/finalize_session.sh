#!/bin/bash
#
# finalize_session.sh — dovršava sesiju snimljenu u Domovina Studio aplikaciji.
#
# Razlika prema podcast_sync.sh: ovdje se pomaci NE traže korelacijom. Aplikacija
# je svaki trag označila vremenom na zajedničkom host clocku, pa su relativni
# pomaci između mikrofona i snimljenog video proxyja poznati na razini uzorka.
# Korelacija se koristi samo za jednu stvar koju sat ne može znati: gdje počinje
# snimka sa SD kartice kamere, koja ima svoj neovisni sat.
#
# Koraci:
#   1. Pročita manifest.json
#   2. Ispravi drift svakog mikrofona (measuredSampleRate iz manifesta)
#   3. Poravna svaki mikrofon na vremensku os video proxyja
#   4. Napravi miks svih mikrofona
#   5. Ako je dan --lumix: poravna SD master prema proxyju i muxa ga s miksom
#      koristeći stream copy (bez renderiranja videa)
#
set -uo pipefail

# --- 1. ARGUMENTI ---
SESSION_DIR=""
LUMIX_VIDS=()
OUTPUT_DIR=""
DRY_RUN=false
KEEP_ISOLATED=true

usage() {
    cat <<'EOF'
Upotreba:
  ./scripts/finalize_session.sh \
    --session <mapa_sesije> \
    [--lumix <SD_snimka.MOV> ...] \
    [--output-dir <mapa>] \
    [--dry-run] [--help]

  --session      Mapa sesije koju je snimio Studio (sadrži manifest.json).
  --lumix        Snimka(e) sa SD kartice GH5. Bez ovoga se obrađuje samo audio.
  --output-dir   Zadano: <mapa_sesije>/final
  --dry-run      Izračuna i ispiše sve pomake, ali ne stvara datoteke.
EOF
    exit "${1:-1}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --session)     SESSION_DIR="${2:-}"; shift 2 ;;
        --lumix)       LUMIX_VIDS+=("${2:-}"); shift 2 ;;
        --output-dir)  OUTPUT_DIR="${2:-}"; shift 2 ;;
        --dry-run)     DRY_RUN=true; shift ;;
        --no-isolated) KEEP_ISOLATED=false; shift ;;
        --help|-h)     usage 0 ;;
        *) echo "❌ Nepoznat argument: $1"; usage ;;
    esac
done

[[ -n "$SESSION_DIR" ]] || { echo "❌ --session je obavezan."; usage; }
MANIFEST="$SESSION_DIR/manifest.json"
[[ -f "$MANIFEST" ]] || { echo "❌ Nema manifesta: $MANIFEST"; exit 1; }
OUTPUT_DIR="${OUTPUT_DIR:-$SESSION_DIR/final}"

# --- 2. ALATI ---
NEEDED=(ffmpeg ffprobe python3)
if [[ ${#LUMIX_VIDS[@]} -gt 0 ]]; then
    NEEDED+=(audio-offset-finder)
fi
for tool in "${NEEDED[@]}"; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "❌ Nedostaje '$tool'."
        case "$tool" in
            ffmpeg|ffprobe) echo "   brew install ffmpeg" ;;
            audio-offset-finder) echo "   pip install audio-offset-finder" ;;
        esac
        exit 1
    }
done

mkdir -p "$OUTPUT_DIR"
ALIGNED_DIR="$OUTPUT_DIR/aligned"
mkdir -p "$ALIGNED_DIR"
LOG_FILE="$OUTPUT_DIR/finalize_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee "$LOG_FILE") 2>&1

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/domovina_finalize.XXXXXX")"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

echo "🎬 Sesija: $SESSION_DIR"
echo "📝 Log:    $LOG_FILE"
echo ""

# --- 3. ČITANJE MANIFESTA ---
# Python ispisuje TSV redove jer je to jedini format koji bash čita bez ovisnosti.
# Pomaci su relativni prema prvom frameu video proxyja; ako videa nema, prema
# početku sesije.
read_manifest() {
    python3 - "$MANIFEST" <<'PY'
import json, sys

with open(sys.argv[1]) as handle:
    manifest = json.load(handle)

session_start = manifest.get("startedAtHostNanos")
tracks = manifest.get("tracks", [])

proxy = next((t for t in tracks if t.get("kind") == "cameraProxyVideo"), None)
# The reference zero point: the first captured video frame if we have one.
anchor = None
if proxy and proxy.get("firstSampleHostNanos"):
    anchor = proxy["firstSampleHostNanos"]
elif session_start:
    anchor = session_start

# Never emit an empty field: tab is an IFS whitespace character in bash, so
# consecutive tabs collapse into one and every later column shifts left.
def field(value):
    text = "" if value is None else str(value)
    return text if text.strip() else "-"

# durationSeconds is derived in the app rather than stored, so recompute it.
started = manifest.get("startedAtHostNanos")
stopped = manifest.get("stoppedAtHostNanos")
duration = (stopped - started) / 1e9 if started and stopped and stopped > started else None

print("SESSION\t%s\t%s\t%s" % (
    field(manifest.get("sessionID")),
    field("%.3f" % duration if duration is not None else None),
    "yes" if proxy else "no",
))

if proxy:
    print("PROXY\t%s\t%s\t%s\t%s" % (
        field(proxy.get("relativePath")),
        field(proxy.get("width") or 0),
        field(proxy.get("height") or 0),
        field(proxy.get("nominalFrameRate") or 0),
    ))

for track in tracks:
    if track.get("kind") != "microphone":
        continue
    first = track.get("firstSampleHostNanos")
    if first is None or anchor is None:
        offset = 0.0
    else:
        offset = (first - anchor) / 1e9

    nominal = track.get("sampleRate") or 48000.0
    measured = track.get("measuredSampleRate") or nominal
    # Guard against a nonsense measurement (very short takes, device hiccup):
    # anything beyond 500 ppm is far outside real crystal tolerance.
    if not (0.9995 < measured / nominal < 1.0005):
        measured = nominal

    print("MIC\t%s\t%s\t%.9f\t%.4f\t%.4f\t%s" % (
        field(track.get("id")),
        field(track.get("relativePath")),
        offset,
        nominal,
        measured,
        field(track.get("label", "").replace("\t", " ")),
    ))

for event in manifest.get("events", []):
    if not event.get("isMarker"):
        continue
    if anchor is None or not event.get("hostNanos"):
        continue
    at = (event["hostNanos"] - anchor) / 1e9
    if at < 0:
        at = 0.0
    print("MARKER\t%.3f\t%s" % (at, field(event.get("message", "").replace("\t", " "))))
PY
}

MANIFEST_DATA="$(read_manifest)" || { echo "❌ Manifest se ne može pročitati."; exit 1; }

HAS_PROXY="no"
PROXY_REL=""
SESSION_ID=""
SESSION_DURATION=""
MIC_IDS=(); MIC_PATHS=(); MIC_OFFSETS=(); MIC_NOMINAL=(); MIC_MEASURED=(); MIC_LABELS=()
MARKER_TIMES=(); MARKER_TEXTS=()

while IFS=$'\t' read -r kind f2 f3 f4 f5 f6 f7; do
    case "$kind" in
        SESSION) SESSION_ID="$f2"; SESSION_DURATION="$f3"; HAS_PROXY="$f4" ;;
        PROXY)   PROXY_REL="$f2"; PROXY_W="$f3"; PROXY_H="$f4"; PROXY_FPS="$f5" ;;
        MIC)     MIC_IDS+=("$f2"); MIC_PATHS+=("$f3"); MIC_OFFSETS+=("$f4")
                 MIC_NOMINAL+=("$f5"); MIC_MEASURED+=("$f6"); MIC_LABELS+=("$f7") ;;
        MARKER)  MARKER_TIMES+=("$f2"); MARKER_TEXTS+=("$f3") ;;
    esac
done <<< "$MANIFEST_DATA"

[[ ${#MIC_IDS[@]} -gt 0 ]] || { echo "❌ Manifest ne sadrži nijedan mikrofonski trag."; exit 1; }

[[ "$SESSION_DURATION" == "-" ]] && SESSION_DURATION="nepoznato"
echo "🆔 Sesija:    ${SESSION_ID:-nepoznata}"
echo "⏱️  Trajanje:  $SESSION_DURATION s"
echo "🎥 Proxy:     $HAS_PROXY${PROXY_REL:+ ($PROXY_REL)}"
echo "🎙️  Mikrofoni: ${#MIC_IDS[@]}"
echo ""

# --- 4. PROVJERA DA AUDIO DATOTEKE POSTOJE ---
for index in "${!MIC_PATHS[@]}"; do
    path="$SESSION_DIR/${MIC_PATHS[$index]}"
    [[ -f "$path" ]] || { echo "❌ Nema audio datoteke: $path"; exit 1; }
done

# --- 5. ISPIS IZRAČUNATIH POMAKA ---
echo "📐 Pomaci prema vremenskoj osi proxyja (iz host clocka, bez korelacije):"
for index in "${!MIC_IDS[@]}"; do
    printf "   %-10s %-22s offset %+9.4f s   drift %+7.1f ppm\n" \
        "${MIC_IDS[$index]}" "${MIC_LABELS[$index]}" "${MIC_OFFSETS[$index]}" \
        "$(python3 -c "print((${MIC_MEASURED[$index]}/${MIC_NOMINAL[$index]}-1)*1e6)")"
done
echo ""

# --- 6. POMAK SD SNIMKE (jedina stvar koju treba korelirati) ---
SD_OFFSET="0"
PROXY_ABS=""
if [[ ${#LUMIX_VIDS[@]} -gt 0 ]]; then
    for file in "${LUMIX_VIDS[@]}"; do
        [[ -f "$file" ]] || { echo "❌ Nema datoteke: $file"; exit 1; }
    done

    [[ -n "$PROXY_REL" ]] || { echo "❌ Sesija nema video proxy — SD snimku nije moguće poravnati."; exit 1; }
    PROXY_ABS="$SESSION_DIR/$PROXY_REL"
    [[ -f "$PROXY_ABS" ]] || { echo "❌ Nema proxy datoteke: $PROXY_ABS"; exit 1; }

    echo "🎵 Izvlačim referentni zvuk iz proxyja i iz SD snimke…"
    ffmpeg -v error -i "$PROXY_ABS" -vn -ac 1 -ar 16000 -acodec pcm_s16le -y "$TMP_DIR/proxy_ref.wav"
    ffmpeg -v error -i "${LUMIX_VIDS[0]}" -vn -ac 1 -ar 16000 -acodec pcm_s16le -y "$TMP_DIR/sd_ref.wav"

    echo "🔎 Tražim gdje proxy počinje unutar SD snimke…"
    AOF_OUT="$(audio-offset-finder --find-offset-of "$TMP_DIR/proxy_ref.wav" --within "$TMP_DIR/sd_ref.wav" 2>&1)" || true
    SD_OFFSET="$(awk '/Offset:/ {print $2; exit}' <<< "$AOF_OUT")"
    AOF_SCORE="$(awk '/Standard score:/ {print $3; exit}' <<< "$AOF_OUT")"

    if [[ -z "$SD_OFFSET" ]]; then
        echo "❌ Korelacija nije uspjela. Izlaz alata:"
        echo "$AOF_OUT"
        exit 1
    fi
    echo "✅ SD offset: $SD_OFFSET s${AOF_SCORE:+ (standard score: $AOF_SCORE)}"
    # A low score means the two recordings may not be the same moment at all.
    if [[ -n "$AOF_SCORE" ]] && python3 -c "import sys; sys.exit(0 if float('$AOF_SCORE') < 10 else 1)"; then
        echo "⚠️  Standard score je nizak — provjeri rezultat prije objave!"
    fi
    echo ""
fi

if [[ "$DRY_RUN" == true ]]; then
    echo "🧪 DRY RUN — ništa nije zapisano."
    echo "   SD offset: $SD_OFFSET s"
    exit 0
fi

# --- 7. PROSTOR NA DISKU ---
AVAIL_KB="$(df -k "$OUTPUT_DIR" | awk 'NR==2 {print $4}')"
if [[ -n "$AVAIL_KB" ]] && (( AVAIL_KB < 10485760 )); then
    echo "⚠️  Manje od 10 GB slobodno na izlaznom disku."
fi

# --- 8. DRIFT + POMAK PO MIKROFONU ---
# asetrate reinterpretira datoteku na stvarno izmjerenoj frekvenciji (time se
# uklanja drift kristala), aresample je vraća na 48 kHz. adelay/atrim potom
# postavlja trag na vremensku os proxyja.
echo "🛠️  Ispravljam drift i poravnavam mikrofone…"
ALIGNED_FILES=()
for index in "${!MIC_IDS[@]}"; do
    mic_id="${MIC_IDS[$index]}"
    src="$SESSION_DIR/${MIC_PATHS[$index]}"
    dst="$ALIGNED_DIR/${mic_id}_aligned.wav"
    offset="${MIC_OFFSETS[$index]}"
    nominal="${MIC_NOMINAL[$index]}"
    measured="${MIC_MEASURED[$index]}"

    filter="asetrate=${measured},aresample=${nominal}"

    # Positive offset: the mic started after the video, so pad the front.
    # Negative offset: the mic started first, so trim the head.
    if python3 -c "import sys; sys.exit(0 if $offset >= 0.0005 else 1)"; then
        delay_ms="$(python3 -c "print(int(round($offset*1000)))")"
        filter="${filter},adelay=${delay_ms}:all=1"
        echo "   $mic_id: +${delay_ms} ms tišine na početak"
    elif python3 -c "import sys; sys.exit(0 if $offset <= -0.0005 else 1)"; then
        trim_s="$(python3 -c "print(abs($offset))")"
        filter="atrim=start=${trim_s},asetpts=PTS-STARTPTS,${filter}"
        echo "   $mic_id: režem ${trim_s} s s početka"
    else
        echo "   $mic_id: već poravnan"
    fi

    ffmpeg -v error -i "$src" -af "$filter" -c:a pcm_s24le -y "$dst" || {
        echo "❌ Poravnavanje '$mic_id' nije uspjelo."; exit 1
    }
    ALIGNED_FILES+=("$dst")
done
echo "✅ Poravnani tragovi u: $ALIGNED_DIR"
echo ""

# --- 9. MIKS ---
MIX_WAV="$OUTPUT_DIR/mix.wav"
echo "🎚️  Pravim miks (${#ALIGNED_FILES[@]} tragova)…"
MIX_ARGS=()
for file in "${ALIGNED_FILES[@]}"; do
    MIX_ARGS+=(-i "$file")
done

if [[ ${#ALIGNED_FILES[@]} -eq 1 ]]; then
    ffmpeg -v error "${MIX_ARGS[@]}" -ac 2 -c:a pcm_s24le -y "$MIX_WAV"
else
    # normalize=0 čuva razine pojedinih mikrofona; inače amix stišava svaki
    # trag proporcionalno broju ulaza.
    ffmpeg -v error "${MIX_ARGS[@]}" \
        -filter_complex "amix=inputs=${#ALIGNED_FILES[@]}:duration=longest:normalize=0,alimiter=limit=0.97" \
        -ac 2 -c:a pcm_s24le -y "$MIX_WAV"
fi
echo "✅ Miks: $MIX_WAV"
echo ""

# --- 10. OZNAKE ---
if [[ ${#MARKER_TIMES[@]} -gt 0 ]]; then
    MARKERS_FILE="$OUTPUT_DIR/markers.txt"
    : > "$MARKERS_FILE"
    for index in "${!MARKER_TIMES[@]}"; do
        printf "%s\t%s\n" \
            "$(python3 -c "t=${MARKER_TIMES[$index]}; print('%02d:%02d:%06.3f' % (t//3600,(t%3600)//60,t%60))")" \
            "${MARKER_TEXTS[$index]}" >> "$MARKERS_FILE"
    done
    echo "🔖 Oznake (${#MARKER_TIMES[@]}): $MARKERS_FILE"
    echo ""
fi

# --- 11. MUX SA SD SNIMKOM (bez renderiranja) ---
if [[ ${#LUMIX_VIDS[@]} -eq 0 ]]; then
    echo "ℹ️  Bez --lumix — obrađen je samo audio."
    echo "🏁 Gotovo."
    exit 0
fi

FINAL_OUT="$OUTPUT_DIR/${SESSION_ID:-podcast}_final.mov"
echo "🎬 Muxam SD snimku s miksom (stream copy, bez renderiranja)…"

if [[ ${#LUMIX_VIDS[@]} -eq 1 ]]; then
    ffmpeg -v warning -stats \
        -ss "$SD_OFFSET" -i "${LUMIX_VIDS[0]}" \
        -i "$MIX_WAV" \
        -map 0:v:0 -map 1:a:0 \
        -c:v copy -c:a pcm_s24le \
        -shortest -y "$FINAL_OUT"
else
    # Concat demuxer spaja dijelove koje je kamera podijelila, bez re-encodea.
    CONCAT_LIST="$TMP_DIR/concat.txt"
    : > "$CONCAT_LIST"
    for file in "${LUMIX_VIDS[@]}"; do
        printf "file '%s'\n" "$(python3 -c "import sys;print(sys.argv[1].replace(chr(39), chr(39)+chr(92)+chr(39)+chr(39)))" "$(cd "$(dirname "$file")" && pwd)/$(basename "$file")")" >> "$CONCAT_LIST"
    done
    ffmpeg -v warning -stats \
        -f concat -safe 0 -ss "$SD_OFFSET" -i "$CONCAT_LIST" \
        -i "$MIX_WAV" \
        -map 0:v:0 -map 1:a:0 \
        -c:v copy -c:a pcm_s24le \
        -shortest -y "$FINAL_OUT"
fi

echo ""
echo "✅ Finalna snimka: $FINAL_OUT"
ffprobe -v error -show_entries format=duration,size -of default=noprint_wrappers=1 "$FINAL_OUT"
echo ""
echo "📁 Sadržaj izlazne mape:"
ls -lh "$OUTPUT_DIR"
echo ""
echo "🏁 Gotovo."
