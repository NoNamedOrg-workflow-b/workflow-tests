#!/usr/bin/env bash
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
build="$root/tools/buildScenarios.sh"
check="$root/.github/scripts/checkRebase.sh"
bashBin=${BASH_BIN:-bash}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
passed=0
failed=0

ok() {
    passed=$((passed + 1))
    echo "PASS $1"
}

bad() {
    failed=$((failed + 1))
    echo "FAIL $1"
    [ -z "${2:-}" ] || echo "$2" | sed 's/^/    /'
}

verdict() {
    local repo=$1 branch=$2 default=$3
    output=$(cd "$repo" && "$bashBin" "$check" "$(git rev-parse "$default")" "$(git rev-parse "$branch")" "$default" 2>&1)
    status=$?
}

expectVerdict() {
    local name=$1 repo=$2 branch=$3 default=$4 wantStatus=$5 wantText=$6
    verdict "$repo" "$branch" "$default"
    if [ "$status" -eq "$wantStatus" ] && echo "$output" | grep -q -F -- "$wantText"; then
        ok "$name"
        return 0
    fi
    bad "$name (exit $status, wanted $wantStatus matching '$wantText')" "$output"
}

for default in development master main v2; do
    repo="$work/$default"
    "$bashBin" "$build" "$repo" "$default" > /dev/null 2>&1 || { bad "[$default] the builder failed"; continue; }

    [ "$(git -C "$repo" rev-parse --abbrev-ref HEAD)" = "$default" ] && ok "[$default] the default branch is checked out" || bad "[$default] wrong default branch"
    [ "$(git -C "$repo" rev-list --count "$default")" -eq 7 ] && ok "[$default] the default branch has 7 commits" || bad "[$default] wrong history length"
    [ -z "$(git -C "$repo" remote)" ] && ok "[$default] no remote is configured" || bad "[$default] the builder configured a remote"

    expectVerdict "[$default] T-RF3-a case/rebased passes" "$repo" case/rebased "$default" 0 "rebased onto"
    expectVerdict "[$default] T-RF2-a case/behind is 2 commits behind" "$repo" case/behind "$default" 1 "2 commit(s) behind"
    expectVerdict "[$default] T-RF1-a case/merge-in has a merge commit" "$repo" case/merge-in "$default" 1 "merge commit"
    expectVerdict "[$default] T-RF11-a case/merge-other has a merge commit" "$repo" case/merge-other "$default" 1 "merge commit"
    expectVerdict "[$default] case/conflict is behind" "$repo" case/conflict "$default" 1 "behind"

    git -C "$repo" merge-tree --write-tree "$default" case/conflict > /dev/null 2>&1
    [ "$?" -eq 1 ] && ok "[$default] case/conflict conflicts with the default branch" || bad "[$default] case/conflict does not conflict (merge-tree exit $?)"

    if git -C "$repo" merge-tree --write-tree "$default" case/behind > /dev/null 2>&1; then
        ok "[$default] case/behind merges cleanly (it is only behind)"
        continue
    fi
    bad "[$default] case/behind conflicts, so it would be hidden as a conflict case"
done

githubFree=yes
for default in development master main v2; do
    for branch in "$default" case/rebased case/behind case/merge-in case/merge-other case/conflict; do
        files=$(git -C "$work/$default" ls-tree -r --name-only "$branch" 2>&1) || { githubFree=no; bad "T-RF9-a $default: branch $branch is missing"; continue; }
        echo "$files" | grep -q '^\.github/' && { githubFree=no; bad "T-RF9-a $default/$branch carries a .github file"; }
    done
    [ -z "$(git -C "$work/$default" rev-list --merges "$default")" ] || bad "[$default] the default branch history is not linear"
done
[ "$githubFree" = "yes" ] && ok "T-RF9-a no branch of any repository carries a .github file, and every branch exists"

for default in "@" side case case/x HEAD; do
    output=$("$bashBin" "$build" "$work/bad-$RANDOM" "$default" 2>&1)
    status=$?
    [ "$status" -eq 2 ] && ok "the default branch name '$default' is rejected up front" || bad "default '$default' was accepted (exit $status)" "$output"
done
ls "$work" | grep -q '^bad-' && bad "a rejected name left a partial directory behind" || ok "a rejected name leaves nothing behind"

repo="$work/main"

output=$("$bashBin" "$build" "$repo" main 2>&1)
status=$?
[ "$status" -eq 2 ] && echo "$output" | grep -q "already exists" && ok "an existing directory is never overwritten" || bad "the builder overwrote an existing directory (exit $status)" "$output"

output=$("$bashBin" "$build" "$work/x" 2>&1)
status=$?
[ "$status" -eq 2 ] && echo "$output" | grep -q "usage:" && ok "missing arguments exit 2 with usage" || bad "usage error not reported (exit $status)" "$output"

output=$("$bashBin" "$build" "$work/y" "bad branch" 2>&1)
status=$?
[ "$status" -eq 2 ] && ok "an invalid branch name exits 2" || bad "an invalid branch name was accepted (exit $status)" "$output"

echo "buildScenarios: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
