#!/usr/bin/env bash
# Deterministic plan of the synthetic fleet: one "name visibility defaultBranch" line per repository, mixing the
# default branch names of the organisation and keeping most repositories private, as they are there.
set -euo pipefail

count=${1:-}

if ! [[ $count =~ ^[0-9]+$ ]]; then
    echo "usage: fleetPlan.sh <count between 1 and 100>" >&2
    exit 2
fi

# A leading zero would be read as octal by the arithmetic below.
count=$((10#$count))
if [ "$count" -lt 1 ] || [ "$count" -gt 100 ]; then
    echo "usage: fleetPlan.sh <count between 1 and 100>" >&2
    exit 2
fi

defaults=(development master main v2)

for ((i = 1; i <= count; i++)); do
    visibility=private
    [ $((i % 5)) -ne 0 ] || visibility=public
    printf 'test-fleet-%02d %s %s\n' "$i" "$visibility" "${defaults[$(((i - 1) % 4))]}"
done
