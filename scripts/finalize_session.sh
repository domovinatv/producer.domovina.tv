#!/bin/bash
#
# finalize_session.sh — dovršava sesiju snimljenu u DOMOVINA Studio aplikaciji.
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
YOUTUBE=false
SYNC_OVERRIDE_MS=""

usage() {
    cat <<'EOF'
Upotreba:
  ./scripts/finalize_session.sh \
    --session <mapa_sesije> \
    [--lumix <SD_snimka.MOV> ...] \
    [--output-dir <mapa>] \
    [--sync-offset-ms <n>] [--youtube] \
    [--dry-run] [--help]

  --session         Mapa sesije koju je snimio Studio (sadrži manifest.json).
  --lumix           Snimka(e) sa SD kartice GH5. Bez ovoga se obrađuje samo audio.
  --output-dir      Zadano: <mapa_sesije>/final
  --sync-offset-ms  Ručni pomak mikrofon→slika umjesto izmjerenog iz manifesta
                    (broj iz klizača "Pomak" u Post tabu).
  --youtube         Nakon finalne snimke napravi i *_youtube.mp4
                    (glasnoća -14 LUFS + AAC + faststart, video se ne renderira).
  --dry-run         Izračuna i ispiše sve pomake, ali ne stvara datoteke.
EOF
    exit "${1:-1}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --session)        SESSION_DIR="${2:-}"; shift 2 ;;
        --lumix)          LUMIX_VIDS+=("${2:-}"); shift 2 ;;
        --output-dir)     OUTPUT_DIR="${2:-}"; shift 2 ;;
        --sync-offset-ms) SYNC_OVERRIDE_MS="${2:-}"; shift 2 ;;
        --youtube)        YOUTUBE=true; shift ;;
        --dry-run)        DRY_RUN=true; shift ;;
        --no-isolated)    KEEP_ISOLATED=false; shift ;;
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
if proxy and proxy.get("firstSampleHostNanos") is not None:
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
        # Measured first: the capture device advertises what its format can do
        # (the Elgato 4K X claims 120 fps), not what the camera actually sent.
        field("%.3f" % proxy["measuredFrameRate"] if proxy.get("measuredFrameRate")
              else (proxy.get("nominalFrameRate") or 0)),
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

    # Drift trajectory. A single ratio only guarantees the total duration; if the
    # crystal walked as the microphone warmed up, the middle of a long take stays
    # wrong. Fit each interval separately and report how far the trajectory
    # departs from a straight line, which is the residual a single ratio leaves.
    # `is not None`, not truthiness: the first trajectory point can legitimately
    # carry frameCount 0, and dropping it shifts the whole baseline — which
    # silently rescales every per-interval rate.
    points = [
        (p["hostNanos"], p["frameCount"])
        for p in track.get("driftSamples", [])
        if p.get("hostNanos") is not None and p.get("frameCount") is not None
    ]
    points.sort()
    # Need a real baseline before per-interval rates mean anything.
    if len(points) >= 4 and (points[-1][0] - points[0][0]) > 120e9:
        t0, n0 = points[0]
        total_seconds = (points[-1][0] - t0) / 1e9
        total_frames = points[-1][1] - n0
        global_rate = total_frames / total_seconds

        # Worst deviation between the true trajectory and the straight-line fit,
        # expressed as a time error in milliseconds.
        worst_ms = 0.0
        for host_nanos, frames in points:
            elapsed = (host_nanos - t0) / 1e9
            predicted = n0 + global_rate * elapsed
            worst_ms = max(worst_ms, abs(frames - predicted) / nominal * 1000.0)

        # Piecewise only when it buys something; ~8 ms is well under the point
        # where anyone notices, and splitting has its own (small) cost.
        target_interval = 600.0        # aim for 10-minute pieces
        count = max(2, min(len(points) - 1, int(round(total_seconds / target_interval))))
        mode = "piecewise" if worst_ms > 8.0 else "single"

        print("MICDRIFT\t%s\t%s\t%.2f\t%d" % (field(track.get("id")), mode, worst_ms, len(points)))

        if mode == "piecewise":
            step = (len(points) - 1) / float(count)
            edges = [points[int(round(i * step))] for i in range(count)] + [points[-1]]
            for i in range(len(edges) - 1):
                (ta, na), (tb, nb) = edges[i], edges[i + 1]
                seconds = (tb - ta) / 1e9
                frames = nb - na
                if seconds <= 0 or frames <= 0:
                    continue
                rate = frames / seconds
                if not (0.999 < rate / nominal < 1.001):
                    rate = nominal          # nonsense interval, leave it alone
                # Interval bounds in the source file's own timeline.
                print("MICINTERVAL\t%s\t%.6f\t%.6f\t%.4f" % (
                    field(track.get("id")),
                    (na - n0) / nominal,
                    (nb - n0) / nominal,
                    rate,
                ))
    else:
        print("MICDRIFT\t%s\tsingle\t0.00\t%d" % (field(track.get("id")), len(points)))

