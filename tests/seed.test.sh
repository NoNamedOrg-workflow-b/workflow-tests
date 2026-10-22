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

# stdin is closed on every seed call: the greedy gh stub reads it and would block when the runner keeps it open.
# The only fakes are the two external edges: the GitHub API through gh, and the network push.
mkdir -p "$work/bin"
realGit=$(command -v git)
cat > "$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "$STUB_LOG"
case "$*" in
    *"--jq .default_branch"*) echo "${STUB_DEFAULT:-}"; exit 0 ;;
    "api repos/"*) [ "${STUB_EXISTS:-}" = "yes" ] && exit 0; exit 1 ;;
esac
[ "${STUB_GREEDY:-}" = "yes" ] && cat > /dev/null
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
    local script=$1
    shift
    : > "$work/calls.log"
    output=$(cd "$work" && env PATH="$work/bin:$PATH" STUB_LOG="$work/calls.log" ${EXTRA:-} GH_TOKEN=t "$bashBin" "$root/tools/$script" "$@" < /dev/null 2>&1)
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

EXTRA=""
runSeed seedRepo.sh "$work/env.json" test-development public development "$work/w1"
expect "seedRepo creates and pushes a repository" 0
has "creates the public repository" "gh repo create NoNamedOrg-workflow/test-development --public" "$calls"
has "pushes the default branch first" "push origin development" "$calls"
has "pushes the scenario branches" "case/rebased" "$calls"
[ "$(git -C "$work/w1/test-development" rev-list --count development)" -eq 7 ] && ok "the local history was built before pushing" || bad "the local history is wrong"

runSeed seedRepo.sh "$work/env.json" test-master private master "$work/w2"
has "creates the private repository" "gh repo create NoNamedOrg-workflow/test-master --private" "$calls"

EXTRA="STUB_EXISTS=yes"
runSeed seedRepo.sh "$work/env.json" test-main private main "$work/w3"
expect "seedRepo never seeds a repository that already exists" 2
has "says it exists" "already exists" "$output"
lacks "creates nothing" "gh repo create" "$calls"
lacks "pushes nothing" "push" "$calls"
EXTRA=""

runSeed seedRepo.sh "$work/env.json" test-x secret main "$work/w4"
expect "an invalid visibility exits 2" 2
runSeed seedRepo.sh "$work/env.json" test-x
expect "missing arguments exit 2" 2
has "prints the usage" "usage:" "$output"

output=$(cd "$work" && env -u GH_TOKEN PATH="$work/bin:$PATH" STUB_LOG="$work/calls.log" "$bashBin" "$root/tools/seedRepo.sh" "$work/env.json" test-x public main "$work/w5" < /dev/null 2>&1)
status=$?
expect "a missing token exits 2" 2

echo '{"environment":"starkbank","org":"someOrg"}' > "$work/real.json"
runSeed seedRepo.sh "$work/real.json" test-x public main "$work/w6"
expect "T-R33 seeding refuses an environment that is not the sandbox" 2
lacks "creates nothing in a real environment" "gh repo create" "$calls"
runSeed seedFleet.sh "$work/real.json" 3 "$work/w7"
expect "T-R33 the fleet refuses an environment that is not the sandbox" 2
lacks "creates no fleet in a real environment" "gh repo create" "$calls"

EXTRA=""
runSeed seedFleet.sh "$work/env.json" 6 "$work/fleet"
expect "seedFleet seeds the planned repositories" 0
has "creates the first repository" "gh repo create NoNamedOrg-workflow/test-fleet-01 --private" "$calls"
has "creates a public one" "gh repo create NoNamedOrg-workflow/test-fleet-05 --public" "$calls"
[ "$(echo "$calls" | grep -c 'gh repo create')" -eq 6 ] && ok "six repositories were created" || bad "wrong number of repositories created" "$calls"
[ "$(git -C "$work/fleet/test-fleet-02" rev-parse --abbrev-ref HEAD)" = "master" ] && ok "the default branch follows the plan" || bad "wrong default branch for test-fleet-02"

