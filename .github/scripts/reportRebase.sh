#!/usr/bin/env bash
# Effect only: a label and a sticky comment. The verdict is decided elsewhere, so a failure here must never
# turn a red check green or a green one red (a read-only token on a fork pull request cannot write).
set -uo pipefail

for name in REPO NUMBER BASE OK REASON; do
    [ -n "${!name:-}" ] && continue
    echo "missing variable: $name" >&2
    exit 2
done

case "$OK" in
    true | false) ;;
    *) echo "OK must be true or false" >&2; exit 2 ;;
esac

marker="<!-- rebase-guard-org -->"
label="rebase-required"
fence='```'

warn() {
    echo "::warning::$1"
}

# A listing that cannot be read could hide an existing comment, and guessing would post a duplicate.
if ! listing=$(gh api "repos/$REPO/issues/$NUMBER/comments" --paginate --slurp 2> /dev/null); then
    warn "could not list the comments of #$NUMBER; the rebase report was skipped"
    exit 0
fi

# Only the bot's own comment counts: anyone could quote the marker to redirect the report.
if ! previousId=$(echo "$listing" | jq -r --arg marker "$marker" \
    'add | map(select(.user.login == "github-actions[bot]" and ((.body // "") | startswith($marker)))) | last.id // empty' 2> /dev/null); then
    warn "the comments of #$NUMBER could not be read; the rebase report was skipped"
    exit 0
fi

upsertComment() {
    if [ -z "$previousId" ]; then
        gh api -X POST "repos/$REPO/issues/$NUMBER/comments" -f body="$1" --silent \
            || warn "could not create the rebase comment on #$NUMBER"
        return 0
    fi
    gh api -X PATCH "repos/$REPO/issues/comments/$previousId" -f body="$1" --silent \
        || warn "could not update the rebase comment on #$NUMBER"
}

if [ "$OK" = "true" ]; then
    [ -z "$previousId" ] || upsertComment "$marker
✅ **Rebase OK** — $REASON"
    gh api -X DELETE "repos/$REPO/issues/$NUMBER/labels/$label" --silent 2> /dev/null || true
    exit 0
fi

# A branch name may contain shell syntax, and this snippet is pasted into a terminal.
quotedBase=$(printf '%q' "origin/$BASE")

upsertComment "$marker
❌ **Branch is not rebased** — $REASON

${fence}bash
git fetch origin
git rebase $quotedBase
git push --force-with-lease
${fence}

Do not use the **Update branch** button: it merges the base branch into yours, which this check rejects."

gh api -X POST "repos/$REPO/issues/$NUMBER/labels" -f "labels[]=$label" --silent \
    || warn "could not apply the $label label on #$NUMBER"
exit 0
