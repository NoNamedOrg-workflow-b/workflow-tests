#!/usr/bin/env bash
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
failed=0

scripts=$(find "$root/.github/scripts" "$root/tools" "$root/tests" -name '*.sh' -type f 2> /dev/null | sort)

report() {
    failed=$((failed + 1))
    echo "FAIL T-NF4-a $1"
}

for file in $scripts; do
    name=${file#"$root"/}

    [ "$(head -n 1 "$file")" = "#!/usr/bin/env bash" ] || report "$name: shebang must be #!/usr/bin/env bash"
    "${BASH_BIN:-bash}" -n "$file" 2> /dev/null || report "$name: bash -n reports a syntax error"
    grep -q "$(printf '\t')" "$file" && report "$name: contains a tab"

    # else hides the early-return shape the codebase relies on.
    grep -v -E '^[[:space:]]*#' "$file" | grep -E '(^|[;&[:space:]])else([[:space:];]|$)' > /dev/null && report "$name: uses else"

    badIndent=$(awk '/^ +[^ #]/ { match($0, /^ */); if (RLENGTH % 4 != 0) print NR }' "$file" | head -n 3 | tr '\n' ' ')
    [ -z "$badIndent" ] || report "$name: indentation is not a multiple of 4 spaces (lines $badIndent)"
done

if [ "$failed" -ne 0 ]; then
    echo "style: $failed problem(s)"
    exit 1
fi
echo "PASS T-NF4-a scripts follow the style rules ($(echo "$scripts" | wc -l | tr -d ' ') files)"
echo "style: 0 problems"
