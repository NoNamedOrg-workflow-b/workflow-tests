#!/usr/bin/env bash
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
apply="$root/tools/applyRuleset.sh"
template="$root/rulesets/rebaseWorkflowOnly.json"
full="$root/rulesets/rebaseRuleset.json"
bashBin=${BASH_BIN:-bash}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
passed=0
failed=0

echo '{"environment":"sandbox","org":"NoNamedOrg-workflow","centralRepo":"workflow-tests"}' > "$work/env.json"

ok() {
    passed=$((passed + 1))
    echo "PASS $1"
}

bad() {
    failed=$((failed + 1))
    echo "FAIL $1"
    [ -z "${2:-}" ] || echo "$2" | sed 's/^/    /'
}

# Only the GitHub API is faked: it answers the repository id, the listing and the stored ruleset from fixtures and
# keeps the body of every write so the tests can read what would have been sent.
mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "$STUB_LOG"
args="$*"
case "$args" in
    *"-X POST"*|*"-X PUT"*)
        previous=""
        for a in "$@"; do
            [ "$previous" = "--input" ] && cp "$a" "$STUB_BODY"
            previous=$a
        done
        echo '{"id": 555}'
        exit 0
        ;;
    "api repos/"*) [ "${STUB_FAIL:-}" = "repo" ] && exit 1; echo "${STUB_REPO_ID:-4242}"; exit 0 ;;
    "api orgs/"*"/rulesets/"*) cat "$STUB_STORED"; exit 0 ;;
    "api orgs/"*"/rulesets"*)
        [ "${STUB_FAIL:-}" = "list" ] && exit 1
        case "$args" in *"--paginate"*"--slurp"*) ;; *) echo "listing must use --paginate --slurp" >&2; exit 1 ;; esac
        cat "$STUB_LIST"
        exit 0
        ;;
esac
exit 0
STUB
chmod +x "$work/bin/gh"

run() {
    : > "$work/calls.log"
    rm -f "$work/body.json"
    output=$(cd "$work" && env PATH="$work/bin:$PATH" STUB_LOG="$work/calls.log" STUB_BODY="$work/body.json" \
        STUB_LIST="$work/list.json" STUB_STORED="$work/stored.json" GH_TOKEN=t "$@" 2>&1)
    status=$?
    calls=$(cat "$work/calls.log")
}

expect() {
    [ "$status" -eq "$2" ] && { ok "$1"; return 0; }
    bad "$1 (exit $status, wanted $2)" "$output"
}

has() {
    echo "$3" | grep -q -F -- "$2" && return 0
    bad "$1: missing '$2'" "$3"
}

lacks() {
    echo "$3" | grep -q -F -- "$2" || return 0
    bad "$1: unexpected '$2'" "$3"
}

echo '[[]]' > "$work/list.json"

run "$bashBin" "$apply" "$work/env.json" "$template" NoNamedOrg-workflow
expect "a new ruleset is created" 0
has "reports the creation" "created" "$output"
has "creates through the API" "-X POST orgs/NoNamedOrg-workflow/rulesets" "$calls"
[ "$(jq -r '.enforcement' "$work/body.json")" = "evaluate" ] && ok "the default enforcement is evaluate" || bad "the default enforcement is not evaluate"
[ "$(jq -r '.rules[0].parameters.workflows[0].repository_id' "$work/body.json")" = "4242" ] && ok "the central repository id is resolved from the API" || bad "the repository id was not resolved" "$(cat "$work/body.json")"
[ "$(jq -r '.rules[0].parameters.workflows[0].ref' "$work/body.json")" = "refs/heads/main" ] && ok "the default workflow ref is the main branch" || bad "unexpected default ref"
[ -s "$work/body.json" ] && ! grep -q '__' "$work/body.json" && ok "no placeholder is left in the body" || bad "a placeholder was left in the body, or no body was sent" "$(cat "$work/body.json" 2>/dev/null)"
cp "$work/body.json" "$work/created.json"