EXTRA="STUB_EXISTS=yes"
runSeed seedFleet.sh "$work/env.json" 3 "$work/fleet2"
expect "seedFleet skips repositories that already exist" 0
lacks "creates nothing" "gh repo create" "$calls"
has "reports the skip" "already exists" "$output"

EXTRA="STUB_DEFAULT=development"
runSeed seedRepo.sh env.json test-rel public development "$work/w8"
expect "a relative environment file works from any directory" 0
has "the repository was created" "gh repo create NoNamedOrg-workflow/test-rel" "$calls"
lacks "no default-branch fix is needed when it already matches" "-X PATCH" "$calls"
pushed=$(echo "$calls" | grep -n 'push origin' | cut -d: -f1 | tr '\n' ' ')
[ "$(echo "$calls" | grep 'push origin' | head -n 1 | grep -c 'push origin development$')" -eq 1 ] && ok "the default branch is pushed first" || bad "the default branch is not pushed first" "$calls"
for branch in case/rebased case/behind case/merge-in case/merge-other case/conflict; do
    echo "$calls" | grep 'push origin' | tail -n 1 | grep -q -F -- "$branch" && ok "the scenario branch $branch is pushed" || bad "the scenario branch $branch is not pushed" "$calls"
done

EXTRA="STUB_DEFAULT=main"
runSeed seedRepo.sh env.json test-fix public development "$work/w9"
has "a default that differs is fixed through the API" "-X PATCH repos/NoNamedOrg-workflow/test-fix" "$calls"

EXTRA=""
for badDefault in -x side case/x; do
    runSeed seedRepo.sh env.json test-bad private "$badDefault" "$work/w10"
    expect "T-R35 an invalid default branch '$badDefault' fails before anything is created" 2
    lacks "no repository is created for '$badDefault'" "gh repo create" "$calls"
done

for badName in a/b .. -r "a b"; do
    runSeed seedRepo.sh env.json "$badName" private main "$work/w11"
    expect "an invalid repository name '$badName' exits 2" 2
    lacks "no gh call for the name '$badName'" "gh " "$calls"
done

git init -q "$work/w12-existing"
git -C "$work/w12-existing" remote add origin https://example.invalid/x.git
mkdir -p "$work/w12"
git init -q -b main "$work/w12/test-leftover" && git -C "$work/w12/test-leftover" remote add origin https://example.invalid/x.git
runSeed seedRepo.sh env.json test-leftover private main "$work/w12"
expect "a leftover local directory stops the run before the repository is created" 2
lacks "nothing is created remotely" "gh repo create" "$calls"

printf '{"environment":null}\n{"environment":"sandbox","org":"someRealOrg"}\n' > "$work/multi.json"
runSeed seedRepo.sh multi.json test-x private main "$work/w13"
expect "a multi-document environment file is refused" 2
lacks "nothing is created from a multi-document file" "gh repo create" "$calls"

echo '{"environment":"sandbox","org":"bad org"}' > "$work/badorg.json"
runSeed seedRepo.sh badorg.json test-x private main "$work/w14"
expect "an org name with unsafe characters is refused" 2

EXTRA="STUB_GREEDY=yes"
runSeed seedFleet.sh env.json 6 "$work/fleetg"
expect "seedFleet survives a gh that reads stdin" 0
[ "$(echo "$calls" | grep -c 'gh repo create')" -eq 6 ] && ok "all six repositories are created even when gh reads stdin" || bad "gh swallowed the plan" "$calls"

EXTRA=""
runSeed seedFleet.sh env.json
expect "seedFleet without arguments exits 2" 2
has "prints the usage" "usage:" "$output"
output=$(cd "$work" && env -u GH_TOKEN PATH="$work/bin:$PATH" STUB_LOG="$work/calls.log" "$bashBin" "$root/tools/seedFleet.sh" env.json 3 "$work/fl" < /dev/null 2>&1)
status=$?
expect "seedFleet without a token exits 2" 2

echo "seed: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
