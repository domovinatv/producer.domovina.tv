#!/bin/bash
#
# prepare_youtube.sh — od gotove snimke do metapodataka za YouTube upload.
#
# fetch.domovina.tv pipeline kreće tek NAKON što je epizoda na YouTubeu, a
# naslov, opis, tagovi i poglavlja trebaju POSTOJATI u trenutku uploada. Ova
# skripta zato vozi minimalni AI lanac unaprijed, na lokalnoj datoteci:
#
#   1. zvuk → 16 kHz mono WAV            (ffmpeg, lokalno)
#   2. WAV → transkript (.canary.srt)    (NVIDIA Canary 1B v2 na Modalu — isti
#                                         modal_canary/canary_modal.py koji
#                                         koristi fetch.domovina.tv; auth je
#                                         ~/.modal.toml, ništa se ne konfigurira)
#   2.5 govornici (.canary.diarized.srt) (pyannote lokalno na M-seriji, isti
#                                         colab_diarize/diarize_canary.py;
#                                         HF token se sam nađe u
#                                         ~/.cache/huggingface/token)
#   3. transkript → youtube_metadata.json (claude -p, headless; recept preuzet
#                                         iz summarize_gemini.js)
#
# Svaki korak je idempotentan: postoji li izlaz, korak se preskače. Ako
# diarizacija nije moguća (nema torcha ili tokena), nastavlja se bez oznaka
# govornika — metapodaci tada nastaju iz običnog transkripta. Puni katalog
# (summary, article, RAG) i dalje radi fetch pipeline nakon uploada, po
# YouTube ID-u.
#
set -uo pipefail

INPUT=""
OUTPUT_DIR=""
TITLE_HINT=""
MODEL="${CLAUDE_MODEL:-opus}"
EFFORT="${CLAUDE_EFFORT:-high}"
FETCH_REPO="${FETCH_REPO:-$HOME/git/domovinatv/fetch.domovina.tv}"
FORCE_METADATA=false
DIARIZE=true
DRY_RUN=false
MAX_HOURS=5          # osigurač: preko ovoga nešto nije u redu s ulazom

usage() {
    cat <<'EOF'
Upotreba:
  ./scripts/prepare_youtube.sh \
    --input <snimka.mov|mp4|wav> \
    [--output-dir <mapa>] [--title-hint "radni naslov"] \
    [--model opus] [--force-metadata] [--dry-run] [--help]

  --input           Finalna snimka (video ili sam zvuk, npr. mix.wav).
  --output-dir      Zadano: mapa u kojoj je ulazna datoteka.
  --title-hint      Radni naslov/tema epizode — pomaže modelu pri naslovima.
  --model           Claude model za metapodatke. Zadano: opus (CLAUDE_MODEL).
  --no-diarize      Preskoči pyannote diarizaciju (oznake govornika).
  --force-metadata  Ponovno generiraj metapodatke i ako već postoje.
  --dry-run         Ispiši što bi se radilo, bez pokretanja.

Okolina: FETCH_REPO (zadano ~/git/domovinatv/fetch.domovina.tv) mora sadržavati
modal_canary/canary_modal.py; `modal` i `claude` moraju biti na PATH-u.
EOF
    exit "${1:-1}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --input)          INPUT="${2:-}"; shift 2 ;;
        --output-dir)     OUTPUT_DIR="${2:-}"; shift 2 ;;
        --title-hint)     TITLE_HINT="${2:-}"; shift 2 ;;
        --model)          MODEL="${2:-}"; shift 2 ;;
        --no-diarize)     DIARIZE=false; shift ;;
        --force-metadata) FORCE_METADATA=true; shift ;;
        --dry-run)        DRY_RUN=true; shift ;;
        --help|-h)        usage 0 ;;
        *) echo "❌ Nepoznat argument: $1"; usage ;;
    esac
done

[[ -n "$INPUT" ]] || { echo "❌ --input je obavezan."; usage; }
[[ -f "$INPUT" ]] || { echo "❌ Datoteka ne postoji: $INPUT"; exit 1; }

for tool in ffmpeg ffprobe python3 modal claude; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "❌ Nedostaje '$tool'."
        case "$tool" in
            ffmpeg|ffprobe) echo "   brew install ffmpeg" ;;
            modal)          echo "   pip install modal && modal setup" ;;
            claude)         echo "   npm install -g @anthropic-ai/claude-code" ;;
        esac
        exit 1
    }
done

CANARY="$FETCH_REPO/modal_canary/canary_modal.py"
[[ -f "$CANARY" ]] || {
    echo "❌ Nema $CANARY"
    echo "   Postavi FETCH_REPO na lokaciju fetch.domovina.tv repozitorija."
    exit 1
}

