#!/bin/bash
#
# test.sh — pokreće sve testove koji ne zahtijevaju priključen hardver.
#
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATUS=0

for suite in test_core.sh test_sigv4.sh test_recover.sh; do
    echo "───────────────────────────────────────────"
    echo "▶ $suite"
    echo "───────────────────────────────────────────"
    "$REPO_ROOT/scripts/$suite" || STATUS=1
    echo ""
done

echo "───────────────────────────────────────────"
if [[ $STATUS -eq 0 ]]; then
    echo "✅ Svi testovi prošli."
else
    echo "🛑 Neki testovi nisu prošli."
fi
exit $STATUS
