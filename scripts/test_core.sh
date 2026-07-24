#!/bin/bash
#
# test_core.sh — testira logiku koja se ne može provjeriti gledanjem UI-ja:
# host clock aritmetiku, mjerače razine, korelator za lip sync (s poznatim
# umjetnim pomacima), manifest i imenovanje mapa sesija.
#
# Ne dira hardver, ne otvara prozore — sigurno se pokreće i tijekom montaže.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCES="$REPO_ROOT/PodcastProducer/Sources"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

command -v swiftc >/dev/null 2>&1 || { echo "❌ swiftc nije pronađen."; exit 1; }

swiftc -O -o "$BUILD_DIR/core" \
    "$SOURCES/Core/HostClock.swift" \
    "$SOURCES/Core/LevelMeter.swift" \
    "$SOURCES/Capture/LipSyncMonitor.swift" \
    "$SOURCES/Capture/AudioDeviceEnumerator.swift" \
    "$SOURCES/Session/SessionManifest.swift" \
    "$SOURCES/Session/SessionStore.swift" \
    "$REPO_ROOT/tests/core/main.swift"

"$BUILD_DIR/core"
