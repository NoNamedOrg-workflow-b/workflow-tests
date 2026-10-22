#!/usr/bin/env bash
# Prints the org of a sandbox environment file and refuses any other environment, so the seeding tools can never be
# pointed at a real organisation by choosing a different file.
set -euo pipefail

envFile=${1:-}

if [ ! -f "$envFile" ]; then
    echo "environment file not found: $envFile" >&2
    exit 2
fi

# A second JSON document could hide a different org behind a harmless first one.
if [ "$(jq -s 'length' "$envFile" 2> /dev/null)" != "1" ] || ! jq -e '.environment == "sandbox"' "$envFile" > /dev/null 2>&1; then
    echo "$envFile is not a single sandbox environment; seeding is only allowed there" >&2
    exit 2
fi

org=$(jq -er '.org | strings' "$envFile" 2> /dev/null) || org=""
if ! [[ $org =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]]; then
    echo "invalid environment file: $envFile" >&2
    exit 2
fi

echo "$org"
