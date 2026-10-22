#!/usr/bin/env bash
# Applies one ruleset template to one organisation, creating it or updating it only when something we asked for
# differs, so running it twice is harmless. The operator must type the org they mean: the environment file alone
# is never enough to write to an organisation.
set -euo pipefail

usage() {
    echo "usage: applyRuleset.sh <envFile> <templateJson> <expectedOrg> [--dry-run]" >&2
    exit 2
}

[ "$#" -ge 3 ] && [ "$#" -le 4 ] || usage
envFile=$1
template=$2
expectedOrg=$3
dryRun=${4:-}
[ -z "$dryRun" ] || [ "$dryRun" = "--dry-run" ] || usage

here=$(cd "$(dirname "$0")" && pwd)

if [ -z "${GH_TOKEN:-}" ]; then
    echo "GH_TOKEN is required" >&2
    exit 2
fi

for file in "$envFile" "$template"; do
    [ -f "$file" ] && continue
    echo "file not found: $file" >&2
    exit 2
done

org=$(jq -er '.org | strings' "$envFile" 2> /dev/null) || org=""
centralRepo=$(jq -er '.centralRepo | strings' "$envFile" 2> /dev/null) || centralRepo=""
if ! [[ $org =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || ! [[ $centralRepo =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    echo "invalid environment file: $envFile" >&2
    exit 2
fi

if [ "$org" != "$expectedOrg" ]; then
    echo "the environment targets $org but $expectedOrg was expected; nothing was written" >&2
    exit 2
fi

enforcement=${ENFORCEMENT:-evaluate}
case "$enforcement" in
    evaluate | active | disabled) ;;
    *) echo "enforcement must be evaluate, active or disabled" >&2; exit 2 ;;
esac

# The ref lands inside a JSON document, so only plain branch and tag names are accepted.
workflowRef=${WORKFLOW_REF:-refs/heads/main}
if ! [[ $workflowRef =~ ^refs/(heads|tags)/[A-Za-z0-9._/-]+$ ]] || [[ $workflowRef == *..* || $workflowRef == *//* || $workflowRef == */ || $workflowRef == *__* ]]; then
    echo "invalid workflow ref: $workflowRef" >&2
    exit 2
fi

checkContext=${CHECK_CONTEXT:-}
if [ -n "$checkContext" ] && { ! [[ $checkContext =~ ^[A-Za-z0-9][A-Za-z0-9\ ./_-]*$ ]] || [[ $checkContext == *__* ]]; }; then
    echo "invalid check context" >&2
    exit 2
fi

# An empty context would be accepted by GitHub and then no check could ever satisfy the rule.
if grep -q '__CHECK_CONTEXT__' "$template" && [ -z "$checkContext" ]; then
    echo "CHECK_CONTEXT is required by this template" >&2
    exit 2
fi

repoId=$(gh api "repos/$org/$centralRepo" --jq .id)
if ! [[ $repoId =~ ^[0-9]+$ ]]; then
    echo "could not resolve the id of $org/$centralRepo" >&2
    exit 2
fi

wanted=$(sed -e "s/__ENFORCEMENT__/$enforcement/" -e "s#__WORKFLOW_REF__#$workflowRef#" \
    -e "s/__CENTRAL_REPO_ID__/$repoId/" -e "s#__CHECK_CONTEXT__#$checkContext#" "$template" | jq -S .)

if echo "$wanted" | grep -q '__'; then
    echo "the template still has an unresolved placeholder" >&2
    exit 2
fi

name=$(echo "$wanted" | jq -r .name)
listing=$(gh api "orgs/$org/rulesets" --paginate --slurp)
id=$(echo "$listing" | jq -r --arg name "$name" 'add // [] | map(select(.name == $name)) | first.id // empty')

action=create
if [ -n "$id" ]; then
    stored=$(gh api "orgs/$org/rulesets/$id")
    shaped=$(echo "$stored" | jq -S --argjson wanted "$wanted" -f "$here/rulesetShape.jq")
    target=$(echo "$wanted" | jq -S '.rules |= sort_by(.type)')
    if [ "$shaped" = "$target" ]; then
        echo "unchanged: $name ($id) in $org"
        exit 0
    fi
    action=update
fi

if [ "$dryRun" = "--dry-run" ]; then
    echo "would $action: $name in $org"
    exit 0
fi

body=$(mktemp)
trap 'rm -f "$body"' EXIT
echo "$wanted" > "$body"

if [ "$action" = "create" ]; then
    newId=$(gh api -X POST "orgs/$org/rulesets" --input "$body" | jq -r .id)
    echo "created: $name ($newId) in $org"
    exit 0
fi

gh api -X PUT "orgs/$org/rulesets/$id" --input "$body" > /dev/null
echo "updated: $name ($id) in $org"
