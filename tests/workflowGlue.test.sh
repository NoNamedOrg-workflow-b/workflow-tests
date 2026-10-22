#!/usr/bin/env bash
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
workflow="$root/.github/workflows/enforceRebase.yml"
bashBin=${BASH_BIN:-bash}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
passed=0
failed=0

# The glue lives inside the workflow, so the step under test is the real one cut out of the YAML.
stepBody() {
    awk -v name="$1" '
        $0 ~ "- name: " name "$" { on = 1; next }
        on && /^            - name:/ { exit }
        on && /^              run: \|/ { body = 1; next }
        on && body { sub(/^                  /, ""); print }
    ' "$workflow"
}

git init -q -b main "$work/origin"
git -C "$work/origin" config user.name tester
git -C "$work/origin" config user.email tester@example.com
git -C "$work/origin" config commit.gpgsign false
echo a > "$work/origin/a" && git -C "$work/origin" add a && git -C "$work/origin" commit -q -m a
git clone -q "$work/origin" "$work/pr"
git -C "$work/pr" config user.name tester
git -C "$work/pr" config user.email tester@example.com
git -C "$work/pr" config commit.gpgsign false

mkdir -p "$work/guard/.github/scripts" "$work/tmp"
cp "$root/.github/scripts/checkRebase.sh" "$work/guard/.github/scripts/checkRebase.sh"
stepBody "Check rebase" > "$work/check.sh"

runStep() {
    local guardDir=$1 headSha=$2
    : > "$work/out"
    output=$(cd "$work/pr" && env BASE=main HEAD_SHA="$headSha" GUARD="$guardDir" RUNNER_TEMP="$work/tmp" \
        GITHUB_OUTPUT="$work/out" "$bashBin" -e "$work/check.sh" 2>&1)
    status=$?
}

expect() {
    local name=$1 wantStatus=$2 wantOutput=$3
    if [ "$status" -eq "$wantStatus" ] && { [ -z "$wantOutput" ] || grep -q -F -- "$wantOutput" "$work/out"; }; then
        passed=$((passed + 1))
        echo "PASS $name"
        return 0
    fi
    failed=$((failed + 1))
    echo "FAIL $name (exit $status, wanted $wantStatus, output file has: $(cat "$work/out"))"
    echo "$output" | sed 's/^/    /'
}

[ -s "$work/check.sh" ] || { echo "FAIL could not cut the Check rebase step out of the workflow"; exit 1; }

head=$(git -C "$work/pr" rev-parse HEAD)
runStep "$work/guard/.github/scripts" "$head"
expect "a rebased branch reports ok=true and the step succeeds" 0 "ok=true"

git -C "$work/pr" checkout -q -b feature
echo b > "$work/pr/b" && git -C "$work/pr" add b && git -C "$work/pr" commit -q -m b
feature=$(git -C "$work/pr" rev-parse HEAD)
echo c > "$work/origin/c" && git -C "$work/origin" add c && git -C "$work/origin" commit -q -m c
runStep "$work/guard/.github/scripts" "$feature"
expect "a policy failure reports ok=false and the step still succeeds" 0 "ok=false"
grep -q "behind" "$work/tmp/rebaseReason.txt" || { failed=$((failed + 1)); echo "FAIL the reason file does not name the lag"; }

printf '#!/usr/bin/env bash\nexit 5\n' > "$work/guard/.github/scripts/checkRebase.sh"
chmod +x "$work/guard/.github/scripts/checkRebase.sh"
runStep "$work/guard/.github/scripts" "$feature"
expect "T-R35 an unexpected failure fails the step and publishes no verdict" 5 ""
grep -q "ok=" "$work/out" && { failed=$((failed + 1)); echo "FAIL a verdict was published after an unexpected failure"; }

printf '#!/usr/bin/env bash\nexit 1\n' > "$work/guard/.github/scripts/checkRebase.sh"
runStep "$work/guard/.github/scripts" "$feature"
expect "a policy failure without a diagnosis still gets a reason" 0 "ok=false"
grep -q "no diagnosis" "$work/tmp/rebaseReason.txt" || { failed=$((failed + 1)); echo "FAIL the missing diagnosis was not replaced by a reason"; }

# A tag named like the base branch must not win the lookup and hide that the branch is behind.
git -C "$work/pr" push -q origin feature
git -C "$work/origin" tag main "$feature" || { failed=$((failed + 1)); echo "FAIL could not create the shadowing tag"; }
printf '#!/usr/bin/env bash\n' > "$work/guard/.github/scripts/checkRebase.sh"
cat "$root/.github/scripts/checkRebase.sh" > "$work/guard/.github/scripts/checkRebase.sh"
runStep "$work/guard/.github/scripts" "$feature"
expect "T-R62-a a tag with the base name does not shadow the base branch" 0 "ok=false"
git -C "$work/origin" tag -d main > /dev/null

runOther() {
    local stepName=$1
    shift
    stepBody "$stepName" > "$work/other.sh"
    output=$(cd "$work/pr" && env "$@" "$bashBin" -e "$work/other.sh" 2>&1)
    status=$?
}

printf 'branch is 1 commit(s) behind origin/main' > "$work/tmp/rebaseReason.txt"
runOther "Fail when the branch is not rebased" RUNNER_TEMP="$work/tmp"
[ "$status" -eq 1 ] && echo "$output" | grep -q "::error::branch is 1 commit(s) behind" && { passed=$((passed + 1)); echo "PASS the verdict step goes red with the reason"; } || { failed=$((failed + 1)); echo "FAIL the verdict step did not fail with the reason (exit $status)"; }

printf '#!/usr/bin/env bash\necho "reported: $OK / $REASON"\n' > "$work/guard/.github/scripts/reportRebase.sh"
chmod +x "$work/guard/.github/scripts/reportRebase.sh"
runOther "Report on the pull request" RUNNER_TEMP="$work/tmp" GUARD="$work/guard/.github/scripts" OK=false
[ "$status" -eq 0 ] && echo "$output" | grep -q "reported: false / branch is 1 commit" && { passed=$((passed + 1)); echo "PASS the report step passes the verdict and the reason on"; } || { failed=$((failed + 1)); echo "FAIL the report step did not pass the verdict on (exit $status)"; }

runOther "Verify the guard source" GUARD_REPO="" GUARD_SHA=""
[ "$status" -eq 2 ] && { passed=$((passed + 1)); echo "PASS an empty guard source stops the run (exit 2)"; } || { failed=$((failed + 1)); echo "FAIL an empty guard source did not stop the run (exit $status)"; }

runOther "Verify the guard source" GUARD_REPO="o/central" GUARD_SHA="0123456789abcdef0123456789abcdef01234567"
[ "$status" -eq 0 ] && { passed=$((passed + 1)); echo "PASS a present guard source lets the run continue"; } || { failed=$((failed + 1)); echo "FAIL a present guard source stopped the run (exit $status)"; }

echo "workflowGlue: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
