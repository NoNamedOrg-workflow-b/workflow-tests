#!/usr/bin/env bash
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
bashBin=${BASH_BIN:-bash}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
passed=0
failed=0

echo '{"environment":"sandbox","org":"NoNamedOrg-workflow"}' > "$work/env.json"

ok() {
    passed=$((passed + 1))
    echo "PASS $1"
}

bad() {
    failed=$((failed + 1))
    echo "FAIL $1"
    [ -z "${2:-}" ] || echo "$2" | sed 's/^/    /'
}

# The only fakes are the two external edges: the GitHub API through gh, and the network push. The gh stub also
# records whether the local history already existed when the repository was created.
mkdir -p "$work/bin"
realGit=$(command -v git)
cat > "$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "$STUB_LOG"
case "$*" in
    "repo create"*) echo "history-ready $(git -C "$PWD" rev-list --count HEAD 2> /dev/null || echo none)" >> "$STUB_LOG" ;;
    *"--jq .default_branch"*) echo "${STUB_DEFAULT:-}"; exit 0 ;;
    "api repos/"*) [ "${STUB_EXISTS:-}" = "yes" ] && exit 0; exit 1 ;;
esac
exit 0
STUB
cat > "$work/bin/git" <<STUB
#!/usr/bin/env bash
case "\$*" in
    *" push "*) echo "git \$*" >> "\$STUB_LOG"; exit 0 ;;
esac
exec "$realGit" "\$@"
STUB
chmod +x "$work/bin/gh" "$work/bin/git"

runSeed() {
    : > "$work/calls.log"
    output=$(cd "$work" && env PATH="$work/bin:$PATH" STUB_LOG="$work/calls.log" ${EXTRA:-} GH_TOKEN=t "$bashBin" "$root/tools/seedHistory.sh" "$@" < /dev/null 2>&1)
    status=$?
    calls=$(cat "$work/calls.log")
}

expect() {
    local name=$1 wantStatus=$2
    [ "$status" -eq "$wantStatus" ] && { ok "$name"; return 0; }
    bad "$name (exit $status, wanted $wantStatus)" "$output"
}

has() {
    echo "$3" | grep -q -F -- "$2" && return 0
    bad "$1: missing '$2'" "$3"
}

lacks() {
    echo "$3" | grep -q -F -- "$2" || return 0
    bad "$1: unexpected '$2'" "$3"
}

countIs() {
    local name=$1 want=$2
    shift 2
    local got
    got=$(git -C "$repoDir" rev-list --count "$@")
    [ "$got" = "$want" ] && { ok "$name"; return 0; }
    bad "$name (got $got, wanted $want)"
}

EXTRA=""
runSeed
expect "missing arguments exit 2" 2
has "prints the usage" "usage:" "$output"

output=$(cd "$work" && env -u GH_TOKEN PATH="$work/bin:$PATH" STUB_LOG="$work/calls.log" "$bashBin" "$root/tools/seedHistory.sh" "$work/env.json" h public main "$work/wt" 5 < /dev/null 2>&1)
status=$?
expect "a missing token exits 2" 2

runSeed "$work/env.json" h secret main "$work/wv" 5
expect "an invalid visibility exits 2" 2
for badName in a/b .. -r "a b"; do
    runSeed "$work/env.json" "$badName" private main "$work/wn" 5
    expect "an invalid repository name '$badName' exits 2" 2
    lacks "no gh call for the name '$badName'" "gh " "$calls"
done
for badCount in 1 0 abc 100001 "" -5 3.5 007x; do
    runSeed "$work/env.json" h-count private main "$work/wc" "$badCount"
    expect "an invalid commit count '$badCount' exits 2" 2
    lacks "nothing is created for the count '$badCount'" "gh repo create" "$calls"
done
runSeed "$work/env.json" h-count private case/x "$work/wc" 5
expect "a reserved default branch exits 2" 2
lacks "nothing is created for a reserved branch" "gh repo create" "$calls"

