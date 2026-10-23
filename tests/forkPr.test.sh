#!/usr/bin/env bash
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
bashBin=${BASH_BIN:-bash}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
passed=0
failed=0
org=NoNamedOrg-workflow
login=me-personal

echo "{\"environment\":\"sandbox\",\"org\":\"$org\"}" > "$work/env.json"

ok() {
    passed=$((passed + 1))
    echo "PASS $1"
}

bad() {
    failed=$((failed + 1))
    echo "FAIL $1"
    [ -z "${2:-}" ] || echo "$2" | sed 's/^/    /'
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

# The only fakes are the external edges: the GitHub API through gh, and the SSH/HTTPS transport, which the git
# wrapper points at local bare repositories for clone, fetch and push only. Every gh call logs the token variables
# it saw, so the tests can prove the personal identity never carries the org token.
mkdir -p "$work/bin"
realGit=$(command -v git)
cat > "$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $* [GH_TOKEN=${GH_TOKEN-absent} GITHUB_TOKEN=${GITHUB_TOKEN-absent}]" >> "$STUB_LOG"
case "$*" in
    "api repos/NoNamedOrg-workflow/"*) printf '%s\n%s\n%s\n' "${STUB_PRIVATE:-false}" "${STUB_FORK:-false}" development ;;
    "api repos/me-personal/"*) echo "${STUB_PARENT-NoNamedOrg-workflow/test-development}" ;;
    "api user"*) echo "${STUB_LOGIN-me-personal}" ;;
    "pr create"*) echo "https://github.com/NoNamedOrg-workflow/test-development/pull/7" ;;
esac
exit 0
STUB
cat > "$work/bin/git" <<STUB
#!/usr/bin/env bash
case " \$* " in
    *" clone "* | *" fetch "* | *" push "*) ;;
    *) exec "$realGit" "\$@" ;;
esac
echo "git \$*" >> "\$STUB_LOG"
"$realGit" \\
    -c "url.$work/fork.git.insteadOf=git@github.com:me-personal/test-development.git" \\
    -c "url.$work/upstream.git.insteadOf=https://github.com/NoNamedOrg-workflow/test-development.git" "\$@" || exit \$?
case " \$* " in
    *" clone "*) [ "\${STUB_BAD_ORIGIN:-}" = "yes" ] && "$realGit" -C "\${!#}" remote set-url origin https://github.com/NoNamedOrg-workflow/test-development.git ;;
esac
exit 0
STUB
chmod +x "$work/bin/gh" "$work/bin/git"

# Three commits so that tip~1 exists.
git init -q -b development "$work/seed"
for n in 1 2 3; do
    echo "$n" > "$work/seed/f.txt"
    git -C "$work/seed" add f.txt
    git -C "$work/seed" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false commit -q -m "c$n"
done

runFork() {
    rm -rf "$work/fork.git" "$work/upstream.git"
    git clone -q --bare "$work/seed" "$work/upstream.git"
    git clone -q --bare "$work/seed" "$work/fork.git"
    : > "$work/calls.log"
    output=$(cd "$work" && env PATH="$work/bin:$PATH" STUB_LOG="$work/calls.log" GITHUB_TOKEN=leak ${EXTRA:-} "$bashBin" "$root/tools/forkPr.sh" "$@" < /dev/null 2>&1)
    status=$?
    calls=$(cat "$work/calls.log")
}

EXTRA=""
runFork "$work/env.json" rebased
expect "missing arguments exit 2" 2
has "prints the usage" "usage:" "$output"

runFork "$work/env.json" sideways "$work/w1"
expect "an unknown scenario exits 2" 2
lacks "no gh call for an unknown scenario" "gh " "$calls"

output=$(cd "$work" && env GH_TOKEN=t PATH="$work/bin:$PATH" STUB_LOG="$work/calls.log" "$bashBin" "$root/tools/forkPr.sh" "$work/env.json" rebased "$work/w2" < /dev/null 2>&1)
status=$?
expect "an exported GH_TOKEN is refused" 2
has "explains the identity rule" "personal account" "$output"
[ ! -d "$work/w2" ] && ok "nothing is created when GH_TOKEN is set" || bad "a directory was created"

echo '{"environment":"starkbank","org":"someOrg"}' > "$work/real.json"
runFork "$work/real.json" rebased "$work/w3"
expect "a non-sandbox environment is refused" 2
lacks "no gh call in a real environment" "gh " "$calls"

echo '{"environment":"sandbox","org":"<sandbox-org>"}' > "$work/placeholder.json"
runFork "$work/placeholder.json" rebased "$work/w4"
expect "a placeholder org is refused" 2
lacks "no gh call for a placeholder" "gh " "$calls"

EXTRA="STUB_PRIVATE=true"
runFork "$work/env.json" rebased "$work/w5"
expect "a private target is refused" 2
lacks "no fork of a private target" "repo fork" "$calls"

EXTRA="STUB_FORK=true"
runFork "$work/env.json" rebased "$work/w6"
expect "a target that is itself a fork is refused" 2
lacks "no fork of a fork" "repo fork" "$calls"

