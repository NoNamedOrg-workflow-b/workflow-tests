#!/usr/bin/env bash
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
script="$root/tools/assertRemote.sh"
bashBin=${BASH_BIN:-bash}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
passed=0
failed=0

echo '{"org":"NoNamedOrg-workflow"}' > "$work/env.json"

repoWithRemote() {
    local dir="$work/$1"
    git init -q -b main "$dir"
    [ -n "${2:-}" ] && git -C "$dir" remote add origin "$2"
    echo "$dir"
}

runAssert() {
    local repo=$1
    shift
    output=$(cd "$repo" && "$bashBin" "$script" "$@" 2>&1)
    status=$?
}

expect() {
    local name=$1 wantStatus=$2 wantPattern=$3
    if [ "$status" -eq "$wantStatus" ] && echo "$output" | grep -q -- "$wantPattern"; then
        passed=$((passed + 1))
        echo "PASS $name"
        return 0
    fi
    failed=$((failed + 1))
    echo "FAIL $name (exit $status, wanted $wantStatus matching '$wantPattern')"
    echo "$output" | sed 's/^/    /'
}

repo=$(repoWithRemote ok "https://github.com/NoNamedOrg-workflow/workflow-tests.git")
runAssert "$repo" "$work/env.json"
expect "T-R33-d HTTPS remote of the test org is accepted" 0 ""

repo=$(repoWithRemote ssh "git@github.com:NoNamedOrg-workflow/workflow-tests.git")
runAssert "$repo" "$work/env.json"
expect "T-R33-d SSH remote is rejected" 2 "not an HTTPS URL"

repo=$(repoWithRemote other "https://github.com/otherOrg/x.git")
runAssert "$repo" "$work/env.json"
expect "T-R33-d HTTPS remote of another org is rejected" 2 "not an HTTPS URL"

repo=$(repoWithRemote lookalike "https://github.com/NoNamedOrg-workflow-evil/x.git")
runAssert "$repo" "$work/env.json"
expect "T-R33-d org name that only starts like the test org is rejected" 2 "not an HTTPS URL"

repo=$(repoWithRemote noremote "")
runAssert "$repo" "$work/env.json"
expect "T-R33-d missing remote is rejected" 2 "not an HTTPS URL"

repo=$(repoWithRemote noenv "https://github.com/NoNamedOrg-workflow/workflow-tests.git")
runAssert "$repo" "$work/missing.json"
expect "T-R33-d missing environment file exits 2" 2 "environment file not found"

repo=$(repoWithRemote pushurl "https://github.com/NoNamedOrg-workflow/workflow-tests.git")
git -C "$repo" remote set-url --push origin "git@github.com:otherOrg/x.git"
runAssert "$repo" "$work/env.json"
expect "T-R33-d a push URL that is not HTTPS of the org is rejected" 2 "not an HTTPS URL"

repo=$(repoWithRemote insteadof "https://github.com/NoNamedOrg-workflow/workflow-tests.git")
git -C "$repo" config url."git@github.com:".pushInsteadOf "https://github.com/"
runAssert "$repo" "$work/env.json"
expect "T-R33-d a pushInsteadOf rewrite to SSH is rejected" 2 "not an HTTPS URL"

repo=$(repoWithRemote creds "https://user:SECRET123@github.com/NoNamedOrg-workflow/workflow-tests.git")
runAssert "$repo" "$work/env.json"
expect "T-R33-d a remote with embedded credentials is rejected" 2 "not an HTTPS URL"
echo "$output" | grep -q "SECRET123" && { failed=$((failed + 1)); echo "FAIL the rejection message printed the embedded credential"; }

repo=$(repoWithRemote dots "https://github.com/NoNamedOrg-workflow/../otherOrg/x.git")
runAssert "$repo" "$work/env.json"
expect "T-R33-d dot segments in the URL are rejected" 2 "not an HTTPS URL"

repo=$(repoWithRemote encoded "https://github.com/NoNamedOrg-workflow/%2e%2e/otherOrg/x.git")
runAssert "$repo" "$work/env.json"
expect "T-R33-d percent-encoded dot segments are rejected" 2 "not an HTTPS URL"

echo '{' > "$work/broken.json"
repo=$(repoWithRemote brokenenv "https://github.com/NoNamedOrg-workflow/workflow-tests.git")
runAssert "$repo" "$work/broken.json"
expect "T-R33-d malformed environment file exits 2" 2 "invalid environment file"

