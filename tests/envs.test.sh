#!/usr/bin/env bash
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
read="$root/tools/readSandboxOrg.sh"
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

org=$("$bashBin" "$read" "$root/envs/sandbox.json" 2>&1)
[ "$org" = "NoNamedOrg-workflow" ] && ok "RF17 the first sandbox environment names its org" || bad "sandbox.json: unexpected '$org'"

org=$("$bashBin" "$read" "$root/envs/sandboxB.json" 2>&1)
[ "$org" = "NoNamedOrg-workflow-b" ] && ok "RF17 the second sandbox environment names its org" || bad "sandboxB.json: unexpected '$org'"

"$bashBin" "$read" "$root/envs/starkbank.json" > /dev/null 2>&1
[ "$?" -eq 2 ] && ok "T-R33 the starkbank environment is refused by the seeding tools" || bad "the starkbank environment was accepted"

for file in "$root"/envs/*.json; do
    centralRepo=$(jq -r '.centralRepo // empty' "$file")
    [ -n "$centralRepo" ] && continue
    bad "$(basename "$file") has no centralRepo"
done
ok "every environment names a central repository"

echo "envs: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
