#!/bin/bash
#
# finalize_backup.sh — spaja backup snimku kamere s RØDE Connect mixom u datoteku
# spremnu za upload na YouTube.
#
# Ovo je treći put kroz post-produkciju, za slučaj kad sesija NIJE prošla kroz
# aplikaciju:
#   podcast_sync.sh      — Riverside referenca + RØDE (naslijeđeno)
#   finalize_session.sh  — sesija iz Studija, pomaci poznati iz host clocka
#   finalize_backup.sh   — samo SD master kamere + StereoMix.wav (ovaj file)
#
# Bez manifesta nema ni jednog poznatog pomaka, pa se sve mjeri korelacijom.
# Referentni zvuk je kamerin vlastiti (SD zapis je interno u syncu sam sa sobom),
# pa korelacija mix→kamerin zvuk daje točno pomak mixa prema slici.
#
# Mjeri se na tri mjesta, ne na jednom:
#   - rano  (~10 % snimke) → pomak A
#   - kasno (~85 % snimke) → nagib r, tj. drift između dva kristala (kamera i RØDE)
#   - sredina             → provjera: linearni model mora pogoditi i tu točku
# Model je  s = A + r·c  (s = vrijeme u mixu, c = vrijeme u kameri). Video dobiva
# -itsscale r, zvuk -ss A; ni jedan frame se ne renderira.
#
set -uo pipefail

# --- 1. ARGUMENTI ---
CAMERA_VIDS=()
AUDIO_WAV=""
OUTPUT_DIR=""
NAME=""
DRY_RUN=false
SMOKE_ONLY=false
SMOKE_AT=""
SMOKE_SECONDS=45
NO_DRIFT=false
LOUDNESS=false
LOUD_TARGET=-14      # YouTube referenca; katalog u fetch.domovina.tv vozi -16
LOUD_TP=-2           # headroom za AAC: enkoder podiže true peak NAKON limitera
KEEP_CAMERA_AUDIO=false
EXTRA_MS=0
WINDOW=60          # duljina korelacijskog prozora
MARGIN=45          # koliko se traži lijevo/desno od predviđenog mjesta

usage() {
    cat <<'EOF'
Upotreba:
  ./scripts/finalize_backup.sh \
    --camera <SD_snimka.MP4> [--camera <nastavak.MP4> ...] \
    --audio  <StereoMix.wav> \
    --output-dir <mapa> \
    [--smoke-test] [--smoke-at <sekunde|middle>] [--smoke-seconds <n>] \
    [--name <naziv>] [--loudness] [--keep-camera-audio] \
    [--offset-ms <n>] [--no-drift] [--dry-run] [--help]

  --camera             SD snimka s kamere. Više puta ako je kamera dijelila file.
  --audio              Mix iz RØDE Connecta (ili bilo koji WAV s istim sadržajem).
  --output-dir         Gdje ide finalna datoteka.
  --smoke-test         Napravi samo kratki isječak iz sredine za provjeru sinkrona.
  --smoke-at           Gdje uzeti isječak (sekunde od početka videa). Zadano: sredina.
  --smoke-seconds      Trajanje isječka. Zadano: 45.
  --name               Osnova naziva izlazne datoteke. Zadano: naziv SD snimke.
  --loudness           Normaliziraj na -14 LUFS (YouTube referenca).
  --loudness-target    Drugi cilj u LUFS, npr. -16 (kućni standard kataloga).
  --keep-camera-audio  Zadrži i kamerin zvuk kao drugi audio trag.
  --offset-ms          Ručna korekcija povrh izmjerene (+ = zvuk kasnije).
  --no-drift           Preskoči drugu korelaciju, koristi samo jedan pomak.
  --dry-run            Izmjeri i ispiši sve, ali ne stvaraj ništa.
EOF
    exit "${1:-1}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --camera)             CAMERA_VIDS+=("${2:-}"); shift 2 ;;
        --audio)              AUDIO_WAV="${2:-}"; shift 2 ;;
        --output-dir)         OUTPUT_DIR="${2:-}"; shift 2 ;;
        --name)               NAME="${2:-}"; shift 2 ;;
        --smoke-test)         SMOKE_ONLY=true; shift ;;
        --smoke-at)           SMOKE_AT="${2:-}"; shift 2 ;;
        --smoke-seconds)      SMOKE_SECONDS="${2:-}"; shift 2 ;;
        --loudness)           LOUDNESS=true; shift ;;
        --loudness-target)    LOUD_TARGET="${2:-}"; LOUDNESS=true; shift 2 ;;
        --keep-camera-audio)  KEEP_CAMERA_AUDIO=true; shift ;;
        --offset-ms)          EXTRA_MS="${2:-}"; shift 2 ;;
        --no-drift)           NO_DRIFT=true; shift ;;
        --dry-run)            DRY_RUN=true; shift ;;
        --help|-h)            usage 0 ;;
        *) echo "❌ Nepoznat argument: $1"; usage ;;
    esac
