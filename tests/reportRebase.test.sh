#!/usr/bin/env bash
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
report="$root/.github/scripts/reportRebase.sh"
bashBin=${BASH_BIN:-bash}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
passed=0
failed=0

# Only the external edge is faked: a gh that records its calls and answers the comment listing from a fixture.
mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
[ "${STUB_FAIL:-}" = "all" ] && { echo "gh: HTTP 403" >&2; exit 1; }
case "$*" in
    *"-X "*) [ "${STUB_FAIL:-}" = "write" ] && { echo "gh: HTTP 403" >&2; exit 1; } ;;
esac
case "$*" in
    *"--slurp"*) echo "${STUB_COMMENTS:-[[]]}" ;;
esac
STUB
chmod +x "$work/bin/gh"

run() {
    : > "$work/calls.log"
    output=$(cd "$work" && env PATH="$work/bin:$PATH" STUB_LOG="$work/calls.log" REPO=o/r NUMBER=7 BASE=development \
        "$@" "$bashBin" "$report" 2>&1)
    status=$?
    calls=$(cat "$work/calls.log")
}

expect() {
    local name=$1 wantStatus=$2
    if [ "$status" -eq "$wantStatus" ]; then
        passed=$((passed + 1))
        echo "PASS $name"
        return 0
    fi
    failed=$((failed + 1))
    echo "FAIL $name (exit $status, wanted $wantStatus)"
    echo "$output" | sed 's/^/    /'
}

has() {
    local name=$1 pattern=$2 text=$3
    echo "$text" | grep -q -F -- "$pattern" && return 0
    failed=$((failed + 1))
    echo "FAIL $name: missing '$pattern'"
    echo "$text" | sed 's/^/    /' | head -12
}

lacks() {
    local name=$1 pattern=$2 text=$3
    echo "$text" | grep -q -F -- "$pattern" || return 0
    failed=$((failed + 1))
    echo "FAIL $name: unexpected '$pattern'"
}

run OK=false REASON="branch is 2 commit(s) behind development"
expect "T-R27-a failure without a previous comment" 0
has "creates the comment" "-X POST repos/o/r/issues/7/comments" "$calls"
has "the comment carries the marker" "<!-- rebase-guard-org -->" "$calls"
has "the comment carries the reason" "2 commit(s) behind development" "$calls"
has "the comment tells how to rebase" "git rebase origin/development" "$calls"
has "T-R40-a the comment warns about Update branch" "Update branch" "$calls"
has "adds the label" "labels[]=rebase-required" "$calls"
lacks "does not patch" "-X PATCH" "$calls"

run OK=false REASON="1 merge commit(s)" STUB_COMMENTS='[[{"id":41,"user":{"login":"someone"},"body":"x"},{"id":77,"user":{"login":"github-actions[bot]"},"body":"<!-- rebase-guard-org -->\nold"}]]'
expect "T-R27-b failure edits the sticky comment" 0
has "patches the existing comment" "-X PATCH repos/o/r/issues/comments/77" "$calls"
lacks "does not post a second comment" "-X POST repos/o/r/issues/7/comments" "$calls"

run OK=false REASON="behind" STUB_COMMENTS='[[{"id":5,"user":{"login":"github-actions[bot]"},"body":"<!-- enforce-rebase -->\nfrom the proof of concept"}]]'
expect "T-R52 the proof-of-concept marker is not mistaken for ours" 0
has "posts its own comment" "-X POST repos/o/r/issues/7/comments" "$calls"
lacks "never edits the proof-of-concept comment" "comments/5" "$calls"

run OK=true REASON="branch is rebased onto development" STUB_COMMENTS='[[{"id":77,"user":{"login":"github-actions[bot]"},"body":"<!-- rebase-guard-org -->\nold"}]]'
expect "T-R27-c success turns the comment green and drops the label" 0
has "patches to the green text" "-X PATCH repos/o/r/issues/comments/77" "$calls"
has "says rebase ok" "Rebase OK" "$calls"
has "removes the label" "-X DELETE repos/o/r/issues/7/labels/rebase-required" "$calls"

