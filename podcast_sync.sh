#!/bin/bash

# Prekini skriptu ako se dogodi greška
set -e

echo "🎙️ Pokrećem automatiziranu sinkronizaciju podcasta..."

# --- 0. PROVJERA POTREBNIH ALATA ---
for cmd in ffmpeg ffprobe afinfo audio-offset-finder; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "❌ '$cmd' nije instaliran!"; exit 1; }
done

# --- 1. INICIJALIZACIJA VARIJABLI ---
RIVERSIDE_WAV=""
RODE_MIC_WAV=""
RODE_STEREO_WAV=""
FINAL_OUT_DIR=""
LUMIX_VIDS=()
DRY_RUN=false

# --- 2. PARSIRANJE IMENOVANIH ARGUMENATA ---
while [[ $# -gt 0 ]]; do
  case $1 in
    --riverside-speaker-1) RIVERSIDE_WAV="$2"; shift 2 ;;
    --rode-mic-speaker-1) RODE_MIC_WAV="$2"; shift 2 ;;
    --rode-stereo-all-tracks) RODE_STEREO_WAV="$2"; shift 2 ;;
    --output-dir) FINAL_OUT_DIR="$2"; shift 2 ;;
    --lumix) LUMIX_VIDS+=("$2"); shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --help|-h)
      echo "Korištenje:"
      echo "$0 \\"
      echo "  --riverside-speaker-1 <putanja_do_wav> \\"
      echo "  --rode-mic-speaker-1 <putanja_do_wav> \\"
      echo "  --rode-stereo-all-tracks <putanja_do_wav> \\"
      echo "  --output-dir <putanja_do_foldera> \\"
      echo "  --lumix <putanja_do_videa_1> \\"
      echo "  [--lumix <putanja_do_videa_2> ...]"
      echo "  [--dry-run]  (samo ispiši izračunate offsete bez izvršavanja)"
      echo "  [--help|-h]"
      exit 0
      ;;
    *) echo "❌ Nepoznat argument: $1"; exit 1 ;;
  esac
done

