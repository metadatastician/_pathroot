#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workflow="$repo_dir/.github/workflows/dogfood-gate.yml"
lock="$repo_dir/.github/workflows/actions.lock"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    grep -Fq -- "$2" "$1" || fail "Expected '$2' in $1"
}

assert_absent() {
    if grep -Fiq -- "$2" "$1"; then
        fail "Unexpected '$2' in $1"
    fi
}

assert_absent "$workflow" 'a2ml'
assert_absent "$lock" 'hyperpolymath/a2ml-ecosystem'

for job in k9-validate empty-lint groove-check eclexiaiser-validate; do
    grep -Fqx "  $job:" "$workflow" || fail "Missing required job: $job"
done

needs="$(awk '/^  dogfood-summary:$/ { summary=1; next }
    summary && /^  [^ #]/ { exit }
    summary && /^    needs: / { print; exit }' "$workflow")"
[[ "$needs" == '    needs: [k9-validate, empty-lint, groove-check, eclexiaiser-validate]' ]] ||
    fail "Unexpected dogfood-summary dependencies: $needs"

workflow_actions="$(sed -nE 's/^[[:space:]]+uses:[[:space:]]+([^[:space:]#]+).*$/\1/p' "$workflow" |
    sed -E 's#^([^/]+/[^/]+)(/[^@]+)(@[^[:space:]]+)$#\1\3#' | sort -u)"
locked_actions="$(awk -v key="    '.github/workflows/dogfood-gate.yml':" '
    $0 == key { found=1; next }
    found && /^        - / { sub(/^[[:space:]]*-[[:space:]]*/, ""); gsub(/\047/, ""); print; next }
    found { exit }
' "$lock" | sort -u)"
[[ -n "$workflow_actions" && "$workflow_actions" == "$locked_actions" ]] ||
    fail "Workflow actions do not match the lock entry: workflow=[$workflow_actions], lock=[$locked_actions]"
while IFS= read -r action; do
    grep -Fqx "    '$action':" "$lock" || fail "Missing dependency lock record: $action"
done <<< "$locked_actions"

scorecard="$(awk '
    /^      - name: Generate dogfooding scorecard$/ { step=1; next }
    step && /^        run: \|$/ { script=1; next }
    script && /^          / { sub(/^          /, ""); print; next }
    script && /^$/ { print; next }
    script { exit }
' "$workflow")"
[[ -n "$scorecard" ]] || fail 'Missing scorecard script'

fixtures="$(mktemp -d)"
trap 'rm -rf "$fixtures"' EXIT

check_scorecard() {
    local scenario="$1" expected="$2" k9="$3" editorconfig="$4" groove="$5" verisimdb="$6" eclexiaiser="$7"
    local fixture="$fixtures/$scenario" summary="$fixtures/$scenario/summary"
    mkdir -p "$fixture"
    (cd "$fixture" && GITHUB_STEP_SUMMARY="$summary" bash -e -c "$scorecard")
    assert_contains "$summary" "**Score: $expected/5**"
    [[ "$(grep -cE '^\| (K9 contracts|\.editorconfig|Groove endpoint|VeriSimDB integration|eclexiaiser) \|' "$summary")" -eq 5 ]] ||
        fail "$scenario: expected exactly five scorecard rows"
    assert_absent "$summary" 'a2ml'
    assert_contains "$summary" "| K9 contracts | $k9 |"
    assert_contains "$summary" "| .editorconfig | $editorconfig |"
    assert_contains "$summary" "| Groove endpoint | $groove |"
    assert_contains "$summary" "| VeriSimDB integration | $verisimdb |"
    assert_contains "$summary" "| eclexiaiser | $eclexiaiser |"
}

check_scorecard empty 0 ':x:' ':x:' ':ballot_box_with_check:' ':ballot_box_with_check:' ':ballot_box_with_check:'

mkdir -p "$fixtures/retired/.git"
touch "$fixtures/retired/0-AI-MANIFEST.a2ml" "$fixtures/retired/.git/old.a2ml"
printf 'groove and verisimdb mentioned in documentation only\n' > "$fixtures/retired/notes.md"
check_scorecard retired 0 ':x:' ':x:' ':ballot_box_with_check:' ':ballot_box_with_check:' ':ballot_box_with_check:'

mkdir -p "$fixtures/partial"
touch "$fixtures/partial/example.k9" "$fixtures/partial/.editorconfig"
check_scorecard partial 2 ':white_check_mark:' ':white_check_mark:' ':ballot_box_with_check:' ':ballot_box_with_check:' ':ballot_box_with_check:'

mkdir -p "$fixtures/full/.well-known/groove"
touch "$fixtures/full/example.k9.ncl" "$fixtures/full/.editorconfig" "$fixtures/full/eclexiaiser.toml"
printf '{}\n' > "$fixtures/full/.well-known/groove/manifest.json"
printf 'database: verisimdb\n' > "$fixtures/full/config.yml"
check_scorecard full 5 ':white_check_mark:' ':white_check_mark:' ':white_check_mark:' ':white_check_mark:' ':white_check_mark:'

printf 'PASS: dogfood gate retirement, lock alignment, and scorecard fixtures\n'