[[ -n "$OUTPUT_DIR" ]] || OUTPUT_DIR="$(cd "$(dirname "$INPUT")" && pwd)"
mkdir -p "$OUTPUT_DIR"
BASE="$(basename "$INPUT")"; BASE="${BASE%.*}"; BASE="${BASE%_youtube}"; BASE="${BASE%_final}"
WAV="$OUTPUT_DIR/${BASE}.16k.wav"
SRT="$WAV.canary.srt"
DIARIZED_SRT="$WAV.canary.diarized.srt"
META_JSON="$OUTPUT_DIR/youtube_metadata.json"
META_TXT="$OUTPUT_DIR/youtube_description.txt"
LOG_FILE="$OUTPUT_DIR/prepare_youtube_$(date +%Y%m%d_%H%M%S).log"

DURATION="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$INPUT" | head -1)"
[[ -n "$DURATION" ]] || { echo "❌ Ne mogu pročitati trajanje ulaza."; exit 1; }
python3 -c "import sys; sys.exit(0 if $DURATION < $MAX_HOURS*3600 else 1)" || {
    echo "❌ Ulaz traje $(python3 -c "print(round($DURATION/3600,1))") h — preko osigurača od $MAX_HOURS h."
    exit 1
}

if [[ "$DRY_RUN" == true ]]; then
    echo "🧪 DRY RUN:"
    echo "   1.  WAV:         $WAV $([[ -f "$WAV" ]] && echo '(postoji, preskače se)')"
    echo "   2.  Transkript:  $SRT $([[ -f "$SRT" ]] && echo '(postoji, preskače se)')"
    if [[ "$DIARIZE" == true ]]; then
        echo "   2.5 Govornici:   $DIARIZED_SRT $([[ -f "$DIARIZED_SRT" ]] && echo '(postoji, preskače se)')"
    else
        echo "   2.5 Govornici:   preskočeno (--no-diarize)"
    fi
    echo "   3.  Metapodaci:  $META_JSON $([[ -f "$META_JSON" && "$FORCE_METADATA" != true ]] && echo '(postoji, preskače se)')"
    exit 0
fi

