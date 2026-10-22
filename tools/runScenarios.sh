#!/usr/bin/env bash
# Gate G6: joins the case registry with what actually ran, so a case nobody executed cannot pass by being absent.
# Local (L) cases are read from the test suite output; E, M and D cases need a row with evidence in the results file.
# R cases are the plan's recorded residual risks: listed, but outside the totals and the exit code.
set -uo pipefail

usage() {
    echo "usage: runScenarios.sh [--cases FILE] [--results FILE] [--me N]" >&2
    exit 2
}

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
casesFile="$here/cases.tsv"
resultsFile=""
me=""

while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || usage
    case "$1" in
        --cases) casesFile=$2 ;;
        --results) resultsFile=$2 ;;
        --me) me=$2 ;;
        *) usage ;;
    esac
    shift 2
done

if ! [[ -z "$me" || $me =~ ^[0-9]+$ ]]; then
    usage
fi

if ! [ -f "$casesFile" ]; then
    echo "cases file not found: $casesFile" >&2
    exit 2
fi

if [ -n "$resultsFile" ] && ! [ -f "$resultsFile" ]; then
    echo "results file not found: $resultsFile" >&2
    exit 2
fi

# A registry or results file that is not what the gate expects must stop it before anything runs: a silently
# skipped row would read as a case that passed.
checked=$(CASES_FILE="$casesFile" RESULTS_FILE="$resultsFile" awk '
function fail(message) {
    print message > "/dev/stderr"
    exit 2
}

BEGIN {
    FS = "\t"
    casesFile = ENVIRON["CASES_FILE"]
    resultsFile = ENVIRON["RESULTS_FILE"]
    first = 1
    while ((getline line < casesFile) > 0) {
        sub(/\r$/, "", line)
        if (first && line != "caso\trisco\ttipo\tme\tgatilho") fail("invalid cases file: bad header in " casesFile)
        if (first) { first = 0; continue }
        if (line == "") continue
        if (split(line, fields, "\t") != 5) fail("invalid cases file: a row without exactly 5 fields: " line)
        if (fields[3] !~ /^[LEMDR]$/) fail("invalid cases file: tipo must be L, E, M, D or R: " fields[1])
        if (fields[4] !~ /^[0-9]+(\/[0-9]+)*$/) fail("invalid cases file: bad me field: " fields[1])
        if (fields[1] in seen) fail("invalid cases file: duplicate id: " fields[1])
        seen[fields[1]] = 1
    }
    if (first) fail("invalid cases file: empty " casesFile)
    if (resultsFile == "") exit 0
    getline line < resultsFile
    sub(/\r$/, "", line)
    if (line != "caso\tresultado\tevidencia") fail("invalid results file: bad header in " resultsFile)
}' < /dev/null && echo checked) || exit 2
[ "$checked" = "checked" ] || exit 2

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
suiteOutput="$work/suite.out"
: > "$suiteOutput"

# The suites run once, and only when some selected case reads them.
needsSuites=$(awk -F'\t' -v me="$me" '
    NR > 1 && $3 == "L" {
        n = split($4, parts, "/")
        for (i = 1; i <= n; i++) if (me == "" || parts[i] == me) { print "yes"; exit }
    }' "$casesFile")

runSuites() {
    [ -n "${RUN_TESTS:-}" ] || { "$root/tests/runTests.sh" < /dev/null 2>&1; return; }
    sh -c "$RUN_TESTS" < /dev/null 2>&1
}

# BSD and GNU sed both take the literal ESC; the C locale keeps non-UTF-8 bytes from aborting sed. Leftover ESC
# bytes are dropped so a verdict can never hide behind a control sequence.
stripColours() {
    LC_ALL=C sed $'s/\033\\[[0-9;]*m//g' | tr -d '\033'
}

# The suite exit code is not the verdict: each case is judged by its own line.
[ -z "$needsSuites" ] || runSuites | stripColours > "$suiteOutput"

CASES_FILE="$casesFile" RESULTS_FILE="$resultsFile" SUITE_OUTPUT="$suiteOutput" awk -v me="$me" '
function selected(meField,    n, parts, i) {
    if (me == "") return 1
    n = split(meField, parts, "/")
    for (i = 1; i <= n; i++) if (parts[i] == me) return 1
    return 0
}

function blank(text) {
    return text ~ /^[ \t\r]*$/
}

function emit(status, id, type, note) {
    printf "%s\t%s\t%s\t%s\n", status, id, type, note
    count[status]++
}

function judgeLocal(id) {
    if (id in failedLines) return emit("FAIL", id, "L", "")
    if (id in passedLines) return emit("PASS", id, "L", "")
    emit("PENDING", id, "L", "no PASS line")
}

function judgeRecorded(id, type,    result) {
    if (!(id in resultOf)) return emit("PENDING", id, type, "no result")
    result = resultOf[id]
    if (result == "FAIL") return emit("FAIL", id, type, evidenceOf[id])
    if (result != "PASS" && result != "N/A") return emit("PENDING", id, type, "invalid result")
    if (blank(evidenceOf[id])) return emit("PENDING", id, type, "no evidence")
    emit(result == "PASS" ? "PASS" : "N-A", id, type, evidenceOf[id])
}

BEGIN {
    FS = "\t"
    casesFile = ENVIRON["CASES_FILE"]
    resultsFile = ENVIRON["RESULTS_FILE"]
    suiteOutput = ENVIRON["SUITE_OUTPUT"]
    selectedCount = 0
    first = 1
    while ((getline line < casesFile) > 0) {
        sub(/\r$/, "", line)
        if (first) { first = 0; continue }
        if (blank(line)) continue
        split(line, fields, "\t")
        known[fields[1]] = 1
        if (!selected(fields[4])) continue
        selectedCount++
        ids[selectedCount] = fields[1]
        types[selectedCount] = fields[3]
    }

    first = 1
    while (resultsFile != "" && (getline line < resultsFile) > 0) {
        sub(/\r$/, "", line)
        if (first) { first = 0; continue }
        if (blank(line)) continue
        split(line, fields, "\t")
        # The last row wins even when it is empty or invalid: a later row that retracts a PASS must hold the gate.
        resultOf[fields[1]] = fields[2]
        evidenceOf[fields[1]] = fields[3]
        if (fields[1] in known || fields[1] in warned) continue
        warned[fields[1]] = 1
        print "warning: result for a case that is not in the registry: " fields[1] > "/dev/stderr"
    }

    while ((getline line < suiteOutput) > 0) {
        split(line, words, " ")
        if (substr(line, 1, 5) == "PASS ") passedLines[words[2]] = 1
        if (substr(line, 1, 5) == "FAIL ") failedLines[words[2]] = 1
    }

    if (selectedCount == 0) {
        print "no case selected" > "/dev/stderr"
        exit 2
    }

    for (i = 1; i <= selectedCount; i++) {
        if (types[i] == "R") { printf "R\t%s\tR\t\n", ids[i]; rCount++; continue }
        if (types[i] == "L") { judgeLocal(ids[i]); continue }
        judgeRecorded(ids[i], types[i])
    }

    printf "summary: PASS %d, FAIL %d, N-A %d, PENDING %d, R %d, total %d\n", count["PASS"], count["FAIL"], count["N-A"], count["PENDING"], rCount, selectedCount - rCount
    exit (count["FAIL"] + count["PENDING"] > 0) ? 1 : 0
}'