# The microphone→picture offset, measured during the take by correlating the
# microphones against the camera's HDMI audio. This is NOT the same thing as the
# host-clock offset: timestamps mark when data reached the driver, and the video
# path is stamped 40–100 ms later than the audio path for the same real moment.
# Without applying this, audio ends up ahead of picture by that amount.
samples = [s for s in manifest.get("syncMeasurements", []) if (s.get("confidence") or 0) > 0.3]


def median(values):
    ordered = sorted(values)
    if not ordered:
        return None
    mid = len(ordered) // 2
    if len(ordered) % 2 == 0:
        return (ordered[mid - 1] + ordered[mid]) / 2.0
    return ordered[mid]


# The camera's own internal A/V offset, from the one-time clap calibration. The
# correlator can only see microphone-to-HDMI-audio; subtracting this turns it into
# microphone-to-picture. Absent means the camera is assumed aligned, which is the
# usual case and was the old behaviour.
calibration = manifest.get("cameraAVOffsetMilliseconds")
calibration = 0.0 if calibration is None else float(calibration)

if len(samples) >= 3:
    offsets = [s["offsetMilliseconds"] - calibration for s in samples]
    overall = median(offsets)
    # Split by time, not by list position, so an uneven sampling rate cannot
    # skew the drift estimate.
    times = [s.get("hostNanos") or 0 for s in samples]
    midpoint = (min(times) + max(times)) / 2.0
    first = [s["offsetMilliseconds"] - calibration for s in samples if (s.get("hostNanos") or 0) <= midpoint]
    second = [s["offsetMilliseconds"] - calibration for s in samples if (s.get("hostNanos") or 0) > midpoint]
    first_median = median(first)
    second_median = median(second)
    spread = max(offsets) - min(offsets)
    print("SYNC\t%.3f\t%d\t%.3f\t%.3f\t%.3f\t%.3f" % (
        overall,
        len(samples),
        spread,
        first_median if first_median is not None else overall,
        second_median if second_median is not None else overall,
        calibration,
    ))
else:
    print("SYNC\t-\t%d\t-\t-\t-\t%.3f" % (len(samples), calibration))

for event in manifest.get("events", []):
    if not event.get("isMarker"):
        continue
    if anchor is None or event.get("hostNanos") is None:
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
SYNC_MS="-"; SYNC_COUNT=0; SYNC_SPREAD="-"; SYNC_FIRST="-"; SYNC_SECOND="-"; SYNC_CALIB="0"

# Parallel indexed arrays, aligned with MIC_IDS. macOS ships bash 3.2, which has
# no associative arrays — `declare -A` fails outright there, so this stays
# portable to a stock Mac instead of requiring a Homebrew bash.
MIC_DRIFT_MODE=(); MIC_DRIFT_WORST=(); MIC_DRIFT_POINTS=(); MIC_DRIFT_INTERVALS=()