done

[[ ${#CAMERA_VIDS[@]} -gt 0 ]] || { echo "❌ --camera je obavezan."; usage; }
[[ -n "$AUDIO_WAV" ]] || { echo "❌ --audio je obavezan."; usage; }
[[ -n "$OUTPUT_DIR" ]] || { echo "❌ --output-dir je obavezan."; usage; }

for file in "${CAMERA_VIDS[@]}" "$AUDIO_WAV"; do
    [[ -f "$file" ]] || { echo "❌ Datoteka ne postoji: $file"; exit 1; }
done

# --- 2. ALATI ---
for tool in ffmpeg ffprobe python3 audio-offset-finder; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "❌ Nedostaje '$tool'."
        case "$tool" in
            ffmpeg|ffprobe)      echo "   brew install ffmpeg" ;;
            audio-offset-finder) echo "   pip install audio-offset-finder" ;;
        esac
        exit 1
    }
done

mkdir -p "$OUTPUT_DIR"
LOG_FILE="$OUTPUT_DIR/backup_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee "$LOG_FILE") 2>&1

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/domovina_backup.XXXXXX")"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

CAM0="${CAMERA_VIDS[0]}"
[[ -n "$NAME" ]] || { NAME="$(basename "$CAM0")"; NAME="${NAME%.*}"; }

echo "🎬 Kamera:  ${CAMERA_VIDS[*]}"
echo "🎙️  Zvuk:    $AUDIO_WAV"
echo "📝 Log:     $LOG_FILE"
echo ""

# --- 3. ŠTO SU ZAPRAVO TE DATOTEKE ---
probe() { ffprobe -v error -show_entries "$1" -of csv=p=0 "$2" 2>/dev/null | head -1; }

CAM_DURATION="$(probe format=duration "$CAM0")"
CAM_FPS_RAW="$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 "$CAM0")"
CAM_SIZE="$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x "$CAM0")"
CAM_VCODEC="$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$CAM0")"
CAM_HAS_AUDIO="$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of csv=p=0 "$CAM0")"
AUD_DURATION="$(probe format=duration "$AUDIO_WAV")"
AUD_RATE="$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate -of csv=p=0 "$AUDIO_WAV")"
AUD_CH="$(ffprobe -v error -select_streams a:0 -show_entries stream=channels -of csv=p=0 "$AUDIO_WAV")"

[[ -n "$CAM_HAS_AUDIO" ]] || {
    echo "❌ SD snimka nema zvučni zapis — korelacija nije moguća."
    echo "   Bez kamerinog zvuka nema načina da se sazna gdje mix počinje."
    exit 1
}

hms() { python3 -c "t=float('$1'); print('%d:%02d:%05.2f' % (t//3600,(t%3600)//60,t%60))"; }

echo "📹 Video:  $CAM_SIZE $CAM_VCODEC @ $CAM_FPS_RAW   $(hms "$CAM_DURATION")  (kamerin zvuk: $CAM_HAS_AUDIO)"
echo "🔊 Zvuk:   ${AUD_RATE} Hz, ${AUD_CH} kanala        $(hms "$AUD_DURATION")"
echo ""