run "$bashBin" "$apply" "$work/env.json" "$template" starkbank
expect "T-R33-a an org different from the expected one aborts" 2
lacks "T-R33-a no API call is made" "gh " "$calls"

run "$bashBin" "$apply" "$work/env.json" "$template" NoNamedOrg-workflow
expect "T-R33-b the expected org passes the assertion" 0

echo '{"environment":"starkbank","org":"<orgName>","centralRepo":"<centralRepoName>"}' > "$work/placeholder.json"
run "$bashBin" "$apply" "$work/placeholder.json" "$template" "<orgName>"
expect "T-R33 an environment still holding placeholders aborts" 2
lacks "no API call from a placeholder environment" "gh " "$calls"

run "$bashBin" "$apply" "$work/env.json" "$template"
expect "T-R33 the expected org is mandatory" 2

jq '. + {id: 777, source_type: "Organization", source: "NoNamedOrg-workflow", created_at: "x"} | .rules[0].parameters.workflows[0] += {sha: null}' "$work/created.json" > "$work/stored.json"
jq '[[{id: 777, name: .name}]]' "$work/stored.json" > "$work/list.json"
run "$bashBin" "$apply" "$work/env.json" "$template" NoNamedOrg-workflow
expect "T-RF16-a applying the same ruleset twice changes nothing" 0
has "says unchanged" "unchanged" "$output"
lacks "T-RF16-a no write is made" "-X P" "$calls"

run env ENFORCEMENT=active "$bashBin" "$apply" "$work/env.json" "$template" NoNamedOrg-workflow
expect "a different enforcement updates the ruleset" 0
has "updates through the API" "-X PUT orgs/NoNamedOrg-workflow/rulesets/777" "$calls"
[ "$(jq -r '.enforcement' "$work/body.json")" = "active" ] && ok "the update carries the new enforcement" || bad "the update did not carry the enforcement"

run env WORKFLOW_REF=refs/tags/v1 "$bashBin" "$apply" "$work/env.json" "$template" NoNamedOrg-workflow
expect "a different workflow ref updates the ruleset" 0
[ "$(jq -r '.rules[0].parameters.workflows[0].ref' "$work/body.json")" = "refs/tags/v1" ] && ok "T-R9-a the ref can be a tag" || bad "the tag ref was not applied"

run env ENFORCEMENT=active "$bashBin" "$apply" "$work/env.json" "$template" NoNamedOrg-workflow --dry-run
expect "a dry run with a difference succeeds" 0
has "the dry run says it would update" "would update" "$output"
lacks "a dry run writes nothing" "-X P" "$calls"
echo '[[]]' > "$work/list.json"
run "$bashBin" "$apply" "$work/env.json" "$template" NoNamedOrg-workflow --dry-run
has "the dry run says it would create" "would create" "$output"
lacks "a dry run never creates" "-X P" "$calls"
jq '[[{id: 777, name: .name}]]' "$work/stored.json" > "$work/list.json"

run env ENFORCEMENT=blocking "$bashBin" "$apply" "$work/env.json" "$template" NoNamedOrg-workflow
expect "an unknown enforcement aborts" 2

run env WORKFLOW_REF='refs/heads/x";evil' "$bashBin" "$apply" "$work/env.json" "$template" NoNamedOrg-workflow
expect "a hostile workflow ref aborts" 2

: > "$work/calls.log"
output=$(cd "$work" && env -u GH_TOKEN PATH="$work/bin:$PATH" STUB_LOG="$work/calls.log" "$bashBin" "$apply" "$work/env.json" "$template" NoNamedOrg-workflow 2>&1)
status=$?
expect "a missing token aborts" 2
[ ! -s "$work/calls.log" ] && ok "a missing token makes no API call" || bad "an API call was made without a token"