mic_index_of() {
    local target="$1" i
    for i in "${!MIC_IDS[@]}"; do
        if [[ "${MIC_IDS[$i]}" == "$target" ]]; then echo "$i"; return 0; fi
    done
    echo "-1"
}

while IFS=$'\t' read -r kind f2 f3 f4 f5 f6 f7; do
    case "$kind" in
        SESSION) SESSION_ID="$f2"; SESSION_DURATION="$f3"; HAS_PROXY="$f4" ;;
        PROXY)   PROXY_REL="$f2"; PROXY_W="$f3"; PROXY_H="$f4"; PROXY_FPS="$f5" ;;
        MIC)     MIC_IDS+=("$f2"); MIC_PATHS+=("$f3"); MIC_OFFSETS+=("$f4")
                 MIC_NOMINAL+=("$f5"); MIC_MEASURED+=("$f6"); MIC_LABELS+=("$f7")
                 MIC_DRIFT_MODE+=("single"); MIC_DRIFT_WORST+=("0")
                 MIC_DRIFT_POINTS+=("0"); MIC_DRIFT_INTERVALS+=("") ;;
        MICDRIFT)
                 di="$(mic_index_of "$f2")"
                 if [[ "$di" != "-1" ]]; then
                     MIC_DRIFT_MODE[$di]="$f3"
                     MIC_DRIFT_WORST[$di]="$f4"
                     MIC_DRIFT_POINTS[$di]="$f5"
                 fi ;;
        MICINTERVAL)
                 di="$(mic_index_of "$f2")"
                 if [[ "$di" != "-1" ]]; then
                     MIC_DRIFT_INTERVALS[$di]="${MIC_DRIFT_INTERVALS[$di]}${f3}:${f4}:${f5} "
                 fi ;;
        SYNC)    SYNC_MS="$f2"; SYNC_COUNT="$f3"; SYNC_SPREAD="$f4"
                 SYNC_FIRST="$f5"; SYNC_SECOND="$f6"; SYNC_CALIB="$f7" ;;
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
echo "📐 Pomaci mikrofona prema vremenskoj osi proxyja (iz host clocka):"
for index in "${!MIC_IDS[@]}"; do
    printf "   %-10s %-22s offset %+9.4f s   drift %+7.1f ppm\n" \
        "${MIC_IDS[$index]}" "${MIC_LABELS[$index]}" "${MIC_OFFSETS[$index]}" \
        "$(python3 -c "print((${MIC_MEASURED[$index]}/${MIC_NOMINAL[$index]}-1)*1e6)")"
done
echo ""

# --- 5b. POMAK MIKROFON → SLIKA (iz korelacije s HDMI zvukom) ---
# Host clock ne vidi latenciju lanaca: video s Elgata je označen desetinama
# milisekundi kasnije od zvuka iz mikrofona za isti stvarni trenutak. HDMI zvuk
# iz kamere putuje istim lancem kao slika, pa korelacija mikrofona i HDMI zvuka
# daje točno tu razliku. Bez ovoga zvuk pretječe sliku.
SYNC_OFFSET_S="0"
if [[ -n "$SYNC_OVERRIDE_MS" ]]; then
    # Ručna vrijednost iz klizača "Pomak" u Post tabu — čovjek je presudio uhom.
    SYNC_OFFSET_S="$(python3 -c "print(${SYNC_OVERRIDE_MS}/1000.0)")"
    printf "🔧 Ručni pomak mikrofon→slika: %+.1f ms  (--sync-offset-ms)\n" "$SYNC_OVERRIDE_MS"
    if [[ "$SYNC_MS" != "-" ]]; then
        printf "   izmjereno korelacijom bilo je %+.1f ms — koristi se ručna vrijednost\n" "$SYNC_MS"
    fi
