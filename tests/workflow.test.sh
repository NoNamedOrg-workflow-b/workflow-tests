#!/usr/bin/env bash
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
workflow="$root/.github/workflows/enforceRebase.yml"
passed=0
failed=0

check() {
    local name=$1
    shift
    if "$@"; then
        passed=$((passed + 1))
        echo "PASS $name"
        return 0
    fi
    failed=$((failed + 1))
    echo "FAIL $name"
}

topLevelBlock() {
    awk -v key="$1" '$0 ~ "^" key ":" {on = 1; next} /^[^ #]/ {on = 0} on && NF' "$workflow"
}

permissionsAreExact() {
    local got want
    got=$(topLevelBlock permissions | sed 's/^ *//' | sort | tr '\n' ',')
    want="contents: read,pull-requests: write,"
    [ "$got" = "$want" ]
}

noExpressionInRunBlocks() {
    [ -f "$workflow" ] && ! awk '
        /^ *run:/ { inRun = 1; match($0, /^ */); indent = RLENGTH; if ($0 ~ /\$\{\{/) bad = 1; next }
        inRun { match($0, /^ */); if (NF && RLENGTH <= indent) inRun = 0 }
        inRun && /\$\{\{/ { bad = 1 }
        END { exit bad ? 0 : 1 }
    ' "$workflow"
}

everyActionIsPinnedToASha() {
    local uses pinned
    uses=$(grep -c -E '^ *(- )?uses:' "$workflow")
    pinned=$(grep -c -E '^ *(- )?uses: [A-Za-z0-9._/-]+@[0-9a-f]{40}( |$)' "$workflow")
    [ "$uses" -gt 0 ] && [ "$uses" -eq "$pinned" ]
}

check "T-NF1-a permissions are exactly contents: read and pull-requests: write" permissionsAreExact
check "T-R25-a no expression is interpolated inside a run block" noExpressionInRunBlocks
check "every action is pinned to a commit sha" everyActionIsPinnedToASha
check "runs on pull_request" grep -q -E '^    pull_request:' "$workflow"
check "can be called as a reusable workflow" grep -q -E '^    workflow_call:' "$workflow"
check "has a readable run-name" grep -q -E '^run-name: "CI: Enforce rebase before merge"' "$workflow"
check "cancels a superseded run of the same pull request" grep -q -E '^ +cancel-in-progress: true' "$workflow"
jobCount() {
    awk '/^jobs:/ {on = 1; next} /^[^ #]/ {on = 0} on && /^    [A-Za-z0-9_-]+:/ {n++} END {print n + 0}' "$workflow"
}

stepLine() {
    grep -n -E "^            - name: $1\$" "$workflow" | head -n 1 | cut -d: -f1
}

stepHas() {
    awk -v name="$1" -v needle="$2" '
        $0 ~ "- name: " name "$" { on = 1; next }
        on && /^            - name:/ { exit }
        on && index($0, needle) { found = 1 }
        END { exit found ? 0 : 1 }
    ' "$workflow"
}

decisionCodeComesOnlyFromTheGuard() {
    grep -q '"$GUARD/checkRebase.sh"' "$workflow" && ! grep -q -E '\./\.github/scripts|pr/\.github|\$\{\{ *github\.workspace *\}\}/pr/' "$workflow"
}

guardIsVerifiedBeforeItIsFetched() {
    local verify fetch
    verify=$(stepLine "Verify the guard source")
    fetch=$(stepLine "Checkout the rebase guard scripts")
    [ -n "$verify" ] && [ -n "$fetch" ] && [ "$verify" -lt "$fetch" ]
}

check "the workflow has exactly one job" test "$(jobCount)" -eq 1
check "the job is named rebase-status" grep -q -E '^    rebase-status:' "$workflow"
check "the guard scripts are checked out at the commit of this workflow" grep -q 'ref: ${{ job.workflow_sha }}' "$workflow"
check "the decision code is run only from guard/" decisionCodeComesOnlyFromTheGuard
check "an empty workflow commit stops the run before the checkout" guardIsVerifiedBeforeItIsFetched
check "the verdict step fails only when ok is false" stepHas "Fail when the branch is not rebased" "if: steps.check.outputs.ok == 'false'"
check "the report step cannot fail the job" stepHas "Report on the pull request" "continue-on-error: true"
check "the base branch is fetched by its full ref, so a tag cannot shadow it" grep -q 'git fetch --no-tags origin "refs/heads/$BASE"' "$workflow"
check "the concurrency group names the workflow and falls back to the ref" grep -q 'github.event.pull_request.number || github.ref }}' "$workflow"
check "T-R68-a the concurrency group includes the workflow ref, so two pinned versions never cancel each other" grep -q 'github.workflow_ref }}' "$workflow"
check "the header explains where the guarantee holds" grep -q -i 'merge ref' "$workflow"

echo "workflow: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
