#!/usr/bin/env bash
set -uo pipefail

root=$(cd "$(dirname "$0")" && pwd)
failures=0

for suite in "$root"/*.test.sh; do
    echo "== $(basename "$suite")"
    "${BASH_BIN:-bash}" "$suite" || failures=$((failures + 1))
done

if [ "$failures" -ne 0 ]; then
    echo "$failures suite(s) failed"
    exit 1
fi
echo "all suites passed"
