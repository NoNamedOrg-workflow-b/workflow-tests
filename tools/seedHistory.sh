#!/usr/bin/env bash
# Creates one synthetic repository in the sandbox org with a large linear history, to measure what fetch-depth: 0
# costs. An existing repository is never touched, and it is created only after the whole local history exists, so a
# failure leaves nothing empty on GitHub. The history is one git fast-import stream: a commit per git commit would
# take minutes at tens of thousands of commits.
set -euo pipefail

if [ "$#" -ne 6 ]; then
    echo "usage: seedHistory.sh <envFile> <repoName> <public|private> <defaultBranch> <workDirectory> <commitCount>" >&2
    exit 2
fi

# The tools below change directory, so a relative path would stop resolving.
envFile=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
repo=$2
visibility=$3
default=$4
workDir=$5
count=$6
tools=$(cd "$(dirname "$0")" && pwd)

if [ -z "${GH_TOKEN:-}" ]; then
    echo "GH_TOKEN is required" >&2
    exit 2
fi

case "$visibility" in
    public | private) ;;
    *) echo "visibility must be public or private" >&2; exit 2 ;;
esac

if ! [[ $repo =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || [[ $repo =~ ^\.+$ ]]; then
    echo "invalid repository name: $repo" >&2
    exit 2
fi

# Two commits are the minimum: case/behind forks from the commit before the tip.
if ! [[ $count =~ ^[0-9]+$ ]] || [ "${#count}" -gt 6 ] || [ "$((10#$count))" -lt 2 ] || [ "$((10#$count))" -gt 100000 ]; then
    echo "commitCount must be an integer between 2 and 100000: $count" >&2
    exit 2
fi
count=$((10#$count))

if ! git check-ref-format --branch "$default" > /dev/null 2>&1; then
    echo "invalid branch name: $default" >&2
    exit 2
fi

# These names are used by the case branches or mean something else to git (@ is HEAD).
case "$default" in
    @ | HEAD | case | case/*)
        echo "reserved branch name: $default" >&2
        exit 2
        ;;
esac

org=$("$tools/readSandboxOrg.sh" "$envFile")

if gh api "repos/$org/$repo" > /dev/null 2>&1; then
    echo "$org/$repo already exists; it is never seeded twice" >&2
    exit 2
fi

if [ -e "$workDir/$repo" ]; then
    echo "$workDir/$repo already exists; the builder never overwrites" >&2
    exit 2
fi

# Marks :1..:count are the default branch commits; the case branches fork from the tip and from the commit before it.
buildStream() {
    awk -v count="$count" -v default="$default" '
        function commit(ref, mark, parent, file, body,    message, who) {
            message = "commit " mark
            who = "scenario-builder <scenario-builder@example.com> " (1700000000 + mark * 60) " +0000"
            print "commit refs/heads/" ref
            print "mark :" mark
            print "author " who
            print "committer " who
            print "data " length(message)
            print message
            if (parent != "") print "from :" parent
            print "M 100644 inline " file
            print "data " length(body)
            print body
        }
        BEGIN {
            for (n = 1; n <= count; n++) commit(default, n, "", "data/" (n % 100) ".txt", "content " n)
            commit("case/rebased", count + 1, count, "case/rebased.txt", "rebased")
            commit("case/behind", count + 2, count - 1, "case/behind.txt", "behind")
        }'
}

git init -q -b "$default" "$workDir/$repo"
cd "$workDir/$repo"
git config commit.gpgsign false
buildStream | git fast-import --quiet
git reset -q --hard
git remote add origin "https://github.com/$org/$repo.git"

gh repo create "$org/$repo" "--$visibility" --description "Synthetic large-history repository for the rebase check"
export ENV_FILE=$envFile
"$tools/gitOrg.sh" push origin "$default"
"$tools/gitOrg.sh" push origin case/rebased case/behind

# The first pushed branch becomes the default of an empty repository, but a repository setting could say otherwise.
current=$(gh api "repos/$org/$repo" --jq .default_branch 2> /dev/null || true)
[ "$current" = "$default" ] || gh api -X PATCH "repos/$org/$repo" -f default_branch="$default" --silent
echo "seeded $org/$repo ($visibility, default $default, $count commits)"
