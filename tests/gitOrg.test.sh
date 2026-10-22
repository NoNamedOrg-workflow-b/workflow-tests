#!/usr/bin/env bash
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
gitOrg="$root/tools/gitOrg.sh"
bashBin=${BASH_BIN:-bash}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
passed=0
failed=0

echo '{"org":"NoNamedOrg-workflow"}' > "$work/env.json"

ok() {
    passed=$((passed + 1))
    echo "PASS $1"
}

bad() {
    failed=$((failed + 1))
    echo "FAIL $1"
    [ -z "${2:-}" ] || echo "$2" | sed 's/^/    /'
}

repoWithRemote() {
    git init -q -b main "$work/$1"
    [ -z "${2:-}" ] || git -C "$work/$1" remote add origin "$2"
    echo "$work/$1"
}

repo=$(repoWithRemote ok "https://github.com/NoNamedOrg-workflow/x.git")

output=$(cd "$repo" && ENV_FILE="$work/env.json" env -u GH_TOKEN "$bashBin" "$gitOrg" push origin main 2>&1)
[ $? -eq 2 ] && echo "$output" | grep -q "GH_TOKEN" && ok "a missing token exits 2" || bad "a missing token was accepted" "$output"

repo=$(repoWithRemote ssh "git@github.com:NoNamedOrg-workflow/x.git")
output=$(cd "$repo" && ENV_FILE="$work/env.json" GH_TOKEN=t "$bashBin" "$gitOrg" push origin main 2>&1)
[ $? -eq 2 ] && echo "$output" | grep -q "not an HTTPS URL" && ok "T-R33-d an SSH remote is refused before git runs" || bad "an SSH remote was accepted" "$output"

repo=$(repoWithRemote other "https://github.com/otherOrg/x.git")
output=$(cd "$repo" && ENV_FILE="$work/env.json" GH_TOKEN=t "$bashBin" "$gitOrg" push origin main 2>&1)
[ $? -eq 2 ] && ok "T-R33-d a remote of another org is refused" || bad "a remote of another org was accepted" "$output"

repo=$(repoWithRemote ok2 "https://github.com/NoNamedOrg-workflow/x.git")
output=$(cd "$repo" && ENV_FILE="$work/env.json" GH_TOKEN=secret-from-env "$bashBin" "$gitOrg" credential fill <<< $'protocol=https\nhost=github.com\n' 2>&1)
echo "$output" | grep -q "^password=secret-from-env$" && ok "the credential helper answers with the token from the environment" || bad "the credential helper did not answer with the token" "$output"
echo "$output" | grep -q "^username=x-access-token$" && ok "the helper uses the access-token username" || bad "unexpected username"

repo=$(repoWithRemote scope "https://github.com/NoNamedOrg-workflow/x.git")
output=$(cd "$repo" && ENV_FILE="$work/env.json" GH_TOKEN=t "$bashBin" "$gitOrg" ls-remote http://127.0.0.1:9/x.git 2>&1)
[ $? -eq 2 ] && ok "T-R33-d a URL argument is refused: only origin is allowed" || bad "a URL argument was forwarded" "$output"

output=$(cd "$repo" && ENV_FILE="$work/env.json" GH_TOKEN=t "$bashBin" "$gitOrg" push other main 2>&1)
[ $? -eq 2 ] && ok "T-R33-d another remote name is refused" || bad "another remote was forwarded" "$output"

output=$(cd "$repo" && ENV_FILE="$work/env.json" GH_TOKEN=secret "$bashBin" "$gitOrg" credential fill <<< $'protocol=https\nhost=evil.example\n' 2>&1)
echo "$output" | grep -q "password=secret" && bad "T-R33-d the token was handed to another host" "$output" || ok "T-R33-d the token is only given to github.com"

output=$(cd "$repo" && ENV_FILE="$work/env.json" GH_TOKEN='a  b' "$bashBin" "$gitOrg" credential fill <<< $'protocol=https\nhost=github.com\n' 2>&1)
echo "$output" | grep -q "^password=a  b$" && ok "the token is passed on unchanged, spaces included" || bad "the token was altered" "$output"

output=$(cd "$repo" && ENV_FILE="$work/env.json" GH_TOKEN=t "$bashBin" "$gitOrg" rev-parse --git-dir 2>&1)
[ $? -eq 2 ] && echo "$output" | grep -q "push, fetch, pull, ls-remote or credential only" && ok "any other git subcommand is refused" || bad "an arbitrary subcommand was forwarded" "$output"

echo "gitOrg: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