runSeed "$work/env.json" hist-dev public development "$work/w1" 50
expect "seedHistory creates and pushes a repository" 0
repoDir="$work/w1/hist-dev"
has "reports the seeding" "seeded NoNamedOrg-workflow/hist-dev (public, default development, 50 commits)" "$output"
has "creates the public repository" "gh repo create NoNamedOrg-workflow/hist-dev --public" "$calls"
has "describes the repository" "Synthetic large-history repository for the rebase check" "$calls"
has "the history existed before the repository was created" "history-ready 50" "$calls"
has "pushes the default branch" "push origin development" "$calls"
has "pushes the case branches" "case/rebased" "$calls"
has "pushes the behind branch" "case/behind" "$calls"
countIs "the default branch has the requested commits" 50 development
countIs "no merge commits" 0 --merges development case/rebased case/behind
countIs "case/rebased is not behind" 0 case/rebased..development
countIs "case/rebased is one ahead" 1 development..case/rebased
countIs "case/behind is exactly one behind" 1 case/behind..development
countIs "case/behind is one ahead" 1 development..case/behind
countIs "case/behind forks from the commit before the tip" 1 development~1..case/behind
[ "$(git -C "$repoDir" rev-parse --abbrev-ref HEAD)" = "development" ] && ok "the default branch name is honoured" || bad "wrong default branch"
[ -z "$(git -C "$repoDir" status --porcelain)" ] && ok "the working tree is clean" || bad "the working tree is not clean"
[ ! -e "$repoDir/.github" ] && ok "no .github directory" || bad "a .github directory exists"
[ "$(git -C "$repoDir" log -n 1 --format='%an <%ae> %cn <%ce>' development)" = "scenario-builder <scenario-builder@example.com> scenario-builder <scenario-builder@example.com>" ] && ok "the identity is fixed" || bad "the identity is not fixed"
[ "$(git -C "$repoDir" log -n 1 --format=%s development)" = "commit 50" ] && ok "the message names the commit" || bad "wrong tip message"
[ "$(git -C "$repoDir" diff --name-only development~1 development)" = "data/50.txt" ] || [ "$(git -C "$repoDir" diff --name-only development~1 development)" = "data/0.txt" ] && ok "a commit changes one small file" || bad "a commit changes the wrong files"

runSeed "$work/env.json" hist-dev2 public development "$work/w1b" 50
tipA=$(git -C "$work/w1/hist-dev" rev-parse development)
tipB=$(git -C "$work/w1b/hist-dev2" rev-parse development)
[ "$tipA" = "$tipB" ] && ok "the history is reproducible" || bad "two runs produced different tips"

pushes=$(echo "$calls" | grep -n -E 'push origin|repo create' | cut -d: -f2 | head -n 1)
echo "$pushes" | grep -q 'repo create' && ok "the repository is created before the push" || bad "push before create" "$calls"

EXTRA="STUB_EXISTS=yes"
runSeed "$work/env.json" hist-x private main "$work/w2" 10
expect "a repository that already exists is never seeded" 2
has "says it exists" "already exists" "$output"
lacks "creates nothing" "gh repo create" "$calls"
lacks "pushes nothing" "push" "$calls"
EXTRA=""

mkdir -p "$work/w3/hist-left"
runSeed "$work/env.json" hist-left private main "$work/w3" 10
expect "an existing local directory exits 2" 2
lacks "nothing is created remotely" "gh repo create" "$calls"

EXTRA="STUB_DEFAULT=main"
runSeed "$work/env.json" hist-fix public development "$work/w4" 5
has "a default that differs is fixed through the API" "-X PATCH repos/NoNamedOrg-workflow/hist-fix" "$calls"
EXTRA=""

if [ "${SKIP_LARGE_HISTORY:-no}" = "yes" ]; then
    echo "SKIP the 20000-commit run (SKIP_LARGE_HISTORY=yes)"
fi
if [ "${SKIP_LARGE_HISTORY:-no}" != "yes" ]; then
    start=$(date +%s)
    runSeed "$work/env.json" hist-large private main "$work/w5" 20000
    elapsed=$(($(date +%s) - start))
    repoDir="$work/w5/hist-large"
    expect "a 20000-commit history is seeded" 0
    countIs "the large history has 20000 commits" 20000 main
    [ "$elapsed" -lt 60 ] && ok "20000 commits took ${elapsed}s (under 60s)" || bad "20000 commits took ${elapsed}s"
fi

echo "seedHistory: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
