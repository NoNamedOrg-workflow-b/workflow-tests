#!/usr/bin/env bash
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
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
    mkdir -p "$dir/tools"
    cp "$root/tools/release.sh" "$dir/tools/release.sh"
    echo a > "$dir/a"
    git -C "$dir" add -A
    git -C "$dir" commit -q -m a
    echo "$dir"
}

runRelease() {
    local repo=$1 testCommand=$2
    shift 2
    output=$(cd "$repo" && RUN_TESTS="$testCommand" "$bashBin" ./tools/release.sh "$@" 2>&1)
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

repo=$(newRepo red)
runRelease "$repo" false v1
expect "T-RF15-b release refuses a tag when the tests are red" 1 "tests failed"
git -C "$repo" rev-parse -q --verify refs/tags/v1 > /dev/null && { failed=$((failed + 1)); echo "FAIL tag was created despite red tests"; }

repo=$(newRepo green)
runRelease "$repo" true v1
expect "T-RF15-b release tags when the tests are green" 0 "created v1"
git -C "$repo" rev-parse -q --verify refs/tags/v1 > /dev/null || { failed=$((failed + 1)); echo "FAIL tag missing after green release"; }

repo=$(newRepo invalid)
runRelease "$repo" true latest
expect "release rejects a tag that is not a version" 2 "usage:"

repo=$(newRepo duplicate)
runRelease "$repo" true v1.2
runRelease "$repo" true v1.2
expect "release refuses to move an existing tag" 2 "already exists"

repo=$(newRepo newline)
runRelease "$repo" true $'v2\nzzz'
expect "release rejects a tag name with a newline" 2 "usage:"

repo=$(newRepo dirty)
echo changed >> "$repo/a"
runRelease "$repo" true v1
expect "release refuses to tag a dirty working tree" 2 "uncommitted"
git -C "$repo" rev-parse -q --verify refs/tags/v1 > /dev/null && { failed=$((failed + 1)); echo "FAIL tag created on a dirty tree"; }

repo=$(newRepo defaulttests)
mkdir -p "$repo/tests"
printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/tests/runTests.sh"
chmod +x "$repo/tests/runTests.sh"
git -C "$repo" add -A
git -C "$repo" commit -q -m tests
output=$(cd "$repo/tools" && env -u RUN_TESTS "$bashBin" ./release.sh v3 2>&1)
status=$?
expect "release finds the default test command from any directory" 0 "created v3"

repo=$(newRepo untracked)
git -C "$repo" config status.showUntrackedFiles no
echo stray > "$repo/stray"
runRelease "$repo" true v1
expect "release counts untracked files even when git is told to hide them" 2 "uncommitted"

repo=$(newRepo script-repo)
other=$(newRepo other-repo)
output=$(cd "$other" && RUN_TESTS=true "$bashBin" "$repo/tools/release.sh" v9 2>&1)
status=$?
expect "release tags the repository of the script, not the current directory" 0 "created v9"
git -C "$repo" rev-parse -q --verify refs/tags/v9 > /dev/null || { failed=$((failed + 1)); echo "FAIL tag missing in the script repository"; }
git -C "$other" rev-parse -q --verify refs/tags/v9 > /dev/null && { failed=$((failed + 1)); echo "FAIL tag created in the unrelated current repository"; }

repo=$(newRepo 'quote"dir')
mkdir -p "$repo/tests"
printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/tests/runTests.sh"
chmod +x "$repo/tests/runTests.sh"
git -C "$repo" add -A
git -C "$repo" commit -q -m tests
output=$(cd "$repo" && env -u RUN_TESTS "$bashBin" ./tools/release.sh v4 2>&1)
status=$?
expect "release works when the repository path contains a quote" 0 "created v4"

repo=$(newRepo race)
before=$(git -C "$repo" rev-parse HEAD)
runRelease "$repo" "git commit -q --allow-empty -m late" v5
expect "release tags the tested commit even if HEAD moves during the tests" 0 "created v5"
[ "$(git -C "$repo" rev-parse 'v5^{commit}')" = "$before" ] || { failed=$((failed + 1)); echo "FAIL the tag moved to a commit that was not tested"; }

echo "release: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
