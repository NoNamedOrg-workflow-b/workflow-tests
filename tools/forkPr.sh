#!/usr/bin/env bash
# Opens a pull request from a fork owned by the operator's PERSONAL GitHub account to the public test-development
# repository of the sandbox org, to measure how the rebase check treats fork pull requests. This is the only tool
# that uses personal credentials, so every personal call runs without the org token, the target is a constant that
# no argument can change, and the push is only attempted once origin is proven to be the personal fork.
set -euo pipefail

if [ "$#" -ne 3 ]; then
    echo "usage: forkPr.sh <envFile> <rebased|behind> <workDirectory>" >&2
    exit 2
fi

# The tools below change directory, so a relative path would stop resolving.
envFile=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
scenario=$2
workDir=$3
tools=$(cd "$(dirname "$0")" && pwd)
repo=test-development

case "$workDir" in
    /*) ;;
    *) workDir=$PWD/$workDir ;;
esac

# Mixing the org token with the personal identity would let a fork call reach the org with the wrong rights.
if [ -n "${GH_TOKEN+x}" ]; then
    echo "forkPr uses the personal account: the org token must not be exported (unset GH_TOKEN)" >&2
    exit 2
fi

case "$scenario" in
    rebased | behind) ;;
    *) echo "scenario must be rebased or behind" >&2; exit 2 ;;
esac

org=$("$tools/readSandboxOrg.sh" "$envFile")

personalGh() {
    env -u GH_TOKEN -u GITHUB_TOKEN gh "$@"
}

target=$(personalGh api "repos/$org/$repo" --jq '.private,.fork,.default_branch')
private=$(echo "$target" | sed -n 1p)
isFork=$(echo "$target" | sed -n 2p)
default=$(echo "$target" | sed -n 3p)

if [ "$private" != "false" ] || [ "$isFork" != "false" ]; then
    echo "$org/$repo must be public and not a fork" >&2
    exit 2
fi

if [ -z "$default" ] || ! git check-ref-format --branch "$default" > /dev/null 2>&1; then
    echo "invalid default branch of $org/$repo: $default" >&2
    exit 2
fi

login=$(personalGh api user --jq .login)
if ! [[ $login =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]]; then
    echo "could not read a valid operator login" >&2
    exit 2
fi

cloneDir=$workDir/$login-$repo
if [ -e "$cloneDir" ]; then
    echo "$cloneDir already exists; the tool never overwrites" >&2
    exit 2
fi

personalGh repo fork "$org/$repo" --clone=false

parent=$(personalGh api "repos/$login/$repo" --jq .parent.full_name)
if [ "$parent" != "$org/$repo" ]; then
    echo "$login/$repo is not a fork of $org/$repo" >&2
    exit 2
fi

forkUrl=git@github.com:$login/$repo.git
export GIT_TERMINAL_PROMPT=0
git clone -q "$forkUrl" "$cloneDir"
cd "$cloneDir"
git config user.name scenario-builder
git config user.email scenario-builder@example.com
git config commit.gpgsign false

git remote add upstream "https://github.com/$org/$repo.git"
git fetch -q upstream

base=upstream/$default
[ "$scenario" = "behind" ] && base=upstream/$default~1
if ! git rev-parse --verify -q "$base^{commit}" > /dev/null; then
    echo "$base does not exist" >&2
    exit 2
fi

branch=fork/$scenario-$(date +%s)
git checkout -q -b "$branch" "$base"
echo "$scenario" > "fork-$scenario.txt"
git add "fork-$scenario.txt"
git commit -q -m "Add fork-$scenario.txt for the fork pull request check"

# A fork URL is the only one the push may use, whatever the clone left behind.
for url in "$(git remote get-url origin)" "$(git remote get-url --push origin)"; do
    [ "$url" = "$forkUrl" ] && continue
    echo "origin is not $forkUrl; nothing was pushed" >&2
    exit 2
done

git push -q origin "$branch"

url=$(personalGh pr create \
    -R "$org/$repo" \
    --head "$login:$branch" \
    --base "$default" \
    --title "Fork pull request ($scenario)" \
    --body "Opened from a personal fork to measure the rebase check on fork pull requests.")
echo "$url" | tail -n 1
