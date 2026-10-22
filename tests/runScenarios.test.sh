#!/usr/bin/env bash
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
runner="$root/tools/runScenarios.sh"
registry="$root/tools/cases.tsv"
bashBin=${BASH_BIN:-bash}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
passed=0
failed=0
tab=$(printf '\t')

ok() {
    passed=$((passed + 1))
    echo "PASS $1"
}

bad() {
    failed=$((failed + 1))
    echo "FAIL $1"
    [ -z "${2:-}" ] || echo "$2" | sed 's/^/    /'
}

# The fake suite replays a fixture, so no test here ever starts the real suites.
cat > "$work/fakeSuite.sh" <<STUB
#!/usr/bin/env bash
cat "$work/suite.out"
STUB
chmod +x "$work/fakeSuite.sh"

writeCases() {
    printf 'caso\trisco\ttipo\tme\tgatilho\n' > "$work/cases.tsv"
    local row
    for row in "$@"; do
        printf '%s\n' "$row" | tr ' ' '\t' >> "$work/cases.tsv"
    done
}

writeResults() {
    printf 'caso\tresultado\tevidencia\n' > "$work/results.tsv"
    local row
    for row in "$@"; do
        printf '%b\n' "$row" >> "$work/results.tsv"
    done
}

run() {
    output=$(RUN_TESTS="$work/fakeSuite.sh" "$bashBin" "$runner" "$@" 2> "$work/stderr.log" < /dev/null)
    status=$?
    errors=$(cat "$work/stderr.log")
}

runSuite() {
    output=$(RUN_TESTS="$work/fakeSuite.sh" "$bashBin" "$runner" "$@" 2> "$work/stderr.log" < /dev/null)
    status=$?
    errors=$(cat "$work/stderr.log")
}

expectLine() {
    local name=$1 line=$2
    if echo "$output" | grep -q -x -F -- "$line"; then
        ok "$name"
        return 0
    fi
    bad "$name: missing line '$line'" "$output"
}

expectStatus() {
    [ "$status" -eq "$2" ] && { ok "$1"; return 0; }
    bad "$1 (exit $status, wanted $2)" "$output $errors"
}

writeCases "T-A-a RA L 1 sempre"
printf 'PASS T-A-a something\n' > "$work/suite.out"
runSuite --cases "$work/cases.tsv"
expectLine "an L case passes on its PASS line" "PASS${tab}T-A-a${tab}L${tab}"
expectLine "the summary counts the pass" "summary: PASS 1, FAIL 0, N-A 0, PENDING 0, R 0, total 1"
expectStatus "an all-pass registry exits 0" 0

printf 'PASS T-A-a something\nFAIL T-A-a something broke\n' > "$work/suite.out"
runSuite --cases "$work/cases.tsv"
expectLine "an L case with a FAIL line fails even with a PASS line" "FAIL${tab}T-A-a${tab}L${tab}"
expectStatus "an L failure exits 1" 1

printf 'PASS T-B-z other\n' > "$work/suite.out"
runSuite --cases "$work/cases.tsv"
expectLine "an L case without a line is pending" "PENDING${tab}T-A-a${tab}L${tab}no PASS line"
expectStatus "a pending L case exits 1" 1

writeCases "T-R1 R1 L 1 sempre" "T-R10-a R10 L 1 sempre"
printf 'PASS T-R10-a long\nFAIL T-R1x nope\n' > "$work/suite.out"
runSuite --cases "$work/cases.tsv"
expectLine "T-R1 does not match the line of T-R10-a" "PENDING${tab}T-R1${tab}L${tab}no PASS line"
expectLine "T-R10-a matches its own line" "PASS${tab}T-R10-a${tab}L${tab}"

writeCases "T-E-a RE E 4 sempre"
writeResults "T-E-a\tPASS\tlog at run 123"
run --cases "$work/cases.tsv" --results "$work/results.tsv"
expectLine "an E case passes with a result and evidence" "PASS${tab}T-E-a${tab}E${tab}log at run 123"
expectStatus "an E pass exits 0" 0

writeResults
run --cases "$work/cases.tsv" --results "$work/results.tsv"
expectLine "an E case without a row is pending" "PENDING${tab}T-E-a${tab}E${tab}no result"
expectStatus "a missing row exits 1" 1

writeResults "T-E-a\tPASS\t"
run --cases "$work/cases.tsv" --results "$work/results.tsv"
expectLine "a PASS without evidence is pending" "PENDING${tab}T-E-a${tab}E${tab}no evidence"

writeResults "T-E-a\tN/A\tnot applicable in this env"
run --cases "$work/cases.tsv" --results "$work/results.tsv"
expectLine "an N/A with a reason is N-A" "N-A${tab}T-E-a${tab}E${tab}not applicable in this env"
expectLine "the summary counts the N-A" "summary: PASS 0, FAIL 0, N-A 1, PENDING 0, R 0, total 1"
expectStatus "an N/A exits 0" 0

writeResults "T-E-a\tN/A\t"
run --cases "$work/cases.tsv" --results "$work/results.tsv"
expectLine "an N/A without a reason is pending" "PENDING${tab}T-E-a${tab}E${tab}no evidence"