# Cijela snimka ostatka posla se mjeri prema videu, pa ako je zvuk kraći od
# videa, dio epizode na kraju nema zvuk — to je bolje reći odmah nego na kraju.
if python3 -c "import sys; sys.exit(0 if $AUD_DURATION < $CAM_DURATION else 1)"; then
    echo "⚠️  Zvuk je kraći od videa za $(python3 -c "print(round($CAM_DURATION-$AUD_DURATION,1))") s."
    echo "   Ako mix ne pokriva cijeli video, kraj će biti nadopunjen tišinom."
    echo ""
fi

# --- 4. KORELACIJA ---
# Referenca je uvijek prozor iz kamere koji se traži unutar mixa: mix je duži i
# obično počinje ranije, a audio-offset-finder traži kraći uzorak u dužem.
echo "🎵 Izvlačim referentni zvuk iz mixa (16 kHz mono)…"
SM_REF="$TMP_DIR/mix_ref.wav"
ffmpeg -v error -i "$AUDIO_WAV" -vn -ac 1 -ar 16000 -acodec pcm_s16le -y "$SM_REF" || {
    echo "❌ Ne mogu pročitati zvuk iz $AUDIO_WAV"; exit 1
}

CAM_WIN_FILE="$TMP_DIR/cam_win.wav"
AOF_OFFSET=""
AOF_SCORE=""

# Traži prozor kamere od `cam_pos` unutar mixa. Ako je dano predviđanje, gleda
# se samo uski pojas oko njega — brže je i ne može odlutati na krivi transient.
correlate() {
    local cam_pos="$1" predicted="${2:-}"
    local haystack="$SM_REF" slice_start=0

    ffmpeg -v error -ss "$cam_pos" -t "$WINDOW" -i "$CAM0" \
        -vn -ac 1 -ar 16000 -acodec pcm_s16le -y "$CAM_WIN_FILE" || return 1

    if [[ -n "$predicted" ]]; then
        slice_start="$(python3 -c "print(max(0.0, $predicted - $MARGIN))")"
        haystack="$TMP_DIR/mix_slice.wav"
        ffmpeg -v error -ss "$slice_start" -t "$(python3 -c "print($WINDOW + 2*$MARGIN)")" \
            -i "$SM_REF" -acodec pcm_s16le -y "$haystack" || return 1
    fi

    local out
    out="$(audio-offset-finder --find-offset-of "$CAM_WIN_FILE" --within "$haystack" 2>&1)" || true
    local raw
    raw="$(awk '/Offset:/ {print $2; exit}' <<< "$out")"
    AOF_SCORE="$(awk '/Standard score:/ {print $3; exit}' <<< "$out")"
    [[ -n "$raw" ]] || { echo "$out"; return 1; }
    AOF_OFFSET="$(python3 -c "print($raw + $slice_start)")"
    return 0
}

EARLY_C="$(python3 -c "print(round($CAM_DURATION * 0.10, 3))")"
LATE_C="$(python3 -c "print(round($CAM_DURATION * 0.85, 3))")"
MID_C="$(python3 -c "print(round($CAM_DURATION * 0.50, 3))")"

echo "🔎 Korelacija 1/3 — prozor kamere na $(hms "$EARLY_C") tražim u cijelom mixu…"
correlate "$EARLY_C" || { echo "❌ Prva korelacija nije uspjela."; exit 1; }
EARLY_S="$AOF_OFFSET"; EARLY_SCORE="$AOF_SCORE"
printf "   nađeno u mixu na %s  (score %s)\n" "$(hms "$EARLY_S")" "${EARLY_SCORE:-?}"

if [[ -n "$EARLY_SCORE" ]] && python3 -c "import sys; sys.exit(0 if float('$EARLY_SCORE') < 10 else 1)"; then
    echo "❌ Standard score je ispod 10 — to nije pouzdano poklapanje."
    echo "   Provjeri jesu li kamera i mix uopće ista snimka."
    exit 1
fi

RATIO=1
PPM=0
if [[ "$NO_DRIFT" == true ]]; then
    echo "ℹ️  --no-drift: preskačem drugu korelaciju."