# --- 3. PROVJERA JESU LI SVI ARGUMENTI UNESENI ---
if [[ -z "$RIVERSIDE_WAV" || -z "$RODE_MIC_WAV" || -z "$RODE_STEREO_WAV" || -z "$FINAL_OUT_DIR" || ${#LUMIX_VIDS[@]} -eq 0 ]]; then
    echo "❌ Greška: Nedostaju obavezni argumenti!"
    echo "Korištenje:"
    echo "$0 \\"
    echo "  --riverside-speaker-1 <putanja_do_wav> \\"
    echo "  --rode-mic-speaker-1 <putanja_do_wav> \\"
    echo "  --rode-stereo-all-tracks <putanja_do_wav> \\"
    echo "  --output-dir <putanja_do_foldera> \\"
    echo "  --lumix <putanja_do_videa_1> \\"
    echo "  [--lumix <putanja_do_videa_2> ...]"
    exit 1
fi

# --- 3b. PROVJERA DA ULAZNE DATOTEKE POSTOJE ---
for f in "$RIVERSIDE_WAV" "$RODE_MIC_WAV" "$RODE_STEREO_WAV" "${LUMIX_VIDS[@]}"; do
  [[ -f "$f" ]] || { echo "❌ Datoteka ne postoji: $f"; exit 1; }
done

echo "✅ Učitano Lumix datoteka: ${#LUMIX_VIDS[@]}"

# --- 3c. CLEANUP TRAP (čisti privremene datoteke čak i ako skripta padne) ---
LUMIX_AUDIO_TEMP="/tmp/lumix_audio_temp.wav"
CONCAT_TXT="/tmp/spajanje.txt"
SAFE_RODE_MIC=""
cleanup() {
  rm -f "$LUMIX_AUDIO_TEMP" "$CONCAT_TXT"
  [[ -n "$SAFE_RODE_MIC" && "$RODE_MIC_WAV" != "$SAFE_RODE_MIC" ]] && rm -f "$SAFE_RODE_MIC"
}
trap cleanup EXIT

# --- 3d. LOGGING U DATOTEKU ---
mkdir -p "$FINAL_OUT_DIR"
LOG_FILE="$FINAL_OUT_DIR/sync_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee "$LOG_FILE") 2>&1

# --- 4. RJEŠAVANJE RAZMAKA U NAZIVU RODE MICA (snake_case kopija) ---
DIRNAME=$(dirname "$RODE_MIC_WAV")
BASENAME=$(basename "$RODE_MIC_WAV")
SAFE_BASENAME=$(echo "$BASENAME" | tr ' ' '_')
SAFE_RODE_MIC="$DIRNAME/$SAFE_BASENAME"  # trap cleanup koristi ovu varijablu

if [ "$RODE_MIC_WAV" != "$SAFE_RODE_MIC" ]; then
    echo "🔄 Radim snake_case kopiju Rode Mic datoteke: $SAFE_BASENAME"
    cp "$RODE_MIC_WAV" "$SAFE_RODE_MIC"
fi

# --- 5. IZRAČUN TRAJANJA RIVERSIDE SNIMKE ---
echo "⏱️ Računam trajanje Riverside snimke..."
DURATION=$(afinfo "$RIVERSIDE_WAV" | awk '/estimated duration/ {print $3}')
echo "✅ Trajanje: $DURATION sekundi"

# --- 6. TRAŽENJE AUDIO OFFSETA ---
echo "🔎 Tražim audio offset između Riverside i Rode snimke..."
RODE_OFFSET=$(audio-offset-finder --find-offset-of "$RIVERSIDE_WAV" --within "$SAFE_RODE_MIC" | awk '/Offset:/ {print $2}')
echo "✅ Audio offset pronađen na: $RODE_OFFSET sekundi"

# --- 7. REZANJE SAVRŠENOG ZVUKA (StereoMix_synced.wav) ---
SYNCED_STEREO="${RODE_STEREO_WAV%.*}_synced.wav"
echo "✂️ Režem StereoMix na točnu duljinu..."
ffmpeg -v warning -ss "$RODE_OFFSET" -i "$RODE_STEREO_WAV" -t "$DURATION" -c copy -y "$SYNCED_STEREO"
echo "✅ Savršeni audio kreiran: $SYNCED_STEREO"

# --- 8. EKSTRAKCIJA ZVUKA IZ KAMERE (Samo iz prvog videa) ---
PRVI_LUMIX="${LUMIX_VIDS[0]}"
echo "🎵 Izvlačim privremeni zvuk iz prvog Lumix videa..."
ffmpeg -v warning -i "$PRVI_LUMIX" -vn -acodec pcm_s16le -y "$LUMIX_AUDIO_TEMP"

# --- 9. TRAŽENJE VIDEO OFFSETA ---
echo "🎬 Tražim video offset (Zlatni Audio vs Lumix Audio)..."
VID_OFFSET=$(audio-offset-finder --find-offset-of "$SYNCED_STEREO" --within "$LUMIX_AUDIO_TEMP" | awk '/Offset:/ {print $2}')
echo "✅ Video inpoint postavljen na: $VID_OFFSET sekundi"

# --- DRY RUN: Ispis rezultata i izlaz ---
if [ "$DRY_RUN" = true ]; then
    echo ""
    echo "🧪 DRY RUN — Izračunati parametri:"
    echo "   Trajanje Riverside snimke: $DURATION s"
    echo "   Audio offset (Rode):      $RODE_OFFSET s"
    echo "   Video offset (Lumix):     $VID_OFFSET s"
    echo "   Synced audio:             $SYNCED_STEREO"
    echo "   Lumix datoteke:           ${LUMIX_VIDS[*]}"
    echo "   Output direktorij:        $FINAL_OUT_DIR"
    echo ""
    echo "ℹ️  Pokreni bez --dry-run za izvršavanje."
    exit 0
fi

# --- 10. PRIPREMA SKRIPTE ZA SPAJANJE (Podrška za N datoteka) ---
echo "📝 Pripremam skriptu za spajanje..."

echo "file '$PRVI_LUMIX'" > "$CONCAT_TXT"
echo "inpoint $VID_OFFSET" >> "$CONCAT_TXT"

if [ ${#LUMIX_VIDS[@]} -gt 1 ]; then
    for (( i=1; i<${#LUMIX_VIDS[@]}; i++ )); do
        echo "file '${LUMIX_VIDS[$i]}'" >> "$CONCAT_TXT"
    done
fi

# --- 11. PROVJERA SLOBODNOG PROSTORA NA DISKU ---
AVAILABLE_KB=$(df -k "$FINAL_OUT_DIR" | awk 'NR==2 {print $4}')
AVAILABLE_GB=$(( AVAILABLE_KB / 1024 / 1024 ))
echo "💾 Slobodan prostor na output disku: ${AVAILABLE_GB} GB"
if [ "$AVAILABLE_KB" -lt 10485760 ]; then
    echo "⚠️  Upozorenje: Manje od 10 GB slobodnog prostora na disku!"
fi

# --- 12. FINALNO SPAJANJE VIDEA I ZVUKA ---
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
FINAL_VIDEO="$FINAL_OUT_DIR/Podcast_${TIMESTAMP}.mov"

echo "🚀 Spajam konačni video bez renderiranja (Ovo može potrajati)..."
ffmpeg -v warning -f concat -safe 0 -i "$CONCAT_TXT" -i "$SYNCED_STEREO" -map 0:v -map 1:a -c copy -shortest -y "$FINAL_VIDEO"

echo "🎉 GOTOVO! Tvoj video je spreman na: $FINAL_VIDEO"

# --- 13. NOTIFIKACIJA ---
# Zvučni signal i macOS notifikacija
afplay /System/Library/Sounds/Glass.aiff &
osascript -e 'display notification "Spajanje i sinkronizacija su završeni!" with title "Podcast Producer"'