writeResults "T-E-a\tFAIL\tbroke" "T-E-a\tPASS\tfixed"
run --cases "$work/cases.tsv" --results "$work/results.tsv"
expectLine "the last row of a case wins" "PASS${tab}T-E-a${tab}E${tab}fixed"

writeResults "T-E-a\tFAIL\tbroke"
run --cases "$work/cases.tsv" --results "$work/results.tsv"
expectLine "an E failure is reported" "FAIL${tab}T-E-a${tab}E${tab}broke"
expectStatus "an E failure exits 1" 1

writeCases "T-E-a RE E 4 sempre"
printf 'PASS T-E-a local line\n' > "$work/suite.out"
runSuite --cases "$work/cases.tsv"
expectLine "a local suite line never counts for an E case" "PENDING${tab}T-E-a${tab}E${tab}no result"

writeCases "T-R-a RR R 7 sempre" "T-A-a RA E 4 sempre"
writeResults "T-A-a\tPASS\tok"
run --cases "$work/cases.tsv" --results "$work/results.tsv"
expectLine "an R case is printed as R" "R${tab}T-R-a${tab}R${tab}"
expectLine "an R case stays out of the totals" "summary: PASS 1, FAIL 0, N-A 0, PENDING 0, R 1, total 1"
expectStatus "an R case does not change the exit code" 0

writeCases "T-A-a RA E 4/5 sempre" "T-B-a RB E 5 sempre" "T-C-a RC E 0/7 sempre" "T-D-a RD E 45 sempre"
writeResults "T-A-a\tPASS\tok" "T-B-a\tPASS\tok" "T-C-a\tPASS\tok" "T-D-a\tPASS\tok"
run --cases "$work/cases.tsv" --results "$work/results.tsv" --me 4
expectLine "--me 4 keeps a case listed as 4/5" "PASS${tab}T-A-a${tab}E${tab}ok"
echo "$output" | grep -q "T-B-a" && bad "--me 4 kept a case of ME 5" "$output" || ok "--me 4 drops a case of ME 5"
echo "$output" | grep -q "T-D-a" && bad "--me 4 matched 45 as a substring" "$output" || ok "--me matches the whole field item, not a substring"
expectLine "--me counts only the selected cases" "summary: PASS 1, FAIL 0, N-A 0, PENDING 0, R 0, total 1"
run --cases "$work/cases.tsv" --results "$work/results.tsv" --me 7
expectLine "--me 7 keeps a case listed as 0/7" "PASS${tab}T-C-a${tab}E${tab}ok"
run --cases "$work/cases.tsv" --me x
expectStatus "a non-numeric --me is a usage error" 2
run --cases "$work/cases.tsv" --me 9
expectStatus "a filter that selects nothing is an error, not a pass" 2

writeCases "T-A-a RA E 4 sempre"
writeResults "T-A-a\tPASS\tok" "T-GHOST-a\tPASS\tok"
run --cases "$work/cases.tsv" --results "$work/results.tsv"
echo "$errors" | grep -q "T-GHOST-a" && ok "a result for an unknown case warns on stderr" || bad "no warning for an unknown case" "$errors"
expectStatus "an unknown case is not an error" 0

run --cases "$work/missing.tsv"
expectStatus "a missing cases file exits 2" 2
echo "$errors" | grep -q "not found" && ok "the missing cases file is explained on stderr" || bad "no message for the missing cases file" "$errors"
run --cases "$work/cases.tsv" --results "$work/missing.tsv"
expectStatus "a missing results file exits 2" 2
run --bogus
expectStatus "an unknown option exits 2" 2
echo "$errors" | grep -q "usage:" && ok "a usage error prints usage" || bad "no usage message" "$errors"

# Only a verdict at column 0 counts: indented lines are the output of a command inside a failing test.
writeCases "T-C-a RC L 1 sempre"
printf 'FAIL other\n    PASS T-C-a\n' > "$work/suite.out"
runSuite --cases "$work/cases.tsv"
expectLine "an indented PASS line is not a verdict" "PENDING${tab}T-C-a${tab}L${tab}no PASS line"
printf 'PASS T-C-a ok\n    FAIL T-C-a inner\n' > "$work/suite.out"
runSuite --cases "$work/cases.tsv"
expectLine "an indented FAIL line does not fail a passed case" "PASS${tab}T-C-a${tab}L${tab}"

esc=$(printf '\033')
printf '%s[32mPASS%s[0m T-C-a ok\n' "$esc" "$esc" > "$work/suite.out"
runSuite --cases "$work/cases.tsv"
expectLine "a coloured PASS line counts" "PASS${tab}T-C-a${tab}L${tab}"
printf 'PASS T-C-a ok\n%s[1;31mFAIL%s[0m T-C-a broke\n' "$esc" "$esc" > "$work/suite.out"
runSuite --cases "$work/cases.tsv"
expectLine "a coloured FAIL line counts" "FAIL${tab}T-C-a${tab}L${tab}"