else
    echo "🔎 Korelacija 2/3 — prozor na $(hms "$LATE_C") (nagib, tj. drift kristala)…"
    if correlate "$LATE_C" "$(python3 -c "print($EARLY_S + $LATE_C - $EARLY_C)")"; then
        LATE_S="$AOF_OFFSET"; LATE_SCORE="$AOF_SCORE"
        printf "   nađeno u mixu na %s  (score %s)\n" "$(hms "$LATE_S")" "${LATE_SCORE:-?}"
        if [[ -n "$LATE_SCORE" ]] && python3 -c "import sys; sys.exit(0 if float('$LATE_SCORE') < 10 else 1)"; then
            echo "⚠️  Nizak score na drugoj korelaciji — ignoriram nagib."
        else
            RATIO="$(python3 -c "print(repr(($LATE_S - $EARLY_S) / ($LATE_C - $EARLY_C)))")"
            PPM="$(python3 -c "print(round(($RATIO - 1) * 1e6, 1))")"
            # Realni kristali su unutar par stotina ppm; više od toga znači da je
            # korelacija sjela na krivo mjesto, a ne da satovi bježe.
            if python3 -c "import sys; sys.exit(0 if abs($PPM) < 500 else 1)"; then
                printf "   drift: %+.1f ppm  →  %+.0f ms kroz cijelu snimku\n" \
                    "$PPM" "$(python3 -c "print(($RATIO-1)*$CAM_DURATION*1000)")"
            else
                echo "⚠️  Izmjereno $PPM ppm je izvan realnog raspona — ignoriram."
                RATIO=1; PPM=0
            fi
        fi
    else
        echo "⚠️  Druga korelacija nije uspjela — ostajem na jednom pomaku."
    fi
fi

# Model: s = A + r·c
OFFSET_A="$(python3 -c "print(repr($EARLY_S - $RATIO * $EARLY_C))")"
# Ručna korekcija: + znači da zvuk treba kasniti, dakle uzima se ranije iz mixa.
if [[ "$EXTRA_MS" != "0" ]]; then
    OFFSET_A="$(python3 -c "print(repr($OFFSET_A - $EXTRA_MS/1000.0))")"
    printf "🔧 Ručna korekcija: %+s ms\n" "$EXTRA_MS"
fi

# Treća korelacija ne ulazi u model — ona ga provjerava. Ako model promaši
# sredinu snimke za više od ~20 ms, nešto ne valja i bolje je to znati sada.
if [[ "$NO_DRIFT" != true ]]; then
    echo "🔎 Korelacija 3/3 — provjera modela na $(hms "$MID_C")…"
    PREDICTED_MID="$(python3 -c "print($OFFSET_A + $RATIO * $MID_C)")"
    if correlate "$MID_C" "$PREDICTED_MID"; then
        RESIDUAL_MS="$(python3 -c "print(round(($AOF_OFFSET - $PREDICTED_MID)*1000, 1))")"
        printf "   model promašuje sredinu za %+.1f ms  (score %s)\n" "$RESIDUAL_MS" "${AOF_SCORE:-?}"
        if python3 -c "import sys; sys.exit(0 if abs($RESIDUAL_MS) > 20 else 1)"; then
            echo "   ⚠️  Više od 20 ms — sinkron nije linearan kroz snimku."
            echo "      Provjeri smoke test prije nego što išta objaviš."
        else
            echo "   ✅ Unutar 20 ms — jedan pomak i jedan nagib pokrivaju cijelu snimku."
        fi
    else
        echo "   ⚠️  Provjera nije uspjela (nema jasnog govora u tom prozoru?)."
    fi
fi

echo ""
echo "📐 Rezultat mjerenja:"
printf "   pomak mixa:  %+.3f s   (%s od početka mixa je prvi frame videa)\n" \
    "$OFFSET_A" "$(hms "$(python3 -c "print(abs($OFFSET_A))")")"
printf "   nagib:       %s  (%+.1f ppm)\n" "$RATIO" "$PPM"
echo ""

# Negativan pomak znači da je mix počeo KASNIJE od kamere — tada se ne može
# rezati zvuk, nego video, i početak epizode ostaje bez zvuka ako se ne reže.
VIDEO_SS=0
AUDIO_SS="$OFFSET_A"
if python3 -c "import sys; sys.exit(0 if $OFFSET_A < 0 else 1)"; then
    VIDEO_SS="$(python3 -c "print(repr(abs($OFFSET_A) / $RATIO))")"
    AUDIO_SS=0
    echo "ℹ️  Mix je počeo kasnije od kamere — režem $(python3 -c "print(round($VIDEO_SS,3))") s s početka videa."
    echo ""