elif [[ "$SYNC_MS" != "-" ]]; then
    SYNC_OFFSET_S="$(python3 -c "print(${SYNC_MS}/1000.0)")"
    printf "🎯 Pomak mikrofon→slika iz korelacije: %+.1f ms  (%s mjerenja, raspon %.1f ms)\n" \
        "$SYNC_MS" "$SYNC_COUNT" "$SYNC_SPREAD"
    printf "   prva polovina %+.1f ms → druga polovina %+.1f ms\n" "$SYNC_FIRST" "$SYNC_SECOND"
    if python3 -c "import sys; sys.exit(0 if abs(${SYNC_CALIB}) > 0.05 else 1)"; then
        printf "   uključena kalibracija kamere: %+.1f ms (pljesak-test)\n" "$SYNC_CALIB"
    else
        echo "   bez kalibracije kamere — pretpostavlja se da je HDMI zvuk poravnan sa slikom"
    fi

    # A walking offset means one global correction leaves a residual at the ends.
    SYNC_TREND="$(python3 -c "print(round(abs(${SYNC_SECOND}-${SYNC_FIRST}), 1))")"
    if python3 -c "import sys; sys.exit(0 if ${SYNC_TREND} > 25 else 1)"; then
        echo "   ⚠️  Pomak se mijenja za ${SYNC_TREND} ms kroz snimku — jedan globalni ispravak"
        echo "      ostavlja rezidual na krajevima. Za duge epizode treba ispravak po dijelovima."
    else
        echo "   ✅ Pomak je stabilan kroz snimku (promjena ${SYNC_TREND} ms) — globalni ispravak je dovoljan."
    fi
    if python3 -c "import sys; sys.exit(0 if ${SYNC_SPREAD} > 60 else 1)"; then
        echo "   ⚠️  Velik raspon mjerenja — provjeri rezultat na pljesku ili jasnom transientu."
    fi
else
    echo "🎯 Pomak mikrofon→slika: NEMA MJERENJA (${SYNC_COUNT} pouzdanih uzoraka)"
    echo "   Poravnava se samo po host clocku, što ostavlja latenciju lanca neispravljenom."
    echo "   Ako je sesija imala video, provjeri je li HDMI zvuk iz kamere bio odabran."
fi
echo ""

