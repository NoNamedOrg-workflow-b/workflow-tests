#!/usr/bin/env bash
# Runs git with the token as the HTTPS credential, and only after the remote is proven to belong to the test org: a
# push over SSH would use the personal key, which reaches organizations outside the sandbox. Only origin can be
# addressed and the token is only offered to github.com, so a URL or another remote name cannot receive it.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
envFile=${ENV_FILE:-"$here/../envs/sandbox.json"}

if [ -z "${GH_TOKEN:-}" ]; then
    echo "GH_TOKEN is required" >&2
    exit 2
fi

case "${1:-}" in
    push | fetch | pull | ls-remote)
        if [ "${2:-}" != "origin" ]; then
            echo "gitOrg only talks to origin" >&2
            exit 2
        fi
        ;;
    credential) ;;
    *)
        echo "gitOrg runs push, fetch, pull, ls-remote or credential only" >&2
        exit 2
        ;;
esac

"$here/assertRemote.sh" "$envFile"

# The helper reads the token from its own environment, so it never appears in an argument list.
GIT_TERMINAL_PROMPT=0 exec git -c credential.helper= \
    -c 'credential.https://github.com.helper=!f() { echo username=x-access-token; echo "password=$GH_TOKEN"; }; f' "$@"