fi

audio_time_for() { python3 -c "print(repr($AUDIO_SS + $RATIO * $1 - $RATIO * $VIDEO_SS))"; }

# --- 5. GLASNOĆA ---
# Mjeri se uvijek, primjenjuje samo uz --loudness. Mjerenje traje ~20 s na sat
# vremena zvuka, a bez njega se ne zna je li mix uopće upotrebljiv: RØDE Connect
# zna izbaciti mix 25 dB ispod onoga što YouTube očekuje, i to se na slušalicama
# tijekom snimanja ne primijeti.
echo "🔉 Mjerim glasnoću mixa…"
LN_JSON="$(ffmpeg -hide_banner -nostats -i "$AUDIO_WAV" \
    -af loudnorm=I=-14:TP=-1.5:LRA=11:print_format=json -f null - 2>&1 | awk '/^\{/,/^\}/')"

MEASURED_I=""; MEASURED_TP=""; MEASURED_LRA=""; MEASURED_THRESH=""
if [[ -n "$LN_JSON" ]]; then
    read -r MEASURED_I MEASURED_TP MEASURED_LRA MEASURED_THRESH <<< "$(python3 - <<PY
import json
data = json.loads('''$LN_JSON''')
print(data["input_i"], data["input_tp"], data["input_lra"], data["input_thresh"])
PY
)"
fi

if [[ -n "$MEASURED_I" ]]; then
    printf "   izmjereno: %s LUFS,  true peak %s dBFS,  LRA %s LU\n" \
        "$MEASURED_I" "$MEASURED_TP" "$MEASURED_LRA"
    GAIN_DB="$(python3 -c "print(round($LOUD_TARGET - ($MEASURED_I), 1))")"
    if python3 -c "import sys; sys.exit(0 if abs($GAIN_DB) > 3 else 1)"; then
        printf "   ⚠️  To je %+.1f dB od cilja (%s LUFS).\n" "$GAIN_DB" "$LOUD_TARGET"
        [[ "$LOUDNESS" == true ]] || echo "      Pokreni s --loudness ili će epizoda biti bitno tiša od svega ostalog."
    else
        echo "   ✅ Blizu ${LOUD_TARGET} LUFS, normalizacija nije nužna."
    fi
else
    echo "   ⚠️  Mjerenje nije uspjelo — nastavljam bez podataka o glasnoći."
fi
echo ""

# --- 5b. FILTAR ZA ZVUK ---
# apad + -shortest daje izlaz točno duljine videa: ako mix završi ranije, ostatak
# je tišina umjesto odrezane slike.
AFILTER="apad"
if [[ "$LOUDNESS" == true ]]; then
    if [[ -n "$MEASURED_I" ]]; then
        # Konstantno pojačanje + EKSPLICITNI limiter. Ovo je namjerno drukčije od
        # normalize_loudness.js u fetch.domovina.tv, koji vozi single-pass dynamic
        # loudnorm: tamo je linearni put odbačen jer loudnorm u linearnom načinu
        # nema true-peak limiter i klipa. Ovdje limiter postoji zasebno, pa razlog
        # za odbacivanje otpada, a dobiva se ono što dynamic ne čuva — dinamika.
        # Izmjereno na 45 s iz sredine ove epizode: dynamic stisne LRA s 8.0 na
        # 4.2 LU, linearno+limiter je ostavi na 8.0 uz isti true peak i isti šum.
        # limit=0.794 je -2 dBFS, ne -1: AAC enkoder podiže true peak NAKON
        # limitera (~0.7 dB izmjereno) — zamka 3 iz docs/loudness_normalization.
        LIMIT="$(python3 -c "print(round(10 ** ($LOUD_TP / 20.0), 4))")"
        AFILTER="volume=${GAIN_DB}dB,alimiter=limit=${LIMIT}:level=disabled,apad"
        echo "🔉 Normalizacija: konstantnih ${GAIN_DB} dB na ${LOUD_TARGET} LUFS + limiter na ${LOUD_TP} dBFS."
        echo "   Šum snimke se diže za isto toliko — to je cijena tihog mixa, ne greška obrade."
    else
        AFILTER="loudnorm=I=-14:TP=-1.5:LRA=11,apad"
        echo "🔉 Normalizacija: jednoprolazna (mjerenje nije uspjelo)."
    fi
    echo ""