writeCases "T-R-a RR R 7 sempre"
run --cases "$work/cases.tsv"
expectLine "a selection of only R cases reports them apart" "summary: PASS 0, FAIL 0, N-A 0, PENDING 0, R 1, total 0"
expectStatus "a selection of only R cases exits 0" 0

# Registry and results files are validated before anything runs.
badRegistry() {
    local name=$1 content=$2
    printf '%b' "$content" > "$work/bad.tsv"
    run --cases "$work/bad.tsv"
    expectStatus "$name" 2
}
badRegistry "a registry with another header exits 2" 'id\trisco\ttipo\tme\tgatilho\nA\tR\tL\t1\tsempre\n'
badRegistry "a registry row with 4 fields exits 2" 'caso\trisco\ttipo\tme\tgatilho\nA\tR\tL\t1\n'
badRegistry "a registry row with 6 fields exits 2" 'caso\trisco\ttipo\tme\tgatilho\nA\tR\tL\t1\tsempre\textra\n'
badRegistry "a registry row with an unknown tipo exits 2" 'caso\trisco\ttipo\tme\tgatilho\nA\tR\tX\t1\tsempre\n'
badRegistry "a registry row with a malformed me exits 2" 'caso\trisco\ttipo\tme\tgatilho\nA\tR\tL\t1//2\tsempre\n'
badRegistry "a registry with a duplicate id exits 2" 'caso\trisco\ttipo\tme\tgatilho\nA\tR\tL\t1\tsempre\nA\tR\tL\t1\tsempre\n'
echo "$errors" | grep -q "duplicate" && ok "the duplicate id is named on stderr" || bad "no message for the duplicate id" "$errors"

writeCases "T-E-a RE E 4 sempre"
printf 'caso\tfoo\tevidencia\nT-E-a\tPASS\tok\n' > "$work/results.tsv"
run --cases "$work/cases.tsv" --results "$work/results.tsv"
expectStatus "a results file with another header exits 2" 2

printf 'caso\trisco\ttipo\tme\tgatilho\r\nT-E-a\tRE\tE\t4\tsempre\r\n' > "$work/crlf.tsv"
printf 'caso\tresultado\tevidencia\r\nT-E-a\tPASS\tok\r\n' > "$work/crlfResults.tsv"
run --cases "$work/crlf.tsv" --results "$work/crlfResults.tsv"
expectLine "CRLF files are read as LF files" "PASS${tab}T-E-a${tab}E${tab}ok"

# A backslash in a path must reach awk untouched.
mkdir -p "$work/back\\slash"
writeCases "T-E-a RE E 4 sempre"
writeResults "T-E-a\tPASS\tok"
cp "$work/cases.tsv" "$work/back\\slash/cases.tsv"
cp "$work/results.tsv" "$work/back\\slash/results.tsv"
run --cases "$work/back\\slash/cases.tsv" --results "$work/back\\slash/results.tsv"
expectLine "paths with a backslash are read" "PASS${tab}T-E-a${tab}E${tab}ok"

# The default registry must be found from any directory.
printf 'PASS T-R35-a x\n' > "$work/suite.out"
output=$(cd "$work" && RUN_TESTS="$work/fakeSuite.sh" "$bashBin" "$runner" --me 1 2> /dev/null < /dev/null)
echo "$output" | grep -q "T-R35-a" && ok "the default registry sits next to the script" || bad "the default registry was not found from another directory" "$output"

# Registry sanity on the real file.
header=$(head -n 1 "$registry")
[ "$header" = "caso${tab}risco${tab}tipo${tab}me${tab}gatilho" ] && ok "the registry header has the five columns" || bad "unexpected registry header: $header"
wrongWidth=$(awk -F'\t' 'NR > 1 && NF != 5 { print NR }' "$registry" | tr '\n' ' ')
[ -z "$wrongWidth" ] && ok "every registry row has 5 columns" || bad "rows without 5 columns: $wrongWidth"
duplicates=$(awk -F'\t' 'NR > 1 && seen[$1]++ { print $1 }' "$registry" | tr '\n' ' ')
[ -z "$duplicates" ] && ok "registry ids are unique" || bad "duplicate ids: $duplicates"
wrongType=$(awk -F'\t' 'NR > 1 && $3 !~ /^[LEMDR]$/ { print $1 }' "$registry" | tr '\n' ' ')
[ -z "$wrongType" ] && ok "every tipo is one of L, E, M, D, R" || bad "invalid tipo: $wrongType"
wrongMe=$(awk -F'\t' 'NR > 1 && $4 !~ /^[0-9]+(\/[0-9]+)*$/ { print $1 }' "$registry" | tr '\n' ' ')
[ -z "$wrongMe" ] && ok "every me field is numbers separated by a slash" || bad "invalid me: $wrongMe"
for me in 0 1 2 3 4 5 6 7 8; do
    awk -F'\t' -v me="$me" 'NR > 1 { n = split($4, parts, "/"); for (i = 1; i <= n; i++) if (parts[i] == me) found = 1 } END { exit !found }' "$registry" \
        && ok "ME $me has at least one case" || bad "ME $me has no case in the registry"
done

echo "runScenarios: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