run env CHECK_CONTEXT=rebase-status "$bashBin" "$apply" "$work/env.json" "$full" NoNamedOrg-workflow
echo '[[]]' > "$work/list.json"
run env CHECK_CONTEXT=rebase-status "$bashBin" "$apply" "$work/env.json" "$full" NoNamedOrg-workflow
has "the full ruleset is created, not updated" "-X POST orgs/NoNamedOrg-workflow/rulesets" "$calls"
expect "T-RF12-a the full ruleset is created with the measured check context" 0
rules=$(jq -c '[.rules[]|.type]|sort' "$work/body.json" 2>/dev/null)
[ "$rules" = '["pull_request","required_status_checks","workflows"]' ] && ok "T-RF12-a workflows, required_status_checks and pull_request are all there" || bad "unexpected rules: $rules"
[ "$(jq -r '.rules[]|select(.type=="required_status_checks")|.parameters.required_status_checks[0].context' "$work/body.json")" = "rebase-status" ] && ok "T-RF12-a the context is the measured one" || bad "the context was not applied"
[ "$(jq -r '.rules[]|select(.type=="required_status_checks")|.parameters.strict_required_status_checks_policy' "$work/body.json")" = "true" ] && ok "T-RF12-a strict is on" || bad "strict is off"
[ "$(jq -r '.rules[]|select(.type=="required_status_checks")|.parameters.required_status_checks[0].integration_id' "$work/body.json")" = "15368" ] && ok "T-R64-a only the GitHub Actions app can satisfy the check" || bad "the check can be satisfied by any app"
[ "$(jq -c '.rules[]|select(.type=="pull_request")|.parameters.allowed_merge_methods' "$work/body.json")" = '["merge"]' ] && ok "T-R39-a only merge commits are allowed" || bad "merge methods are not restricted"
cp "$work/body.json" "$work/created-full.json"

run "$bashBin" "$apply" "$work/env.json" "$full" NoNamedOrg-workflow
expect "T-RF12-a the full template without a check context aborts instead of sending an empty one" 2
lacks "nothing is written without a context" "-X P" "$calls"

# What GitHub stores: our body plus fields it fills in. These must not count as a difference.
withDefaults='. + {id: 9, node_id: "n", source_type: "Organization", source: "o", created_at: "x", updated_at: "y", current_user_can_bypass: "never"}
    | (.rules[] | select(.type == "pull_request") | .parameters) += {require_extra_approval_for_unattributed_changes: true, dismissal_restriction: {enabled: false, allowed_actors: []}, required_reviewers: []}
    | (.rules[] | select(.type == "workflows") | .parameters.workflows[0]) += {sha: null}'

applyAgainst() {
    local label=$1 filter=$2 wanted=$3
    jq "$withDefaults | $filter" "$work/created-full.json" > "$work/stored.json"
    jq '[[{id: 9, name: .name}]]' "$work/stored.json" > "$work/list.json"
    run env CHECK_CONTEXT=rebase-status "$bashBin" "$apply" "$work/env.json" "$full" NoNamedOrg-workflow
    if [ "$wanted" = "unchanged" ]; then
        echo "$output" | grep -q "unchanged" && ok "$label" || bad "$label: expected unchanged" "$output"
        return 0
    fi
    echo "$calls" | grep -q -F -- "-X PUT orgs/NoNamedOrg-workflow/rulesets/9" && ok "$label" || bad "$label: expected an update" "$output"
}