# --- 6. POMAK SD SNIMKE (jedina stvar koju treba korelirati) ---
SD_OFFSET="0"
PROXY_ABS=""
ITSSCALE="1"
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

    # --- 6b. DRIFT KAMERINOG SATA KROZ SNIMKU ---
    # Proxy je postavljen na Macov sat (svaki frame ide na mjesto svog PTS-a), ali
    # SD snimka je od početka do kraja taktirana kamerinim kristalom. Jedna
    # korelacija na početku poravna početak epizode i ostavi kraj van syncа — na
    # 180 minuta i 30 ppm to je preko 300 ms. Zato se korelira i blizu kraja, pa
    # se razlika pretvori u skaliranje timestampova.
    PROXY_DURATION="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$PROXY_ABS")"
    ITSSCALE="1"
    WINDOW=60

    if python3 -c "import sys; sys.exit(0 if ${PROXY_DURATION:-0} > 420 else 1)"; then
        LATE_START="$(python3 -c "print(round(${PROXY_DURATION} * 0.85, 3))")"
        echo "🔎 Druga korelacija na ${LATE_START} s (baseline za drift kamerinog sata)…"

        ffmpeg -v error -ss "$LATE_START" -t "$WINDOW" -i "$PROXY_ABS" \
            -vn -ac 1 -ar 16000 -acodec pcm_s16le -y "$TMP_DIR/proxy_late.wav"

        LATE_OUT="$(audio-offset-finder --find-offset-of "$TMP_DIR/proxy_late.wav" --within "$TMP_DIR/sd_ref.wav" 2>&1)" || true
        LATE_SD="$(awk '/Offset:/ {print $2; exit}' <<< "$LATE_OUT")"
        LATE_SCORE="$(awk '/Standard score:/ {print $3; exit}' <<< "$LATE_OUT")"

        if [[ -z "$LATE_SD" ]]; then
            echo "⚠️  Druga korelacija nije uspjela — ostajem na jednom pomaku."
            echo "   Kraj epizode može biti van syncа ako kamerin sat drifta."
        elif [[ -n "$LATE_SCORE" ]] && python3 -c "import sys; sys.exit(0 if float('$LATE_SCORE') < 10 else 1)"; then
            echo "⚠️  Druga korelacija ima nizak score ($LATE_SCORE) — ignoriram je."
        else
            # SD napreduje (LATE_SD - SD_OFFSET) za svakih LATE_START proxy sekundi.
            RATIO="$(python3 -c "print((${LATE_SD} - ${SD_OFFSET}) / ${LATE_START})")"
            PPM="$(python3 -c "print(round((${RATIO} - 1) * 1e6, 1))")"
            # Sanity band: real crystals are within a few hundred ppm. Anything
            # further out means the correlation landed on the wrong transient.
            if python3 -c "import sys; sys.exit(0 if abs(${PPM}) < 500 else 1)"; then
                ITSSCALE="$(python3 -c "print(repr(1.0 / ${RATIO}))")"
                DRIFT_MS="$(python3 -c "print(round((${RATIO}-1) * ${PROXY_DURATION} * 1000, 1))")"
                printf "✅ Kamerin sat: %+.1f ppm  →  %+.1f ms kroz snimku, ispravljam s -itsscale %s\n" \
                    "$PPM" "$DRIFT_MS" "$ITSSCALE"
                echo "   (skalira samo timestampove — ni jedan frame se ne renderira)"
            else
                echo "⚠️  Izmjereno ${PPM} ppm je izvan realnog raspona — korelacija je pogriješila, ignoriram."
            fi
        fi
        echo ""
    else
        echo "ℹ️  Snimka je kraća od 7 minuta — drift kamerinog sata je zanemariv, preskačem."
        echo ""
    fi
fi

if [[ "$DRY_RUN" == true ]]; then
    echo "🧪 DRY RUN — ništa nije zapisano."
    echo "   SD offset: $SD_OFFSET s"
    echo "   itsscale:  $ITSSCALE"
    exit 0
fi

# --- 7. PROSTOR NA DISKU ---
AVAIL_KB="$(df -k "$OUTPUT_DIR" | awk 'NR==2 {print $4}')"
if [[ -n "$AVAIL_KB" ]] && (( AVAIL_KB < 10485760 )); then
    echo "⚠️  Manje od 10 GB slobodno na izlaznom disku."
fi

# --- 8. DRIFT + POMAK PO MIKROFONU ---
# Dva prolaza, namjerno:
#   1. drift — asetrate reinterpretira datoteku na stvarno izmjerenoj frekvenciji,
#      aresample je vraća na nominalnu. Globalno ili po dijelovima.
#   2. pomak — adelay/atrim postavlja trag na vremensku os proxyja.
# Jedan prolaz bi bio brži, ali ispravak po dijelovima u njemu nije izvediv.
echo "🛠️  Ispravljam drift i poravnavam mikrofone…"
ALIGNED_FILES=()
for index in "${!MIC_IDS[@]}"; do
    mic_id="${MIC_IDS[$index]}"
    src="$SESSION_DIR/${MIC_PATHS[$index]}"
    drifted="$ALIGNED_DIR/${mic_id}_drift.wav"
    dst="$ALIGNED_DIR/${mic_id}_aligned.wav"
    offset="${MIC_OFFSETS[$index]}"
    nominal="${MIC_NOMINAL[$index]}"
    measured="${MIC_MEASURED[$index]}"
    mode="${MIC_DRIFT_MODE[$index]}"
    intervals="${MIC_DRIFT_INTERVALS[$index]}"

    # --- prolaz 1: drift ---
    # Sve granice su u UZORCIMA, ne u sekundama, i svaki dio se reže na točan
    # očekivani broj uzoraka. Bez toga aresample doda 1–2 ms na kraj svakog dijela;
    # na 18 dijelova (3 sata) to je 20–35 ms akumulirane greške, dakle upravo
    # onoliko koliko ispravak po dijelovima treba ukloniti.
    total_frames="$(ffprobe -v error -select_streams a:0 -show_entries stream=duration_ts \
        -of csv=p=0 "$src" 2>/dev/null)"
    if [[ -z "$total_frames" || "$total_frames" == "N/A" ]]; then
        total_frames="$(python3 -c "print(int(round($(ffprobe -v error -show_entries format=duration -of csv=p=0 "$src") * ${nominal})))")"
    fi

    if [[ "$mode" == "piecewise" && -n "$intervals" ]]; then
        printf "   %-10s drift po dijelovima: " "$mic_id"
        PART_LIST="$TMP_DIR/${mic_id}_parts.txt"
        : > "$PART_LIST"
        part_index=0
        cursor=0
        for spec in $intervals; do
            IFS=':' read -r p_start p_end p_rate <<< "$spec"
            # Clamp to the file: the trajectory can extend a fraction of a second
            # past the last written sample.
            read -r n_start n_end expected <<< "$(python3 -c "
