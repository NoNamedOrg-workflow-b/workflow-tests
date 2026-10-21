#!/usr/bin/env bash
# Aborts unless every fetch and push URL of origin is an HTTPS URL of the test org: a push over SSH uses the
# personal key, which reaches organizations outside the sandbox.
set -euo pipefail

envFile=${1:-"$(dirname "$0")/../envs/sandbox.json"}

if [ ! -f "$envFile" ]; then
    echo "environment file not found: $envFile" >&2
    exit 2
fi

if ! command -v jq > /dev/null; then
    echo "jq is required to read $envFile" >&2
    exit 2
fi

if ! org=$(jq -er '.org | strings' "$envFile" 2> /dev/null) || ! [[ $org =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]]; then
    echo "invalid environment file: no org with a plain name in $envFile" >&2
    exit 2
fi

# An allowlist of the whole URL rejects dot segments, extra slashes, backslashes, encodings, userinfo and
# whitespace in one rule, instead of chasing each trick a client might normalise into another repository.
pattern="^https://github\\.com/$org/([A-Za-z0-9._-]+)\$"

acceptable() {
    [[ $1 =~ $pattern ]] || return 1
    [[ ${BASH_REMATCH[1]} =~ ^\.+$ ]] && return 1
    return 0
}

urls=$(
    git remote get-url --all origin 2> /dev/null || true
    git remote get-url --push --all origin 2> /dev/null || true
)

if [ -z "$urls" ]; then
    echo "origin is missing: not an HTTPS URL of $org" >&2
    exit 2
fi

# The URL is never printed: a token embedded in a remote would reach the logs.
while IFS= read -r url; do
    acceptable "$url" && continue
    echo "a fetch or push URL of origin is not an HTTPS URL of $org" >&2
    exit 2
done <<< "$urls"