applyAgainst "T-RF16-a fields GitHub fills in are not a difference" '.' unchanged
applyAgainst "the order of the stored rules is not a difference" '.rules |= reverse' unchanged
applyAgainst "T-R9 a pinned sha stored by somebody is a difference" '(.rules[] | select(.type == "workflows") | .parameters.workflows[0]).sha = "deadbeef"' update
applyAgainst "an extra stored condition is a difference" '.conditions.repository_name.protected = true' update
applyAgainst "an extra stored reviewer requirement is a difference" '(.rules[] | select(.type == "pull_request") | .parameters).required_reviewers = [{"reviewer": {"id": 1, "type": "Team"}}]' update
applyAgainst "an extra stored rule is a difference" '.rules += [{type: "deletion"}]' update
applyAgainst "a missing stored rule is a difference" '.rules |= map(select(.type != "pull_request"))' update
applyAgainst "a stored bypass actor is a difference" '.bypass_actors = [{actor_id: 1, actor_type: "OrganizationAdmin", bypass_mode: "always"}]' update
applyAgainst "an extra included repository pattern is a difference" '.conditions.repository_name.include += ["other-*"]' update
applyAgainst "a flipped boolean is a difference" '(.rules[] | select(.type == "required_status_checks") | .parameters).strict_required_status_checks_policy = false' update
applyAgainst "a stored allowed merge method that we did not ask for is a difference" '(.rules[] | select(.type == "pull_request") | .parameters).allowed_merge_methods += ["squash"]' update

# The listing has two pages and the ruleset we want is on the second one.
jq "$withDefaults" "$work/created-full.json" > "$work/stored.json"
jq '[[{id: 1, name: "another"}], [{id: 9, name: .name}]]' "$work/stored.json" > "$work/list.json"
run env CHECK_CONTEXT=rebase-status "$bashBin" "$apply" "$work/env.json" "$full" NoNamedOrg-workflow
echo "$output" | grep -q "unchanged: .* (9)" && ok "the ruleset found on the second page of the listing is used" || bad "pagination: the ruleset on page two was not found" "$output"

run env STUB_FAIL=list CHECK_CONTEXT=rebase-status "$bashBin" "$apply" "$work/env.json" "$full" NoNamedOrg-workflow
[ "$status" -ne 0 ] && ok "a failing listing aborts" || bad "a failing listing was ignored"
lacks "a failing listing writes nothing" "-X P" "$calls"

run env STUB_FAIL=repo CHECK_CONTEXT=rebase-status "$bashBin" "$apply" "$work/env.json" "$full" NoNamedOrg-workflow
[ "$status" -ne 0 ] && ok "a failing repository lookup aborts" || bad "a failing repository lookup was ignored"
lacks "a failing repository lookup writes nothing" "-X P" "$calls"

run env STUB_REPO_ID=abc CHECK_CONTEXT=rebase-status "$bashBin" "$apply" "$work/env.json" "$full" NoNamedOrg-workflow
expect "a repository id that is not a number aborts" 2

echo '[[]]' > "$work/list.json"
for hostile in 'a"b' 'a&b' 'a#b' 'a\b' 'a__b' "$(printf 'a\nb')"; do
    run env CHECK_CONTEXT="$hostile" "$bashBin" "$apply" "$work/env.json" "$full" NoNamedOrg-workflow
    [ "$status" -eq 2 ] && ok "a hostile check context is refused" || bad "a hostile check context was accepted: $hostile" "$output"
done
for badRef in refs/heads/../../x refs/heads/a//b refs/heads/a/ 'refs/heads/a b' refs/heads/x__y; do
    run env WORKFLOW_REF="$badRef" "$bashBin" "$apply" "$work/env.json" "$template" NoNamedOrg-workflow
    [ "$status" -eq 2 ] && ok "the workflow ref '$badRef' is refused" || bad "the workflow ref '$badRef' was accepted" "$output"
done

run env CHECK_CONTEXT="rebase / rebase-status" "$bashBin" "$apply" "$work/env.json" "$full" NoNamedOrg-workflow
expect "a check context with the workflow name and a slash is legitimate" 0

printf '{"name":"x","enforcement":"__ENFORCEMENT__","unknown":"__SOMETHING_ELSE__","a":"__ENFORCEMENT__ __ENFORCEMENT__"}' > "$work/odd.json"
run "$bashBin" "$apply" "$work/env.json" "$work/odd.json" NoNamedOrg-workflow
expect "a placeholder outside the known list aborts before any write" 2
lacks "an unknown placeholder writes nothing" "-X P" "$calls"

echo "applyRuleset: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
