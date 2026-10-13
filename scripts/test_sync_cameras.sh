#!/bin/bash
#
# test_sync_cameras.sh — sync_cameras.py na sintetičkim kamerama (pomak, drift, jeka, bljesak).
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 "$REPO_ROOT/tests/sync_cameras/test_sync_cameras.py"
exec python3 "$REPO_ROOT/tests/sync_cameras/test_finalize_cameras.py"