echo '{}' > "$work/noorg.json"
runAssert "$repo" "$work/noorg.json"
expect "T-R33-d environment file without org exits 2" 2 "no org"

rejectsWithoutLeaking() {
    local name=$1 url=$2 secret=$3
    local repo; repo=$(repoWithRemote "leak$RANDOM" "https://github.com/NoNamedOrg-workflow/workflow-tests.git")
    git -C "$repo" config remote.origin.url "$url"
    runAssert "$repo" "$work/env.json"
    expect "T-R33-d $name" 2 "not an HTTPS URL"
    echo "$output" | grep -q "$secret" && { failed=$((failed + 1)); echo "FAIL $name printed the credential"; }
}

rejectsWithoutLeaking "a password containing @ is not printed" "https://u:p@TOKEN2@github.com/NoNamedOrg-workflow/x.git" "TOKEN2"
rejectsWithoutLeaking "a leading space does not expose the credential" " https://u:TOKEN1@github.com/NoNamedOrg-workflow/x.git" "TOKEN1"
rejectsWithoutLeaking "a leading tab does not expose the credential" "$(printf '\thttps://u:TOKEN4@github.com/NoNamedOrg-workflow/x.git')" "TOKEN4"

rejects() {
    local name=$1 url=$2
    local repo; repo=$(repoWithRemote "rej$RANDOM" "https://github.com/NoNamedOrg-workflow/workflow-tests.git")
    git -C "$repo" config remote.origin.url "$url"
    runAssert "$repo" "$work/env.json"
    expect "T-R33-d $name" 2 "not an HTTPS URL"
}

rejects "a trailing dot segment is rejected" "https://github.com/NoNamedOrg-workflow/.."
rejects "a trailing single dot is rejected" "https://github.com/NoNamedOrg-workflow/x/."
rejects "a double slash is rejected" "https://github.com/NoNamedOrg-workflow//evil/x"
rejects "a backslash is rejected" 'https://github.com/NoNamedOrg-workflow/..\evil/x'
rejects "an encoded backslash is rejected" "https://github.com/NoNamedOrg-workflow/..%5cevil/x"
rejects "an uppercase scheme is rejected" "HTTPS://github.com/NoNamedOrg-workflow/x.git"
rejects "a file scheme is rejected" "file:///tmp/NoNamedOrg-workflow/x.git"
rejects "an ssh scheme is rejected" "ssh://git@github.com/NoNamedOrg-workflow/x.git"
rejects "userinfo that hides another host is rejected" "https://github.com@evil.example/NoNamedOrg-workflow/x.git"

repo=$(repoWithRemote multi "https://github.com/NoNamedOrg-workflow/workflow-tests.git")
git -C "$repo" config --add remote.origin.url "https://github.com/otherOrg/x.git"
runAssert "$repo" "$work/env.json"
expect "T-R33-d a second remote URL of another org is rejected" 2 "not an HTTPS URL"

repo=$(repoWithRemote fetchrewrite "https://github.com/NoNamedOrg-workflow/workflow-tests.git")
git -C "$repo" config url."git@github.com:".insteadOf "https://github.com/"
runAssert "$repo" "$work/env.json"
expect "T-R33-d an insteadOf rewrite of the fetch URL to SSH is rejected" 2 "not an HTTPS URL"

echo '{"org":["a"]}' > "$work/orgarray.json"
repo=$(repoWithRemote orgarray "https://github.com/NoNamedOrg-workflow/workflow-tests.git")
runAssert "$repo" "$work/orgarray.json"
expect "T-R33-d an org that is not a string exits 2" 2 "invalid environment file"

echo '{"org":"bad org/../x"}' > "$work/orgbad.json"
runAssert "$repo" "$work/orgbad.json"
expect "T-R33-d an org name with unsafe characters exits 2" 2 "invalid environment file"

mkdir -p "$work/nojq"
for tool in git bash dirname; do ln -sf "$(command -v $tool)" "$work/nojq/$tool"; done
repo=$(repoWithRemote nojq "https://github.com/NoNamedOrg-workflow/workflow-tests.git")
output=$(cd "$repo" && PATH="$work/nojq" "$work/nojq/bash" "$script" "$work/env.json" 2>&1)
status=$?
expect "T-R33-d a missing jq exits 2" 2 "jq is required"

echo "assertRemote: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
