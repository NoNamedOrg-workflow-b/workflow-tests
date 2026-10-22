#!/usr/bin/env bash
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
plan="$root/tools/fleetPlan.sh"
bashBin=${BASH_BIN:-bash}
passed=0
failed=0

ok() {
    passed=$((passed + 1))
    echo "PASS $1"
}

bad() {
    failed=$((failed + 1))
    echo "FAIL $1"
}

lines=$("$bashBin" "$plan" 15 2>&1)
status=$?

[ "$status" -eq 0 ] && [ "$(echo "$lines" | wc -l | tr -d ' ')" -eq 15 ] && ok "15 repositories are planned" || bad "wrong number of repositories (exit $status)"
echo "$lines" | head -n 1 | grep -q "^test-fleet-01 " && ok "names start at test-fleet-01" || bad "unexpected first name"
echo "$lines" | tail -n 1 | grep -q "^test-fleet-15 " && ok "names end at test-fleet-15" || bad "unexpected last name"
[ "$(echo "$lines" | cut -d' ' -f1 | sort -u | wc -l | tr -d ' ')" -eq 15 ] && ok "names are unique" || bad "duplicate names"
for default in development master main v2; do
    echo "$lines" | cut -d' ' -f3 | grep -q "^$default$" && ok "default branch $default is covered" || bad "default branch $default is missing"
done
echo "$lines" | cut -d' ' -f2 | grep -q "^public$" && echo "$lines" | cut -d' ' -f2 | grep -q "^private$" && ok "both visibilities are covered" || bad "visibility is not mixed"
[ $(($(echo "$lines" | cut -d' ' -f2 | grep -c '^public$') * 5)) -le 15 ] && ok "most repositories are private, as in the organisation" || bad "too many public repositories"
[ "$("$bashBin" "$plan" 15)" = "$lines" ] && ok "the plan is deterministic" || bad "the plan changes between runs"

for padded in 08 09 010; do
    got=$("$bashBin" "$plan" "$padded" 2>&1)
    want=$((10#$padded))
    [ "$?" -eq 0 ] && [ "$(echo "$got" | wc -l | tr -d ' ')" -eq "$want" ] && ok "count $padded is read as decimal ($want repositories)" || bad "count $padded was mis-read"
done

for invalid in 0 00 -1 abc 101 ""; do
    "$bashBin" "$plan" "$invalid" > /dev/null 2>&1
    [ "$?" -eq 2 ] && ok "count '$invalid' is rejected" || bad "count '$invalid' was accepted"
done

echo "fleetPlan: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
