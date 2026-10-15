#!/bin/bash
#
# rebuild_mix.sh — gradi miks iz izoliranih RØDE Connect tragova umjesto iz
# njegovog gotovog StereoMixa.
#
# Zašto uopće: RØDE-ov miks je zbroj mikrofona onakvih kakvi jesu. Ako je jedan
# govornik bliže svom mikrofonu, u miksu je i glasniji i bučniji (proximity efekt
# diže bas ispod ~200 Hz), a to se u miksu više ne da razdvojiti. Izolirani tragovi
# su uzorak-po-uzorak poravnati s miksom, pa se svaki glas može posebno izbalansirati
# i EQ-ati, a rezultat i dalje sjeda na isti pomak prema videu.
#
# Sve odluke se MJERE, ne pretpostavljaju:
#   - tko govori kada: trag je "svoj" dok je jači od svih ostalih za >4 dB
#   - razina: medijan RMS-a dok taj govornik govori → pojačanje koje ih izjednači
#   - proximity: udio 90-150 Hz prema 1-2 kHz, uspoređen među tragovima
#
# Izlaz je WAV bez finalne normalizacije — nju radi finalize_backup.sh, koji ionako
# mjeri ulaz koji dobije.
#
set -uo pipefail

MICS=()
OUTPUT=""
PROXIMITY_DB=-8         # koliko skinuti na 120 Hz tragu koji ima proximity efekt
PROXIMITY_THRESHOLD=6   # od koliko dB viška se uopće smatra proximity efektom
HIGHPASS=75
PRESENCE_DB=0           # +dB iznad 3.5 kHz na tragu s proximityjem (0 = ne diraj)
DRY_RUN=false

usage() {
    cat <<'EOF'
Upotreba:
  ./scripts/rebuild_mix.sh --mic <trag1.wav> --mic <trag2.wav> [...] \
    --output <miks.wav> [--proximity-db -8] [--presence-db 0] \
    [--highpass 75] [--dry-run]

  --mic            Izolirani trag. Navesti jednom po mikrofonu.
  --output         Izlazni WAV (24-bit).
  --proximity-db   Rez na 120 Hz za trag s proximity efektom. Zadano -8.
  --presence-db    Podizanje iznad 3.5 kHz za taj isti trag. Zadano 0 (isključeno).
  --highpass       Rez ispod ove frekvencije na svim tragovima. Zadano 75 Hz.
  --dry-run        Samo izmjeri i ispiši što bi napravio.
EOF
    exit "${1:-1}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mic)           MICS+=("${2:-}"); shift 2 ;;
        --output)        OUTPUT="${2:-}"; shift 2 ;;
        --proximity-db)  PROXIMITY_DB="${2:-}"; shift 2 ;;
        --presence-db)   PRESENCE_DB="${2:-}"; shift 2 ;;
        --highpass)      HIGHPASS="${2:-}"; shift 2 ;;
        --dry-run)       DRY_RUN=true; shift ;;
        --help|-h)       usage 0 ;;
        *) echo "❌ Nepoznat argument: $1"; usage ;;
    esac
done

