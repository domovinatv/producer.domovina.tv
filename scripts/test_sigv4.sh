#!/bin/bash
#
# test_sigv4.sh — provjerava potpisivanje R2 zahtjeva protiv AWS-ovih objavljenih
# test vektora za S3 Signature V4.
#
# Zašto postoji: pogrešan potpis se ne vidi dok ne padne pravi upload, a tada je
# snimanje već u tijeku. Ovaj test se izvodi u sekundi i pokriva canonical URI,
# sortiranje query parametara i HMAC lanac.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

command -v swiftc >/dev/null 2>&1 || { echo "❌ swiftc nije pronađen."; exit 1; }

swiftc -O -o "$BUILD_DIR/sigv4_vectors" \
    "$REPO_ROOT/PodcastProducer/Sources/Upload/SigV4.swift" \
    "$REPO_ROOT/tests/sigv4_vectors/main.swift"

"$BUILD_DIR/sigv4_vectors"
