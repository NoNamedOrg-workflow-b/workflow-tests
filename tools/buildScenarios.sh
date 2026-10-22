#!/usr/bin/env bash
# Builds, in a new local repository, a default branch with a known history and the branches the end-to-end
# scenarios open pull requests from. Every commit is made before anything is pushed, so no commit ever lands on a
# default branch that already has a remote.
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: buildScenarios.sh <newDirectory> <defaultBranch>" >&2
    exit 2
fi

dir=$1
default=$2

if ! git check-ref-format --branch "$default" > /dev/null 2>&1; then
    echo "invalid branch name: $default" >&2
    exit 2
fi

# These names are used by the scenario branches or mean something else to git (@ is HEAD), and would build a wrong repo.
case "$default" in
    @ | HEAD | side | case | case/*)
        echo "reserved branch name: $default" >&2
        exit 2
        ;;
esac

if [ -e "$dir" ]; then
    echo "$dir already exists; the builder never overwrites" >&2
    exit 2
fi

git init -q -b "$default" "$dir"
cd "$dir"
git config user.name > /dev/null || git config user.name "scenario-builder"
git config user.email > /dev/null || git config user.email "scenario-builder@example.com"
git config commit.gpgsign false

addCommit() {
    printf '%s\n' "$2" > "$1"
    git add "$1"
    git commit -q -m "$3"
}

addCommit README.md "synthetic test repository" "Add readme"
addCommit notes.txt "notes" "Add notes"
printf 'line one\nline two\nline three\n' > shared.txt
git add shared.txt
git commit -q -m "Add shared file"
addCommit more.txt "more" "Add more"
addCommit more2.txt "more again" "Add more again"
fork=$(git rev-parse HEAD)

# Two commits the scenario branches that start at the fork point do not have, one of them touching shared.txt.
printf 'line one\nline two (changed on the default branch)\nline three\n' > shared.txt
git add shared.txt
git commit -q -m "Change the shared file on the default branch"
addCommit extra.txt "extra" "Add extra"

git checkout -q -b case/behind "$fork"
addCommit b.txt "b" "Add b"

git checkout -q -b case/conflict "$fork"
printf 'line one\nline two (changed on the branch)\nline three\n' > shared.txt
git add shared.txt
git commit -q -m "Change the shared file on the branch"

git checkout -q -b case/merge-in "$fork"
addCommit m.txt "m" "Add m"
git merge -q --no-ff -m "Merge $default into the branch" "$default"

git checkout -q -b side "$fork"
addCommit s.txt "s" "Add s"

git checkout -q -b case/rebased "$default"
addCommit r.txt "r" "Add r"

git checkout -q -b case/merge-other "$default"
addCommit o.txt "o" "Add o"
git merge -q --no-ff -m "Merge side into the branch" side

git checkout -q "$default"
