#!/usr/bin/env bash
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
check="$root/.github/scripts/checkRebase.sh"
bashBin=${BASH_BIN:-bash}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
passed=0
failed=0

newRepo() {
    local dir="$work/$1"
    git init -q -b main "$dir"
    git -C "$dir" config user.name tester
    git -C "$dir" config user.email tester@example.com
    git -C "$dir" config commit.gpgsign false
    echo "$dir"
}

commitFile() {
    local repo=$1 name=$2
    echo "$name" > "$repo/$name"
    git -C "$repo" add "$name"
    git -C "$repo" commit -q -m "$name"
}

runCheck() {
    local repo=$1
    shift
    output=$(cd "$repo" && "$bashBin" "$check" "$@" 2>&1)
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

rebasedBranchPasses() {
    local repo; repo=$(newRepo rebased)
    commitFile "$repo" a
    git -C "$repo" checkout -q -b feature
    commitFile "$repo" b
    runCheck "$repo" "$(git -C "$repo" rev-parse main)" "$(git -C "$repo" rev-parse feature)" main
    expect "T-RF3-a rebased branch passes" 0 "rebased onto main"
}

severalLinearCommitsPass() {
    local repo; repo=$(newRepo linear)
    commitFile "$repo" a
    git -C "$repo" checkout -q -b feature
    commitFile "$repo" b
    commitFile "$repo" c
    commitFile "$repo" d
    runCheck "$repo" "$(git -C "$repo" rev-parse main)" "$(git -C "$repo" rev-parse feature)" main
    expect "T-R54-a several linear commits pass" 0 "rebased onto main"
}

sameCommitPasses() {
    local repo; repo=$(newRepo same)
    commitFile "$repo" a
    local tip; tip=$(git -C "$repo" rev-parse main)
    runCheck "$repo" "$tip" "$tip" main
    expect "base equals head passes" 0 "rebased onto main"
}

behindBranchFails() {
    local repo; repo=$(newRepo behind)
    commitFile "$repo" a
    git -C "$repo" checkout -q -b feature
    commitFile "$repo" b
    git -C "$repo" checkout -q main
    commitFile "$repo" c
    commitFile "$repo" d
    runCheck "$repo" "$(git -C "$repo" rev-parse main)" "$(git -C "$repo" rev-parse feature)" main
    expect "T-RF2-a behind branch fails and counts commits" 1 "2 commit(s) behind main"
}

baseMergedIntoBranchFails() {
    local repo; repo=$(newRepo mergein)
    commitFile "$repo" a
    git -C "$repo" checkout -q -b feature
    commitFile "$repo" b
    git -C "$repo" checkout -q main
    commitFile "$repo" c
    git -C "$repo" checkout -q feature
    git -C "$repo" merge -q --no-ff -m "merge main" main
    runCheck "$repo" "$(git -C "$repo" rev-parse main)" "$(git -C "$repo" rev-parse feature)" main
    expect "T-RF1-a base merged into the branch fails" 1 "merge commit"
}

otherBranchMergedFails() {
    local repo; repo=$(newRepo mergeother)
    commitFile "$repo" a
    git -C "$repo" checkout -q -b other
    commitFile "$repo" x
    git -C "$repo" checkout -q main
    git -C "$repo" checkout -q -b feature
    commitFile "$repo" b
    git -C "$repo" merge -q --no-ff -m "merge other" other
    runCheck "$repo" "$(git -C "$repo" rev-parse main)" "$(git -C "$repo" rev-parse feature)" main
    expect "T-R16-a another branch merged into the branch fails" 1 "merge commit"
}

mergeAndBehindReportBoth() {
    local repo; repo=$(newRepo both)
    commitFile "$repo" a
    git -C "$repo" checkout -q -b feature
    commitFile "$repo" b
    git -C "$repo" checkout -q main
    commitFile "$repo" c
    git -C "$repo" checkout -q feature
    git -C "$repo" merge -q --no-ff -m "merge main" main
    git -C "$repo" checkout -q main
    commitFile "$repo" d
    runCheck "$repo" "$(git -C "$repo" rev-parse main)" "$(git -C "$repo" rev-parse feature)" main
    expect "merge commit and lag are both reported" 1 "merge commit"
    echo "$output" | grep -q "behind main" || { failed=$((failed + 1)); echo "FAIL both reasons: lag missing"; }
}

rewrittenBaseFails() {
    local repo; repo=$(newRepo rewritten)
    commitFile "$repo" a
    git -C "$repo" checkout -q -b feature
    commitFile "$repo" b
    git -C "$repo" checkout -q main
    commitFile "$repo" c
    git -C "$repo" reset -q --hard HEAD~1
    commitFile "$repo" c2
    runCheck "$repo" "$(git -C "$repo" rev-parse main)" "$(git -C "$repo" rev-parse feature)" main
    expect "T-R36-a rewritten base reports lag" 1 "behind main"
}

missingArgumentIsNotAPolicyFailure() {
    local repo; repo=$(newRepo noargs)
    commitFile "$repo" a
    runCheck "$repo" "$(git -C "$repo" rev-parse main)"
    expect "missing argument exits 2 with usage" 2 "usage:"
}

unknownCommitIsNotAPolicyFailure() {
    local repo; repo=$(newRepo unknown)
    commitFile "$repo" a
    runCheck "$repo" "$(git -C "$repo" rev-parse main)" "0000000000000000000000000000000000000000" main
    expect "unknown commit exits 2" 2 "unknown commit"
}

unrelatedHistoriesAreNotLag() {
    local repo; repo=$(newRepo orphan)
    commitFile "$repo" a
    git -C "$repo" checkout -q --orphan stranger
    git -C "$repo" rm -q -rf .
    commitFile "$repo" z
    runCheck "$repo" "$(git -C "$repo" rev-parse main)" "$(git -C "$repo" rev-parse stranger)" main
    expect "T-R35-a unrelated histories exit 2, never 'behind'" 2 "no common ancestor"
    echo "$output" | grep -q "behind" && { failed=$((failed + 1)); echo "FAIL orphan reported as behind"; }
}

shallowCloneIsNotAPolicyFailure() {
    local origin; origin=$(newRepo origin)
    commitFile "$origin" a
    commitFile "$origin" b
    commitFile "$origin" c
    git clone -q --depth 1 "file://$origin" "$work/shallow"
    local tip; tip=$(git -C "$work/shallow" rev-parse HEAD)
    runCheck "$work/shallow" "$tip" "$tip" main
    expect "T-R35-b shallow clone exits 2" 2 "shallow"
}

notACommitIsNotAPolicyFailure() {
    local repo; repo=$(newRepo tree)
    commitFile "$repo" a
    runCheck "$repo" "$(git -C "$repo" rev-parse main)" "$(git -C "$repo" rev-parse 'main^{tree}')" main
    expect "a tree object instead of a commit exits 2" 2 "unknown commit"
}

baseNameDefaultsWhenOmitted() {
    local repo; repo=$(newRepo noname)
    commitFile "$repo" a
    local tip; tip=$(git -C "$repo" rev-parse main)
    runCheck "$repo" "$tip" "$tip"
    expect "base name defaults when the third argument is omitted" 0 "rebased onto base"
}

mergeMessageDoesNotBlameTheBase() {
    local repo; repo=$(newRepo blame)
    commitFile "$repo" a
    git -C "$repo" checkout -q -b other
    commitFile "$repo" x
    git -C "$repo" checkout -q main
    git -C "$repo" checkout -q -b feature
    commitFile "$repo" b
    git -C "$repo" merge -q --no-ff -m "merge other" other
    runCheck "$repo" "$(git -C "$repo" rev-parse main)" "$(git -C "$repo" rev-parse feature)" main
    echo "$output" | grep -q "was merged in" && { failed=$((failed + 1)); echo "FAIL message blames the base for a merge of another branch"; }
    expect "merge message tells how to fix it without blaming the base" 1 "rebase it onto main"
}

rebasedBranchPasses
severalLinearCommitsPass
sameCommitPasses
behindBranchFails
baseMergedIntoBranchFails
otherBranchMergedFails
mergeAndBehindReportBoth
rewrittenBaseFails
missingArgumentIsNotAPolicyFailure
unknownCommitIsNotAPolicyFailure
unrelatedHistoriesAreNotLag
shallowCloneIsNotAPolicyFailure
notACommitIsNotAPolicyFailure
baseNameDefaultsWhenOmitted
mergeMessageDoesNotBlameTheBase

echo "checkRebase: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
