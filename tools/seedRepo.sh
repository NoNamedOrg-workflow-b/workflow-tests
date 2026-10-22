#!/usr/bin/env bash
# Creates one synthetic repository in the sandbox org and seeds it with the scenario history. An existing
# repository is never touched: seeding twice would rewrite history somebody may already be testing against. The
# repository is created only after the whole local history exists, so a failure leaves nothing empty on GitHub.
set -euo pipefail

if [ "$#" -ne 5 ]; then
    echo "usage: seedRepo.sh <envFile> <repoName> <public|private> <defaultBranch> <workDirectory>" >&2
    exit 2
fi

# The tools below change directory, so a relative path would stop resolving.
envFile=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
repo=$2
visibility=$3
default=$4
workDir=$5
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

org=$("$tools/readSandboxOrg.sh" "$envFile")

if gh api "repos/$org/$repo" > /dev/null 2>&1; then
    echo "$org/$repo already exists; it is never seeded twice" >&2
    exit 2
fi

"$tools/buildScenarios.sh" "$workDir/$repo" "$default"
cd "$workDir/$repo"
git remote add origin "https://github.com/$org/$repo.git"

gh repo create "$org/$repo" "--$visibility" --description "Synthetic test repository for the rebase check"
export ENV_FILE=$envFile
"$tools/gitOrg.sh" push origin "$default"
"$tools/gitOrg.sh" push origin case/rebased case/behind case/merge-in case/merge-other case/conflict

# The first pushed branch becomes the default of an empty repository, but a repository setting could say otherwise.
current=$(gh api "repos/$org/$repo" --jq .default_branch 2> /dev/null || true)
[ "$current" = "$default" ] || gh api -X PATCH "repos/$org/$repo" -f default_branch="$default" --silent
echo "seeded $org/$repo ($visibility, default $default)"