fi

if [[ "$DRY_RUN" == true ]]; then
    echo "🧪 DRY RUN — ništa nije zapisano."
    exit 0
fi

# --- 6. SMOKE TEST ---
# Kratki isječak iz sredine, prekodiran na 1080p da se otvori bilo gdje i brzo.
# Uz to se automatski provjeri koliko je zvuk u isječku pomaknut prema kamerinom
# zvuku iz istog trenutka — to je broj koji kaže je li sinkron stvarno dobar.
if [[ "$SMOKE_ONLY" == true ]]; then
    SMOKE_C="${SMOKE_AT:-$MID_C}"
    [[ "$SMOKE_C" == "middle" ]] && SMOKE_C="$MID_C"
    SMOKE_A="$(audio_time_for "$SMOKE_C")"
    SMOKE_OUT="$OUTPUT_DIR/${NAME}_smoke_$(python3 -c "print(int($SMOKE_C))").mp4"

    echo "🧪 Smoke test: video od $(hms "$SMOKE_C"), zvuk iz mixa od $(hms "$SMOKE_A"), ${SMOKE_SECONDS} s"
    ffmpeg -v warning -stats \
        -ss "$SMOKE_C" -t "$SMOKE_SECONDS" -i "$CAM0" \
        -ss "$SMOKE_A" -t "$SMOKE_SECONDS" -i "$AUDIO_WAV" \
        -map 0:v:0 -map 1:a:0 \
        -vf scale=1920:-2 -c:v libx264 -preset veryfast -crf 20 -pix_fmt yuv420p \
        -filter:a:0 "$AFILTER" -c:a aac -b:a 256k -ar 48000 \
        -shortest -movflags +faststart -y "$SMOKE_OUT" || {
        echo "❌ Smoke test nije napravljen."; exit 1
    }

    echo ""
    echo "🔬 Provjeravam sinkron unutar isječka (zvuk isječka prema kamerinom zvuku)…"
    # Referenca je uži isječak kamerinog zvuka, uzet 5 s od početka prozora. Ako je
    # sve točno, on se u zvuku gotovog isječka mora naći na točno 5,000 s.
    PROBE_LEN="$(python3 -c "print(max(10, $SMOKE_SECONDS - 10))")"
    ffmpeg -v error -i "$SMOKE_OUT" -vn -ac 1 -ar 16000 -acodec pcm_s16le -y "$TMP_DIR/smoke_mix.wav"
    ffmpeg -v error -ss "$(python3 -c "print($SMOKE_C + 5)")" -t "$PROBE_LEN" -i "$CAM0" \
        -vn -ac 1 -ar 16000 -acodec pcm_s16le -y "$TMP_DIR/smoke_cam.wav"
    SMOKE_OUT_TXT="$(audio-offset-finder --find-offset-of "$TMP_DIR/smoke_cam.wav" \
        --within "$TMP_DIR/smoke_mix.wav" 2>&1)" || true
    SMOKE_RES="$(awk '/Offset:/ {print $2; exit}' <<< "$SMOKE_OUT_TXT")"
    SMOKE_SC="$(awk '/Standard score:/ {print $3; exit}' <<< "$SMOKE_OUT_TXT")"
    if [[ -n "$SMOKE_RES" ]]; then
        SMOKE_MS="$(python3 -c "print(round(($SMOKE_RES - 5.0)*1000, 1))")"
        printf "   rezidual: %+.1f ms  (score %s)\n" "$SMOKE_MS" "${SMOKE_SC:-?}"
        echo "   (+ = zvuk kasni za slikom, − = zvuk pretječe sliku; ispod ~20 ms se ne vidi)"
    else
        echo "   ⚠️  Nije izmjereno — pogledaj isječak očima."
    fi

    # Isječak je i provjera obrade zvuka, ne samo sinkrona: ovo je razina koja će
    # izaći iz finalne datoteke, mjerena na gotovom produktu a ne na ulazu.
    echo ""
    echo "🔉 Glasnoća isječka (ono što će čuti gledatelj):"
    ffmpeg -hide_banner -nostats -i "$SMOKE_OUT" -af ebur128=peak=true -f null - 2>&1 \
        | grep -E "^ +(I|Peak):" | sed 's/^/   /'

    echo ""
    echo "✅ Isječak: $SMOKE_OUT"
    echo "   open \"$SMOKE_OUT\""
    exit 0
