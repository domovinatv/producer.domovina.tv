#!/bin/bash
#
# test_finalize.sh — provjerava finalize_session.sh na sintetičkoj sesiji.
#
# Traži da poravnani tragovi budu točni DO UZORKA, i pokriva tri stvari koje su
# se u razvoju stvarno pokvarile: odbacivanje prve točke trajektorije drifta
# (frameCount 0 je falsy), padding koji aresample doda na kraj svakog dijela, i
# neprimjenjivanje izmjerenog pomaka mikrofon→slika.
#
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v ffmpeg >/dev/null 2>&1 || { echo "❌ ffmpeg nije pronađen (brew install ffmpeg)"; exit 1; }
exec python3 "$REPO_ROOT/tests/finalize/test_finalize.py"
