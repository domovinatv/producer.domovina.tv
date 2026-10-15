#!/bin/bash
#
# test_calibration.sh — provjerava kalibraciju pljeskom.
#
# Gradi sintetički klip u kojem su klik u zvuku i blic u slici na poznatim,
# namjerno različitim trenucima, pa provjeri da mjerenje vrati točno tu razliku.
# Ljudski korak (odabir framea kontakta) zamjenjuje detektor skoka svjetline, pa
# su detekcija zvuka, izvlačenje frameova i aritmetika sve stvarni kod.
#
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v ffmpeg >/dev/null 2>&1 || { echo "❌ ffmpeg nije pronađen (brew install ffmpeg)"; exit 1; }
command -v swiftc >/dev/null 2>&1 || { echo "❌ swiftc nije pronađen"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Klik točno na t = 5.000 s, uz tihi ton kao podlogu.
EXPR='0.02*sin(2*PI*220*t)+0.9*sin(2*PI*3000*t)*if(gt(t\,5)\,exp(-150*(t-5))\,0)'
ffmpeg -v error -f lavfi -i "aevalsrc=${EXPR}:d=10:s=48000" -ac 1 -c:a pcm_s16le -y "$WORK/click.wav"
# Blic jedan frame, točno na t = 4.960 s (frame 248 pri 50 fps).
ffmpeg -v error -f lavfi -i "color=c=black:s=320x180:r=50:d=10" \
    -vf "drawbox=x=0:y=0:w=iw:h=ih:color=white@1:t=fill:enable='between(t,4.96,4.979)'" \
    -c:v libx264 -preset ultrafast -pix_fmt yuv420p -y "$WORK/flash.mp4"
ffmpeg -v error -i "$WORK/flash.mp4" -i "$WORK/click.wav" -map 0:v:0 -map 1:a:0 \
    -c:v copy -c:a aac -shortest -y "$WORK/clip.mov"

swiftc -O -target arm64-apple-macosx14.0 -o "$WORK/test" \
    "$REPO_ROOT/PodcastProducer/Sources/Capture/ClapCalibrator.swift" \
    "$REPO_ROOT/tests/calibration/main.swift"

"$WORK/test" "$WORK/clip.mov"
