#!/usr/bin/env bash
# Tags only when the local tests pass on the exact committed tree, so a broken central workflow never gets a
# version the ruleset can pin. The tag is lightweight on purpose: a ruleset that requires the workflow at an annotated
# tag is accepted by the API and then never runs, so the pull requests would get no check at all.
set -euo pipefail

tag=${1:-}
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

if ! [[ $tag =~ ^v[0-9]+(\.[0-9]+)*$ ]]; then
    echo "usage: release.sh vN[.N...]" >&2
    exit 2
fi

if git rev-parse -q --verify "refs/tags/$tag" > /dev/null; then
    echo "tag $tag already exists; tags are never moved" >&2
    exit 2
fi

# The tag lands on HEAD, so the tests must have run against HEAD and not against local edits.
if [ -n "$(git status --porcelain --untracked-files=all)" ]; then
    echo "uncommitted changes: the tests would not match $tag" >&2
    exit 2
fi

tested=$(git rev-parse HEAD)

runTests() {
    [ -n "${RUN_TESTS:-}" ] || { "$root/tests/runTests.sh"; return; }
    sh -c "$RUN_TESTS"
}

if ! runTests > /dev/null; then
    echo "tests failed: $tag not created" >&2
    exit 1
fi

git tag "$tag" "$tested"
echo "created $tag (not pushed)"