nominal=${nominal}; total=${total_frames}
s=min(int(round(${p_start}*nominal)), total)
e=min(int(round(${p_end}*nominal)), total)
n=max(0, e-s)
print(s, e, int(round(n*nominal/${p_rate})))")"
            if [[ "$expected" -le 0 ]]; then continue; fi

            part="$TMP_DIR/${mic_id}_part_$(printf '%03d' "$part_index").wav"
            ffmpeg -v error -i "$src" \
                -af "atrim=start_sample=${n_start}:end_sample=${n_end},asetpts=PTS-STARTPTS,asetrate=${p_rate},aresample=${nominal},atrim=end_sample=${expected},asetpts=PTS-STARTPTS" \
                -c:a pcm_s24le -y "$part" || {
                echo; echo "❌ Dio ${part_index} traga '$mic_id' nije obrađen."; exit 1
            }
            printf "file '%s'\n" "$part" >> "$PART_LIST"
            part_index=$((part_index + 1))
            cursor="$n_end"
        done

        # The trajectory's last point precedes the final samples, so whatever was
        # recorded after it would be dropped — carry it over at the average rate.
        if [[ "$cursor" -lt "$total_frames" ]]; then
            expected="$(python3 -c "print(int(round(($total_frames - $cursor) * ${nominal} / ${measured})))")"
            if [[ "$expected" -gt 0 ]]; then
                tail_part="$TMP_DIR/${mic_id}_part_tail.wav"
                ffmpeg -v error -i "$src" \
                    -af "atrim=start_sample=${cursor},asetpts=PTS-STARTPTS,asetrate=${measured},aresample=${nominal},atrim=end_sample=${expected},asetpts=PTS-STARTPTS" \
                    -c:a pcm_s24le -y "$tail_part" \
                    && printf "file '%s'\n" "$tail_part" >> "$PART_LIST"
            fi
        fi

        ffmpeg -v error -f concat -safe 0 -i "$PART_LIST" -c copy -y "$drifted" || {
            echo; echo "❌ Spajanje dijelova traga '$mic_id' nije uspjelo."; exit 1
        }
        printf "%d dijela (odstupanje od pravca %.1f ms)\n" "$part_index" "${MIC_DRIFT_WORST[$index]}"
    else
        expected="$(python3 -c "print(int(round($total_frames * ${nominal} / ${measured})))")"
        ffmpeg -v error -i "$src" \
            -af "asetrate=${measured},aresample=${nominal},atrim=end_sample=${expected},asetpts=PTS-STARTPTS" \
            -c:a pcm_s24le -y "$drifted" || {
            echo "❌ Ispravak drifta traga '$mic_id' nije uspio."; exit 1
        }
    fi

    # --- prolaz 2: pomak ---
    # Total shift = where the host clock says this file starts, PLUS the measured
    # pipeline-latency difference between the audio and video chains. The second
    # term is the one the clock cannot see, and omitting it puts the audio ahead
    # of the picture by the whole amount.
    total="$(python3 -c "print(${offset} + ${SYNC_OFFSET_S})")"

    # Positive: microphone content sits earlier than the picture, so pad the front.
    # Negative: microphone content sits later, so trim the head.
    if python3 -c "import sys; sys.exit(0 if $total >= 0.0005 else 1)"; then
        delay_ms="$(python3 -c "print(int(round($total*1000)))")"
        shift_filter="adelay=${delay_ms}:all=1"
        printf "   %-10s +%d ms tišine na početak  (sat %+.1f ms + lanac %+.1f ms)\n" \
            "$mic_id" "$delay_ms" \
            "$(python3 -c "print($offset*1000)")" \
            "$(python3 -c "print(${SYNC_OFFSET_S}*1000)")"
    elif python3 -c "import sys; sys.exit(0 if $total <= -0.0005 else 1)"; then
        trim_s="$(python3 -c "print(abs($total))")"
        shift_filter="atrim=start=${trim_s},asetpts=PTS-STARTPTS"
        printf "   %-10s režem %.4f s s početka  (sat %+.1f ms + lanac %+.1f ms)\n" \
            "$mic_id" "$trim_s" \
            "$(python3 -c "print($offset*1000)")" \
            "$(python3 -c "print(${SYNC_OFFSET_S}*1000)")"
    else
        shift_filter="anull"
        printf "   %-10s već poravnan\n" "$mic_id"
    fi

    ffmpeg -v error -i "$drifted" -af "$shift_filter" -c:a pcm_s24le -y "$dst" || {
        echo "❌ Poravnavanje '$mic_id' nije uspjelo."; exit 1
    }
    rm -f "$drifted"
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
    [[ "$YOUTUBE" == true ]] && echo "   (--youtube preskočen: nema videa za isporuku)"
    echo "🏁 Gotovo."
    exit 0
