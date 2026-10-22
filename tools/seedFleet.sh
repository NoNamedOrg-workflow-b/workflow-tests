#!/usr/bin/env bash
# Seeds the synthetic fleet: many small repositories with the default branch names of the organisation, used to
# prove waves, exclusions and the runner time. Existing repositories are skipped, never reseeded, and each one is
# created only after its local history exists.
set -euo pipefail

if [ "$#" -ne 3 ]; then
    echo "usage: seedFleet.sh <envFile> <count> <workDirectory>" >&2
    exit 2
fi

# The tools below change directory, so a relative path would stop resolving.
envFile=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
count=$2
workDir=$3
tools=$(cd "$(dirname "$0")" && pwd)

if [ -z "${GH_TOKEN:-}" ]; then
    echo "GH_TOKEN is required" >&2
    exit 2
fi

org=$("$tools/readSandboxOrg.sh" "$envFile")
plan=$("$tools/fleetPlan.sh" "$count")
export ENV_FILE=$envFile

# The plan is read from descriptor 3 so a command inside the loop cannot swallow it from stdin.
while read -r name visibility default <&3; do
    if gh api "repos/$org/$name" > /dev/null 2>&1; then
        echo "$org/$name already exists; skipped"
        continue
    fi
    if [ -e "$workDir/$name" ]; then
        echo "$workDir/$name already exists locally; remove it first" >&2
        exit 2
    fi
    git init -q -b "$default" "$workDir/$name"
    (
        cd "$workDir/$name"
        git config user.name > /dev/null || git config user.name "scenario-builder"
        git config user.email > /dev/null || git config user.email "scenario-builder@example.com"
        git config commit.gpgsign false
        echo "synthetic fleet repository" > README.md
        git add README.md
        git commit -q -m "Add readme"
        git remote add origin "https://github.com/$org/$name.git"
        gh repo create "$org/$name" "--$visibility" --description "Synthetic fleet repository for the rebase check"
        "$tools/gitOrg.sh" push origin "$default"
    )
    echo "seeded $org/$name ($visibility, default $default)"
done 3<<< "$plan"
