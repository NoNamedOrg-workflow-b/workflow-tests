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
envDir=$(cd "$(dirname "$1")" 2> /dev/null && pwd) || {
    echo "environment directory not found: $(dirname "$1")" >&2
    exit 2
}
envFile=$envDir/$(basename "$1")
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

# A host, config directory or enterprise token from the environment could point gh at another identity or server.
personalGh() {
    env -u GH_TOKEN -u GITHUB_TOKEN -u GH_HOST -u GH_CONFIG_DIR -u GH_ENTERPRISE_TOKEN -u GITHUB_ENTERPRISE_TOKEN gh "$@"
}

# GitHub creates forks asynchronously, so the fork and its clone may need a few seconds to answer.
waitSeconds=${FORK_WAIT_SECONDS:-3}
if ! [[ $waitSeconds =~ ^[0-9]+$ ]]; then
    echo "FORK_WAIT_SECONDS must be a whole number: $waitSeconds" >&2
    exit 2
fi

retry() {
    local tries=0
    while [ "$tries" -lt 10 ]; do
        "$@" && return 0
        tries=$((tries + 1))
        sleep "$waitSeconds"
    done
    return 1
}

lookUpParent() {
    parent=$(personalGh api "repos/$login/$repo" --jq .parent.full_name 2> /dev/null)
}

cloneFork() {
    rm -rf "$cloneDir"
    git clone -q "$forkUrl" "$cloneDir"
}

# Only a clone this run created is removed, so a rerun is possible and a foreign directory is never touched.
cloned=no
finished=no
cleanUp() {
    [ "$cloned" = "yes" ] && [ "$finished" != "yes" ] && rm -rf "$cloneDir"
    return 0
}
trap cleanUp EXIT

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

if ! personalGh repo fork "$org/$repo" --clone=false; then
    echo "gh repo fork failed" >&2
    exit 2
fi

parent=
if ! retry lookUpParent; then
    echo "the fork $login/$repo did not appear after 10 tries" >&2
    exit 2
fi
if [ "$parent" != "$org/$repo" ]; then
    echo "$login/$repo is not a fork of $org/$repo" >&2
    exit 2
fi

forkUrl=git@github.com:$login/$repo.git
export GIT_TERMINAL_PROMPT=0
if ! retry cloneFork; then
    echo "could not clone $forkUrl after 10 tries" >&2
    exit 2
fi
cloned=yes
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

# The fork URL is the only one the push may use, whatever the clone left behind: every fetch and push URL counts.
originUrls=$(
    git remote get-url --all origin
    git remote get-url --push --all origin
)
while IFS= read -r originUrl; do
    [ "$originUrl" = "$forkUrl" ] && continue
    echo "origin is not $forkUrl; nothing was pushed" >&2
    exit 2
done <<< "$originUrls"

if ! git push -q origin "$branch"; then
    echo "push to $forkUrl failed" >&2
    exit 2
fi

if ! url=$(personalGh pr create \
    -R "$org/$repo" \
    --head "$login:$branch" \
    --base "$default" \
    --title "Fork pull request ($scenario)" \
    --body "Opened from a personal fork to measure the rebase check on fork pull requests."); then
    echo "gh pr create failed" >&2
    exit 2
fi

finished=yes
echo "$url" | tail -n 1