fi

# --- 7. PROSTOR NA DISKU ---
NEEDED_KB=0
for file in "${CAMERA_VIDS[@]}"; do
    NEEDED_KB=$(( NEEDED_KB + $(stat -f%z "$file") / 1024 ))
done
NEEDED_KB=$(( NEEDED_KB * 105 / 100 ))     # video se kopira 1:1, zvuk je zanemariv
AVAIL_KB="$(df -k "$OUTPUT_DIR" | awk 'NR==2 {print $4}')"
if [[ -n "$AVAIL_KB" ]] && (( AVAIL_KB < NEEDED_KB )); then
    echo "❌ Nema dovoljno prostora: treba ~$((NEEDED_KB/1024/1024)) GB, slobodno $((AVAIL_KB/1024/1024)) GB."
    exit 1
fi

# --- 8. FINALNI MUX ---
# Video se ne dira: -c:v copy. Mijenjaju se samo timestampovi (-itsscale) i zvuk
# se kodira u AAC 384k, što je ono što YouTube ionako traži.
FINAL_OUT="$OUTPUT_DIR/${NAME}_youtube.mp4"
echo "🎬 Spajam finalnu datoteku (stream copy videa, bez renderiranja)…"
echo "   → $FINAL_OUT"
[[ "$RATIO" != "1" ]] && echo "   uz -itsscale $RATIO za drift kristala"

INPUT_ARGS=()
if [[ ${#CAMERA_VIDS[@]} -eq 1 ]]; then
    INPUT_ARGS=(-itsscale "$RATIO" -ss "$VIDEO_SS" -i "$CAM0")
else
    CONCAT_LIST="$TMP_DIR/concat.txt"
    : > "$CONCAT_LIST"
    for file in "${CAMERA_VIDS[@]}"; do
        abs="$(cd "$(dirname "$file")" && pwd)/$(basename "$file")"
        printf "file '%s'\n" "$(python3 -c "import sys;print(sys.argv[1].replace(chr(39), chr(39)+chr(92)+chr(39)+chr(39)))" "$abs")" >> "$CONCAT_LIST"
    done
    INPUT_ARGS=(-itsscale "$RATIO" -f concat -safe 0 -ss "$VIDEO_SS" -i "$CONCAT_LIST")
fi

MAP_ARGS=(-map 0:v:0 -map 1:a:0)
CODEC_ARGS=(-c:v copy -filter:a:0 "$AFILTER" -c:a aac -b:a 384k -ar 48000)
if [[ "$KEEP_CAMERA_AUDIO" == true ]]; then
    MAP_ARGS+=(-map 0:a:0)
    CODEC_ARGS+=(-c:a:1 aac -b:a:1 128k
                 -metadata:s:a:0 title="RØDE Connect mix"
                 -metadata:s:a:1 title="Kamera (referenca)")
fi

ffmpeg -v warning -stats \
    "${INPUT_ARGS[@]}" \
    -ss "$AUDIO_SS" -i "$AUDIO_WAV" \
    "${MAP_ARGS[@]}" \
    "${CODEC_ARGS[@]}" \
    -shortest -y "$FINAL_OUT" || { echo "❌ Spajanje nije uspjelo."; exit 1; }

echo ""
echo "✅ Za upload: $FINAL_OUT"
ffprobe -v error -show_entries format=duration,size -of default=noprint_wrappers=1 "$FINAL_OUT"
ls -lh "$FINAL_OUT"
echo ""
echo "🏁 Gotovo."
command -v afplay >/dev/null 2>&1 && afplay /System/Library/Sounds/Glass.aiff &
osascript -e 'display notification "Finalna datoteka je spremna za YouTube." with title "DOMOVINA Studio"' 2>/dev/null