fi

FINAL_OUT="$OUTPUT_DIR/${SESSION_ID:-podcast}_final.mov"
echo "🎬 Muxam SD snimku s miksom (stream copy, bez renderiranja)…"

if [[ "$ITSSCALE" != "1" ]]; then
    echo "   (uz -itsscale $ITSSCALE za drift kamerinog sata)"
fi

if [[ ${#LUMIX_VIDS[@]} -eq 1 ]]; then
    ffmpeg -v warning -stats \
        -itsscale "$ITSSCALE" -ss "$SD_OFFSET" -i "${LUMIX_VIDS[0]}" \
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
        -itsscale "$ITSSCALE" -f concat -safe 0 -ss "$SD_OFFSET" -i "$CONCAT_LIST" \
        -i "$MIX_WAV" \
        -map 0:v:0 -map 1:a:0 \
        -c:v copy -c:a pcm_s24le \
        -shortest -y "$FINAL_OUT"
fi

echo ""
echo "✅ Finalna snimka: $FINAL_OUT"
ffprobe -v error -show_entries format=duration,size -of default=noprint_wrappers=1 "$FINAL_OUT"
echo ""

# --- 12. ISPORUKA ZA YOUTUBE (opcionalno) ---
# Odvojen prolaz: glasnoća + AAC + faststart, video opet samo stream copy.
if [[ "$YOUTUBE" == true ]]; then
    DELIVERY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/youtube_delivery.sh"
    [[ -x "$DELIVERY" ]] || { echo "❌ Nema youtube_delivery.sh pored ove skripte."; exit 1; }
    "$DELIVERY" --input "$FINAL_OUT" --output-dir "$OUTPUT_DIR" || exit 1
    echo ""
fi

echo "📁 Sadržaj izlazne mape:"
ls -lh "$OUTPUT_DIR"
echo ""
echo "🏁 Gotovo."