EXTRA="STUB_LOGIN="
runFork "$work/env.json" rebased "$work/w7"
expect "an empty operator login is refused" 2
lacks "no fork without a login" "repo fork" "$calls"

EXTRA="STUB_PARENT=someoneElse/test-development"
runFork "$work/env.json" rebased "$work/w8"
expect "a fork whose parent is not the org repository is refused" 2
lacks "nothing is cloned" "git clone" "$calls"
lacks "no pull request is opened" "pr create" "$calls"
[ ! -d "$work/w8" ] && ok "no directory for a wrong parent" || bad "a directory was created for a wrong parent"

EXTRA=""
mkdir -p "$work/w9/$login-test-development"
runFork "$work/env.json" rebased "$work/w9"
expect "an existing work directory is refused" 2
lacks "nothing is forked into an occupied directory" "repo fork" "$calls"
lacks "nothing is cloned into an occupied directory" "git clone" "$calls"

runFork "$work/env.json" rebased "$work/w10"
expect "rebased opens the pull request" 0
dir=$work/w10/$login-test-development
counts=$(git -C "$dir" rev-list --left-right --count upstream/development...HEAD)
[ "$counts" = "$(printf '0\t1')" ] && ok "rebased is upstream tip plus one commit" || bad "rebased counts: $counts"
[ "$(echo "$output" | tail -n 1)" = "https://github.com/$org/test-development/pull/7" ] && ok "the PR URL is the last line" || bad "the PR URL is not last" "$output"
has "the PR targets the org repository" "pr create -R $org/test-development" "$calls"
branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD)
[[ $branch =~ ^fork/rebased-[0-9]+$ ]] && ok "the branch name carries the scenario and epoch" || bad "branch: $branch"
has "the head is login:branch" "--head $login:$branch" "$calls"
has "the base is the default branch" "--base development" "$calls"
[ "$(git -C "$work/fork.git" rev-parse "refs/heads/$branch")" = "$(git -C "$dir" rev-parse HEAD)" ] && ok "the branch reached the fork only" || bad "the fork lacks the branch"
[ -z "$(git -C "$work/upstream.git" for-each-ref "refs/heads/fork/*")" ] && ok "the upstream received nothing" || bad "the upstream got a branch"
[ "$(git -C "$dir" show -s --format='%an <%ae>|%cn <%ce>' HEAD)" = "scenario-builder <scenario-builder@example.com>|scenario-builder <scenario-builder@example.com>" ] && ok "the commit identity is scenario-builder" || bad "wrong identity"
[ "$(git -C "$dir" show -s --format=%G? HEAD)" = "N" ] && ok "the commit is unsigned" || bad "the commit is signed"
[ "$(git -C "$dir" show --name-only --format= HEAD)" = "fork-rebased.txt" ] && ok "the commit adds only fork-rebased.txt" || bad "unexpected files in the commit"
[ "$(git -C "$dir" remote get-url upstream)" = "https://github.com/$org/test-development.git" ] && ok "upstream points at the org repository" || bad "wrong upstream"
[ "$(git -C "$dir" remote get-url origin)" = "git@github.com:$login/test-development.git" ] && ok "origin is the personal fork" || bad "wrong origin"

echo "$calls" | grep '^gh ' > "$work/gh.log"
[ -s "$work/gh.log" ] && ! grep -v -F -e 'GH_TOKEN=absent GITHUB_TOKEN=absent]' "$work/gh.log" > /dev/null && ok "every gh call ran without the org token" || bad "a gh call saw a token" "$(cat "$work/gh.log")"
has "the fork is requested without cloning" "repo fork $org/test-development --clone=false" "$calls"
stray=$(sed -e "s#$org/test-development##g" -e "s#$login/test-development##g" -e 's#fork/[a-z]*-[0-9]*##g' "$work/gh.log" | grep -E '[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' || true)
[ -z "$stray" ] && ok "gh only names the two allowed repositories" || bad "gh named another repository" "$stray"
strayGit=$(echo "$calls" | grep '^git ' | sed -e "s#git@github.com:$login/test-development.git##g" -e "s#https://github.com/$org/test-development.git##g" | grep -E 'github\.com' || true)
[ -z "$strayGit" ] && ok "git only names the two allowed remotes" || bad "git named another remote" "$strayGit"

runFork "$work/env.json" behind "$work/w11"
expect "behind opens the pull request" 0
dir=$work/w11/$login-test-development
counts=$(git -C "$dir" rev-list --left-right --count upstream/development...HEAD)
[ "$counts" = "$(printf '1\t1')" ] && ok "behind is tip~1 plus one commit" || bad "behind counts: $counts"
[ "$(git -C "$dir" show --name-only --format= HEAD)" = "fork-behind.txt" ] && ok "the commit adds only fork-behind.txt" || bad "unexpected files in the behind commit"

EXTRA="STUB_BAD_ORIGIN=yes"
runFork "$work/env.json" rebased "$work/w12"
expect "an origin that is not the personal fork aborts" 2
lacks "nothing is pushed" " push " "$calls"
lacks "no pull request is opened" "pr create" "$calls"

echo "forkPr: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