run OK=true REASON="branch is rebased onto development"
expect "success on a pull request that never failed stays quiet" 0
lacks "no comment is created" "-X POST repos/o/r/issues/7/comments" "$calls"
lacks "no comment is edited" "-X PATCH" "$calls"
has "still clears a stray label" "-X DELETE repos/o/r/issues/7/labels/rebase-required" "$calls"

run OK=false REASON="behind" STUB_FAIL=all
expect "T-R14 a read-only token only warns and never fails the step" 0
has "warns instead of failing" "::warning::" "$output"

run OK=false REASON='$(touch /tmp/pwned) `id` "quoted"'
expect "T-R25 hostile text in the reason is data, not code" 0
has "the reason arrives verbatim" '$(touch /tmp/pwned)' "$calls"
[ -e /tmp/pwned ] && { failed=$((failed + 1)); echo "FAIL the reason was executed"; rm -f /tmp/pwned; }

run OK=false REASON=behind STUB_COMMENTS='[[{"id":77,"user":{"login":"github-actions[bot]"},"body":"<!-- rebase-guard-org -->\nold"},{"id":88,"user":{"login":"someone"},"body":"lol <!-- rebase-guard-org -->"}]]'
expect "the sticky comment is the bot's, even when a human quotes the marker later" 0
has "edits the bot comment" "-X PATCH repos/o/r/issues/comments/77" "$calls"
lacks "never touches the human comment" "comments/88" "$calls"

run OK=false REASON=behind STUB_COMMENTS='[[{"id":77,"user":{"login":"github-actions[bot]"},"body":"<!-- rebase-guard-org -->\nold"},{"id":88,"user":{"login":"someone"},"body":"<!-- rebase-guard-org -->\nforged by a human"}]]'
expect "a human forging the marker at the start of a newer comment is not adopted" 0
has "still edits the bot comment" "-X PATCH repos/o/r/issues/comments/77" "$calls"
lacks "never edits the forged comment" "comments/88" "$calls"

run OK=false REASON=behind STUB_COMMENTS='[[{"id":88,"user":{"login":"someone"},"body":"lol <!-- rebase-guard-org -->"}]]'
expect "a human comment that only quotes the marker is not adopted" 0
has "creates its own comment instead" "-X POST repos/o/r/issues/7/comments" "$calls"
lacks "does not edit the human comment" "-X PATCH" "$calls"

run OK=false REASON=behind STUB_COMMENTS='[[{"id":77,"user":{"login":"github-actions[bot]"},"body":"<!-- rebase-guard-org -->'
expect "T-R14 a listing jq cannot parse skips the report" 0
lacks "no duplicate comment is created" "-X POST repos/o/r/issues/7/comments" "$calls"
lacks "no comment is edited" "-X PATCH" "$calls"
has "says why" "::warning::" "$output"

run OK=false REASON=behind STUB_COMMENTS='<html>502 Bad Gateway</html>'
expect "an HTML error page as the listing skips the report" 0
lacks "no duplicate from an HTML page" "-X POST repos/o/r/issues/7/comments" "$calls"

run OK=false REASON=behind STUB_FAIL=write
expect "T-R14 the listing works but every write is refused: only warnings" 0
has "warns about the comment" "could not create the rebase comment" "$output"
has "warns about the label" "could not apply the rebase-required label" "$output"

run OK=TRUE REASON=x
expect "an OK value other than true or false is an unexpected input" 2

run OK=false REASON=behind BASE='main$(id)'
expect "a hostile base name is quoted in the snippet people paste" 0
has "the snippet quotes the base" 'git rebase origin/main\$\(id\)' "$calls"

output=$(cd "$work" && env PATH="$work/bin:$PATH" STUB_LOG="$work/calls.log" NUMBER=7 BASE=development OK=true REASON=x "$bashBin" "$report" 2>&1)
status=$?
expect "a missing variable is an unexpected input (exit 2)" 2

echo "reportRebase: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