[[ ${#MICS[@]} -ge 2 ]] || { echo "❌ Trebaju barem dva --mic traga."; usage; }
[[ -n "$OUTPUT" ]] || { echo "❌ --output je obavezan."; usage; }
for f in "${MICS[@]}"; do
    [[ -f "$f" ]] || { echo "❌ Datoteka ne postoji: $f"; exit 1; }
done
for tool in ffmpeg ffprobe python3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "❌ Nedostaje '$tool'."; exit 1; }
done
python3 -c "import numpy, soundfile" 2>/dev/null || {
    echo "❌ Trebaju python moduli numpy i soundfile:  pip install numpy soundfile"; exit 1
}

echo "🎚️  Tragovi (${#MICS[@]}):"
for f in "${MICS[@]}"; do echo "   $(basename "$f")"; done
echo ""

# --- MJERENJE ---
# Python ispisuje TSV: po jedan redak GAIN za svaki trag i jedan PROX redak.
# Isti razlog kao u finalize_session.sh: TSV je jedini format koji bash čita bez
# ovisnosti, a prazna polja se nikad ne emitiraju (tab je IFS whitespace).
MEASURE="$(python3 - "$PROXIMITY_THRESHOLD" "${MICS[@]}" <<'PY'
import sys, numpy as np, soundfile as sf

threshold = float(sys.argv[1])
paths = sys.argv[2:]
sr = 48000

# 1. RMS po sekundi za svaki trag.
levels = []
for p in paths:
    f = sf.SoundFile(p)
    sr = f.samplerate
    vals = []
    while True:
        x = f.read(sr, dtype='float32')
        if len(x) == 0:
            break
        if x.ndim > 1:
            x = x.mean(axis=1)
        vals.append(np.sqrt((x ** 2).mean()))
    levels.append(20 * np.log10(np.array(vals) + 1e-12))

n = min(len(v) for v in levels)
levels = [v[:n] for v in levels]

# 2. Trag je "svoj" dok je jači od svakog drugog za >4 dB i iznad -60 dBFS.
own = []
for i, v in enumerate(levels):
    others = np.maximum.reduce([levels[j] for j in range(len(levels)) if j != i])
    own.append((v > -60) & (v > others + 4))

medians = []
for i, v in enumerate(levels):
    medians.append(float(np.median(v[own[i]])) if own[i].sum() > 30 else None)

# Nedovoljno vlastitog govora: taj trag se ne dira, jer bi mjerenje bilo nagađanje.
valid = [m for m in medians if m is not None]
target = float(np.mean(valid)) if valid else 0.0

# 3. Proximity efekt: udio 90-150 Hz prema 1-2 kHz, samo na vlastitom govoru.
def tilt(path, seconds):
    if len(seconds) == 0:
        return None
    f = sf.SoundFile(path)
    acc = None
    picks = seconds[:: max(1, len(seconds) // 40)][:40]
    for s in picks:
        f.seek(int(s) * sr)
        x = f.read(sr, dtype='float32')
        if len(x) < sr:
            continue
        if x.ndim > 1:
            x = x.mean(axis=1)
        X = np.abs(np.fft.rfft(x * np.hanning(len(x)))) ** 2
        acc = X if acc is None else acc + X
    if acc is None:
        return None
    freq = np.fft.rfftfreq(sr, 1 / sr)
    low = acc[(freq >= 90) & (freq < 150)].sum()
    mid = acc[(freq >= 1000) & (freq < 2000)].sum()
    return 10 * np.log10(low / mid) if mid > 0 else None

tilts = [tilt(p, np.where(own[i])[0]) for i, p in enumerate(paths)]
known = [t for t in tilts if t is not None]
# Referenca je NAJČIŠĆI trag, ne medijan. S dva mikrofona medijan je njihova
# sredina, pa bi se stvarna razlika od 10 dB prikazala kao ±5 i pala ispod praga —
# a trag koji nema proximity efekt ne treba nikakvu korekciju, on je mjerilo.
tilt_ref = float(min(known)) if known else 0.0

for i, p in enumerate(paths):
    gain = 0.0 if medians[i] is None else target - medians[i]
    speech = int(own[i].sum())
    print("GAIN\t%d\t%.2f\t%s\t%d" % (
        i, gain,
        "-" if medians[i] is None else "%.1f" % medians[i],
        speech,
    ))
    excess = 0.0 if tilts[i] is None else tilts[i] - tilt_ref
    print("TILT\t%d\t%.2f\t%s" % (
        i, excess,
        "yes" if excess > threshold else "no",
    ))
PY
)" || { echo "❌ Mjerenje nije uspjelo."; exit 1; }

GAINS=(); MEDIANS=(); SPEECH=(); EXCESS=(); PROX=()
while IFS=$'\t' read -r kind idx f3 f4 f5; do
    case "$kind" in
        GAIN) GAINS+=("$f3"); MEDIANS+=("$f4"); SPEECH+=("$f5") ;;
        TILT) EXCESS+=("$f3"); PROX+=("$f4") ;;
    esac
done <<< "$MEASURE"

echo "📐 Izmjereno:"
for i in "${!MICS[@]}"; do
    printf "   %-24s govori %5s s   razina %7s dBFS   pojačanje %+5.1f dB   bas višak %+5.1f dB%s\n" \
        "$(basename "${MICS[$i]}")" "${SPEECH[$i]}" "${MEDIANS[$i]}" "${GAINS[$i]}" "${EXCESS[$i]}" \
        "$([[ "${PROX[$i]}" == "yes" ]] && echo "  ← proximity")"
done
echo ""

# --- FILTARSKI LANAC ---
# Po tragu: rez ispod highpassa, korekcija proximityja ako je izmjeren, pojačanje
# koje izjednačava govornike. Zbroj ide bez normalizacije (normalize=0) jer bi
# inače amix stišao svaki trag proporcionalno broju ulaza.
FILTER=""
LABELS=""
for i in "${!MICS[@]}"; do
    chain="highpass=f=${HIGHPASS}:poles=2"
    if [[ "${PROX[$i]}" == "yes" ]]; then
        chain="${chain},equalizer=f=120:t=q:w=1.0:g=${PROXIMITY_DB}"
        if [[ "$PRESENCE_DB" != "0" ]]; then
            chain="${chain},treble=g=${PRESENCE_DB}:f=3500"
        fi
    fi
    chain="${chain},volume=${GAINS[$i]}dB"
    FILTER="${FILTER}[${i}:a]${chain}[m${i}];"
    LABELS="${LABELS}[m${i}]"
done
FILTER="${FILTER}${LABELS}amix=inputs=${#MICS[@]}:duration=longest:normalize=0[mix]"

echo "🧪 Filtar:"
echo "   $FILTER" | sed 's/;/;\n     /g'
echo ""

if [[ "$DRY_RUN" == true ]]; then
    echo "🧪 DRY RUN — ništa nije zapisano."
    exit 0
fi

INPUTS=()
for f in "${MICS[@]}"; do INPUTS+=(-i "$f"); done

echo "🎚️  Gradim miks…"
ffmpeg -v warning -stats "${INPUTS[@]}" \
    -filter_complex "$FILTER" -map "[mix]" \
    -ac 2 -c:a pcm_s24le -y "$OUTPUT" || { echo "❌ Miks nije napravljen."; exit 1; }

# NAMJERNO se ne dira razina. Miks izlazi na svojoj prirodnoj razini (ovdje ~-42
# LUFS jer su i sami mikrofoni snimljeni tiho), a pojačanje i limiter radi
# finalize_backup.sh — jedno pojačanje, jedan limiter, na jednom mjestu.
# Raniji pokušaj da se ovdje "napravi prostor" dizao je miks na fiksni cilj BEZ
# limitera i tvrdo ga klipao po cijeloj duljini.

echo ""
echo "✅ Miks: $OUTPUT"
ffmpeg -hide_banner -nostats -i "$OUTPUT" -af ebur128=peak=true:framelog=quiet -f null - 2>&1 \
    | grep -E "^ +(I|LRA|Peak):" | sed 's/^/   /'
echo ""
echo "Dalje:  ./scripts/finalize_backup.sh --audio \"$OUTPUT\" --camera <video> --output-dir <mapa> --loudness"