exec > >(tee "$LOG_FILE") 2>&1
echo "🎬 Ulaz: $INPUT ($(python3 -c "t=$DURATION; print('%d:%02d:%02d' % (t//3600,(t%3600)//60,t%60))"))"
echo "📝 Log:  $LOG_FILE"
echo ""

# --- 1. WAV 16 kHz mono ---
if [[ -f "$WAV" ]]; then
    echo "1️⃣  WAV postoji, preskačem: $WAV"
else
    echo "1️⃣  Izvlačim zvuk (16 kHz mono)…"
    ffmpeg -v error -i "$INPUT" -vn -ac 1 -ar 16000 -c:a pcm_s16le -y "$WAV" || {
        echo "❌ Izvlačenje zvuka nije uspjelo."; rm -f "$WAV"; exit 1
    }
    ls -lh "$WAV" | awk '{print "   " $5 "  " $9}'
fi
echo ""

# --- 2. TRANSKRIPCIJA NA MODALU ---
if [[ -f "$SRT" ]]; then
    echo "2️⃣  Transkript postoji, preskačem: $SRT"
else
    echo "2️⃣  Transkripcija na Modalu (Canary 1B v2, A100)…"
    echo "    prvi poziv uključuje cold start (~1 min); sama transkripcija je brža od stvarnog vremena"
    modal run "$CANARY" --wav "$WAV" || {
        echo "❌ Modal transkripcija nije uspjela. Provjeri 'modal token' i mrežu."
        exit 1
    }
    [[ -f "$SRT" ]] || { echo "❌ Modal je završio, ali nema $SRT"; exit 1; }
fi
SRT_LINES="$(wc -l < "$SRT" | tr -d ' ')"
echo "    transkript: $SRT_LINES redaka"
echo ""

# --- 2.5 GOVORNICI (pyannote, lokalno) ---
# Isti korak i ista skripta kao u fetch pipelineu (KORAK 6): pyannote na
# M-seriji, nikad na GPU cloudu — clustering je CPU-bound pa cloud ne pomaže.
# Token se ne prosljeđuje: diarize_canary.py ga sam nađe (env HF_TOKEN ili
# ~/.cache/huggingface/token). Neuspjeh nije fatalan — metapodaci mogu nastati
# i iz običnog transkripta, samo bez pouzdanog razlikovanja govornika.
META_SOURCE="$SRT"
if [[ "$DIARIZE" == true ]]; then
    if [[ -f "$DIARIZED_SRT" ]]; then
        echo "2️⃣½  Diarizacija postoji, preskačem: $DIARIZED_SRT"
        META_SOURCE="$DIARIZED_SRT"
    else
        # torch vidi samo python.org framework interpreter, ne nužno prvi
        # python3 na PATH-u — ista logika kao PYTHON_BIN u run_pipeline.sh.
        PYTHON_BIN=""
        for candidate in \
            /Library/Frameworks/Python.framework/Versions/3.13/bin/python3 \
            "$(command -v python3)"; do
            if [[ -x "$candidate" ]] && "$candidate" -c "import torch, pyannote.audio" 2>/dev/null; then
                PYTHON_BIN="$candidate"
                break
            fi
        done
        if [[ -z "$PYTHON_BIN" ]]; then
            echo "2️⃣½  ⚠️  Nijedan python ne vidi torch+pyannote — nastavljam bez govornika."
        else
            echo "2️⃣½  Diarizacija govornika (pyannote, lokalno; za sat materijala ~3-6 min)…"
            if "$PYTHON_BIN" "$FETCH_REPO/colab_diarize/diarize_canary.py" \
                --input-dir "$OUTPUT_DIR" --file "$WAV"; then
                if [[ -f "$DIARIZED_SRT" ]]; then
                    META_SOURCE="$DIARIZED_SRT"
                else
                    echo "    ⚠️  Diarizacija je prošla, ali nema $DIARIZED_SRT — nastavljam bez govornika."
                fi
            else
                echo "    ⚠️  Diarizacija nije uspjela — nastavljam bez govornika."
            fi
        fi
    fi
else
    echo "2️⃣½  Diarizacija preskočena (--no-diarize)."
fi
echo ""

# --- 3. METAPODACI ---
if [[ -f "$META_JSON" && "$FORCE_METADATA" != true ]]; then
    echo "3️⃣  Metapodaci postoje, preskačem (--force-metadata za ponovno): $META_JSON"
else
    echo "3️⃣  Generiram naslov, opis, poglavlja i tagove (claude -p, model: $MODEL)…"
    echo "    izvor: $(basename "$META_SOURCE")"

    HINT_BLOCK=""
    if [[ -n "$TITLE_HINT" ]]; then
        HINT_BLOCK="Autorov radni naslov/tema epizode: \"$TITLE_HINT\" — uzmi ga u obzir, ali ga smiješ poboljšati."
    fi

    # Pravila su preuzeta iz fetch.domovina.tv prompta protiv halucinacija
    # (summarize_gemini.js): imena samo iz transkripta, ništa iz općeg znanja.
    SYSTEM_PROMPT="Ti si urednik YouTube kanala DOMOVINA TV, hrvatskog podcasta o vjeri, društvu i kulturi. Dobit ćeš transkript epizode u SRT formatu (hrvatski, s vremenima). Na temelju ISKLJUČIVO sadržaja transkripta pripremi metapodatke za YouTube upload.

Odgovori SAMO valjanim JSON-om, bez markdown ograda i bez ikakvog teksta izvan JSON-a, točno ovog oblika:
{
  \"title_options\": [\"...\", \"...\", \"...\"],
  \"description\": \"...\",
  \"chapters\": [{\"time\": \"00:00\", \"topic\": \"...\"}],
  \"tags\": [\"...\"]
}

Pravila:
- title_options: 3 prijedloga naslova na hrvatskom, svaki do 95 znakova, konkretni i bez clickbaita bez pokrića; najbolji prvi.
- description: 2-3 rečenice sažetka (najvažnije u prvu rečenicu — samo se ona vidi prije 'Prikaži više'), zatim prazan redak, zatim redak 'Poglavlja:' pa po jedan redak po poglavlju u obliku 'MM:SS Naziv' (odnosno 'H:MM:SS' nakon prvog sata), zatim prazan redak i 3-5 hashtagova. Ukupno do 4500 znakova.
- chapters: ista poglavlja kao u opisu, kronološki. Prvo OBAVEZNO počinje na 00:00, najmanje 3 poglavlja, svako traje najmanje 10 sekundi. Granice postavi na prirodne promjene teme, nikad usred misli; vremena moraju odgovarati SRT vremenima stvarnog početka teme.
- tags: 10-20 pojmova (osobe, mjesta i teme IZ transkripta, plus 'podcast', 'hrvatski podcast', 'domovina'); svi zajedno do 480 znakova.
- Imena osoba SAMO ako su izgovorena u transkriptu. Ako ime nije izrečeno, koristi ulogu ('voditelj', 'gošća'). Ne nadopunjuj ništa iz općeg znanja i ne izmišljaj brojke ni citate.
- Ako transkript ima oznake [SPEAKER_00], [SPEAKER_01]…, koristi ih da razlikuješ tko što govori (voditelj postavlja pitanja, gost odgovara). Ime pripiši govorniku samo ako ga netko u transkriptu izravno oslovi ili se sam predstavi; oznake SPEAKER_XX nikad ne ispisuj u naslovu, opisu ni tagovima.
$HINT_BLOCK"

    # Neutralan cwd: pokretanje iz repozitorija bi u kontekst povuklo CLAUDE.md.
    # SRT ide na stdin (100-500 KB ne stane u argv). --tools '' jer alati ovdje
    # samo troše kontekst; --max-turns 1 jer je ovo jedan odgovor, ne agent.
    NEUTRAL_DIR="$(mktemp -d "${TMPDIR:-/tmp}/domovina_yt.XXXXXX")"
    trap 'rm -rf "$NEUTRAL_DIR"' EXIT
    RAW_JSON="$NEUTRAL_DIR/claude_envelope.json"

    (cd "$NEUTRAL_DIR" && claude -p \
        --model "$MODEL" --effort "$EFFORT" \
        --output-format json \
        --setting-sources "" --strict-mcp-config \
        --max-turns 1 --tools "" \
        --system-prompt "$SYSTEM_PROMPT" \
        < "$META_SOURCE" > "$RAW_JSON") || {
        echo "❌ claude -p nije uspio. Provjeri prijavu (claude login) i model '$MODEL'."
        exit 1
    }

    python3 - "$RAW_JSON" "$META_JSON" "$META_TXT" <<'PY' || exit 1
import json, re, sys

envelope_path, meta_path, txt_path = sys.argv[1:4]
with open(envelope_path) as handle:
    envelope = json.load(handle)

text = envelope.get("result", "")
if not text:
    sys.exit("❌ Prazan odgovor modela (envelope bez 'result').")

# Model je zamoljen za čisti JSON, ali ograde se ipak znaju pojaviti.
match = re.search(r"\{.*\}", text, re.DOTALL)
if not match:
    sys.exit("❌ U odgovoru nema JSON objekta:\n" + text[:400])
data = json.loads(match.group(0))

problems = []
titles = data.get("title_options") or []
if not titles:
    problems.append("nema title_options")
for title in titles:
    if len(title) > 100:
        problems.append("naslov preko 100 znakova: %r" % title[:60])

def to_seconds(value):
    total = 0
    for part in str(value).strip().split(":"):
        total = total * 60 + int(part)
    return total

chapters = data.get("chapters") or []
if len(chapters) < 3:
    problems.append("manje od 3 poglavlja")
try:
    if chapters and to_seconds(chapters[0].get("time", "")) != 0:
        problems.append("prvo poglavlje ne počinje na 00:00 (%s)" % chapters[0].get("time"))
    times = [to_seconds(c.get("time", "")) for c in chapters]
    if times != sorted(times):
        problems.append("poglavlja nisu kronološka")
except ValueError:
    problems.append("vrijeme poglavlja nije u obliku MM:SS / H:MM:SS")

tags = data.get("tags") or []
if len(",".join(tags)) > 500:
    problems.append("tagovi zajedno preko 500 znakova")

description = data.get("description") or ""
if not description:
    problems.append("nema description")
if len(description) > 5000:
    problems.append("opis preko YouTube limita od 5000 znakova")

if problems:
    sys.exit("❌ Metapodaci ne prolaze provjeru: " + "; ".join(problems))

with open(meta_path, "w") as handle:
    json.dump(data, handle, ensure_ascii=False, indent=2)

# Tekstualna varijanta spremna za copy/paste u YouTube Studio.
lines = [
    "NASLOV (opcije):",
    *["  %d. %s" % (i + 1, t) for i, t in enumerate(titles)],
    "",
    "OPIS:",
    description,
    "",
    "TAGOVI (copy/paste):",
    ", ".join(tags),
]
with open(txt_path, "w") as handle:
    handle.write("\n".join(lines) + "\n")

print("   naslova: %d   poglavlja: %d   tagova: %d   opis: %d znakova"
      % (len(titles), len(chapters), len(tags), len(description)))
PY
fi
echo ""

echo "✅ Spremno za upload:"
echo "   $META_JSON"
echo "   $META_TXT"
echo ""
echo "── Pregled ──"
python3 - "$META_JSON" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
print("Naslov 1:", data["title_options"][0])
for chapter in data["chapters"][:6]:
    print("  %s  %s" % (chapter["time"], chapter["topic"]))
if len(data["chapters"]) > 6:
    print("  … (+%d)" % (len(data["chapters"]) - 6))
PY
echo ""
echo "🏁 Gotovo."
osascript -e 'display notification "YouTube metapodaci su spremni." with title "DOMOVINA Studio"' 2>/dev/null
