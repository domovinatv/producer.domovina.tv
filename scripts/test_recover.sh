#!/bin/bash
#
# test_recover.sh — provjerava alat za oporavak sesije iz R2.
#
# Pokriva potpisivanje (protiv AWS SigV4 test vektora) i spajanje segmenata na
# stvarnim fMP4 i WAV datotekama. Ne dira mrežu.
#
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v ffmpeg >/dev/null 2>&1 || { echo "❌ ffmpeg nije pronađen (brew install ffmpeg)"; exit 1; }
exec python3 "$REPO_ROOT/tests/recover/test_recover.py"
