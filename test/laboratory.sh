#!/system/bin/sh
# shellcheck shell=ksh

# ============================================================================
# ART PACKAGE PIPELINE LABORATORY
# Purpose: Exercise maintenance.sh's real process_packages() pipeline using
#          controlled package/state inputs and mocked compilation where needed.
# ============================================================================

TEST_DIR="${0%/*}"
[ "$TEST_DIR" = "$0" ] && TEST_DIR="."

# maintenance.sh lives one directory above test/.
REPO_ROOT="${TEST_DIR}/.."

PACKAGE_FILE="${1-${TEST_DIR}/test_packages_list.txt}"
STATE_FILE="${2-${TEST_DIR}/test_last_optimized}"
EXPECTED_STATE_FILE="${3-${TEST_DIR}/test_expected_state.txt}"
EXPECTED_FAILURE_STATE_FILE="${4-${TEST_DIR}/test_expected_state_failed.txt}"

# Load maintenance.sh functions without executing normal maintenance.
MAINTENANCE_SOURCE_ONLY=1
# shellcheck source=../maintenance.sh
. "${REPO_ROOT}/maintenance.sh"

# ============================================================================
# ASSERTION HELPERS
# ============================================================================

assert_eq() {
    typeset actual="$1"
    typeset expected="$2"
    typeset label="$3"

    if [ "$actual" -ne "$expected" ]; then
        print -r -- "[!] TEST ASSERTION FAILED: $label: expected $expected, got $actual" >&2
        return 1
    fi

    print -r -- "[+] Assertion passed: $label = $actual"
    return 0
}

assert_empty() {
    typeset actual="$1"
    typeset label="$2"

    if [ -n "$actual" ]; then
        print -r -- "[!] TEST ASSERTION FAILED: $label: expected empty, got '$actual'" >&2
        return 1
    fi

    print -r -- "[+] Assertion passed: $label is empty"
    return 0
}

assert_nonempty_file() {
    typeset file="$1"
    typeset label="$2"

    if [ -z "$file" ] || [ ! -s "$file" ]; then
        print -r -- "[!] TEST ASSERTION FAILED: $label: expected non-empty file" >&2
        return 1
    fi

    print -r -- "[+] Assertion passed: $label exists and is non-empty"
    return 0
}

assert_file_eq() {
    typeset actual_file="$1"
    typeset expected_file="$2"
    typeset label="$3"

    if [ -z "$actual_file" ] || [ ! -f "$actual_file" ]; then
        print -r -- "[!] TEST ASSERTION FAILED: $label: actual file is missing" >&2
        return 1
    fi

    if ! cmp -s "$actual_file" "$expected_file"; then
        print -r -- "[!] TEST ASSERTION FAILED: $label: files differ" >&2
        print -r -- '    --- expected ---' >&2
        cat "$expected_file" >&2
        print -r -- '    --- actual ---' >&2
        cat "$actual_file" >&2
        return 1
    fi

    print -r -- "[+] Assertion passed: $label"
    return 0
}

assert_file_lines() {
    typeset file="$1"
    typeset expected="$2"
    typeset label="$3"
    typeset actual

    actual=$(wc -l <"$file")
    assert_eq "$actual" "$expected" "$label"
}

assert_file_contains_line() {
    typeset file="$1"
    typeset expected_line="$2"
    typeset label="$3"

    if ! grep -Fxq "$expected_line" "$file"; then
        print -r -- "[!] TEST ASSERTION FAILED: $label" >&2
        print -r -- "    Missing line: $expected_line" >&2
        return 1
    fi

    print -r -- "[+] Assertion passed: $label"
    return 0
}

assert_file_not_contains() {
    typeset file="$1"
    typeset pattern="$2"
    typeset label="$3"

    if grep -Fq "$pattern" "$file"; then
        print -r -- "[!] TEST ASSERTION FAILED: $label" >&2
        print -r -- "    Unexpected text: $pattern" >&2
        return 1
    fi

    print -r -- "[+] Assertion passed: $label"
    return 0
}

assert_text_contains() {
    typeset text="$1"
    typeset expected="$2"
    typeset label="$3"

    case "$text" in
    *"$expected"*)
        print -r -- "[+] Assertion passed: $label"
        return 0
        ;;
    *)
        print -r -- "[!] TEST ASSERTION FAILED: $label" >&2
        print -r -- "    Missing text: $expected" >&2
        return 1
        ;;
    esac
}

# ============================================================================
# TEST-CASE RUNTIME HELPERS
# ============================================================================

case_cleanup() {
    exec 3>&- 2>/dev/null || true

    for tmpfile in \
        "${CURRENT_RUN_STATE:-}" \
        "${STAGE_PATHS:-}" \
        "${STAGE_STATS:-}" \
        "${STAGE_MERGED:-}" \
        "${ERROR_TMPFILE:-}" \
        "${RUN_ERROR_TMPFILE:-}" \
        "${MOCK_CMD_LOG:-}"; do

        if [ -n "$tmpfile" ] && [ -e "$tmpfile" ]; then
            rm -f "$tmpfile" 2>/dev/null || true
        fi
    done
}

setup_case() {
    DRY_RUN="$1"
    DEBUG=1
    NO_USER=0

    trap 'case_cleanup' EXIT
    runtime_setup
}

load_previous_state() {
    PREV_STATE="
$(<"$STATE_FILE")
"
}

prepare_pipeline() {
    if ! package_pipeline_setup; then
        print -r -- '[!] TEST ERROR: package_pipeline_setup failed.' >&2
        return 1
    fi

    load_previous_state
    return 0
}

# Mock Android's cmd package compile for real-run laboratory cases. The mock is
# intentionally a shell function so process_packages() exercises its normal
# command path without invoking Android package-manager services.
cmd() {
    typeset mock_pkg=""

    print -r -- "$*" >>"$MOCK_CMD_LOG"

    while [ "$#" -gt 0 ]; do
        case "$1" in
        -f)
            if [ "$#" -ge 2 ]; then
                mock_pkg="$2"
                shift 2
                continue
            fi
            ;;
        esac

        shift
    done

    if [ -n "${MOCK_FAIL_PACKAGE:-}" ] && [ "$mock_pkg" = "$MOCK_FAIL_PACKAGE" ]; then
        print -r -- "mock compile failure for $mock_pkg" >&2
        return 1
    fi

    return 0
}

# ============================================================================
# TEST CASES
# ============================================================================

test_dry_run_speed_profile() {
    typeset package_list failures=0

    setup_case 1
    prepare_pipeline || return 1

    package_list=$(<"$PACKAGE_FILE")

    if ! process_packages "$package_list" "speed-profile"; then
        print -r -- '[!] TEST ERROR: speed-profile dry-run pipeline failed.' >&2
        return 1
    fi

    assert_eq "$SYSTEM_PKGS_COUNT" 0 "Dry-run parsed system packages" || failures=1
    assert_eq "$USER_PKGS_COUNT" 8 "Dry-run parsed user packages" || failures=1
    assert_eq "$TOTAL_COMPILED" 0 "Dry-run compiled packages" || failures=1
    assert_eq "$TOTAL_SKIPPED" 4 "Dry-run skipped unchanged" || failures=1
    assert_eq "$TOTAL_WOULD_COMPILE" 3 "Dry-run would compile" || failures=1
    assert_eq "$TOTAL_FAILED" 0 "Dry-run compilation failures" || failures=1
    assert_eq "$TOTAL_INVALID" 1 "Dry-run invalid records" || failures=1

    assert_empty "$CURRENT_RUN_STATE" "Dry-run current-run state path" || failures=1
    assert_empty "$ERROR_TMPFILE" "Dry-run compile-error tempfile path" || failures=1
    assert_empty "$RUN_ERROR_TMPFILE" "Dry-run maintenance-error tempfile path" || failures=1

    assert_file_not_contains "$STAGE_MERGED" "com.test.relative" \
        "Relative package path rejected during normalization" || failures=1
    assert_file_not_contains "$STAGE_MERGED" "com.test.pipepath" \
        "Pipe-containing package path rejected during normalization" || failures=1
    assert_file_not_contains "$STAGE_MERGED" "pipepkg" \
        "Pipe-containing package name rejected during normalization" || failures=1

    return "$failures"
}

test_dry_run_system() {
    typeset package_list failures=0

    setup_case 1
    prepare_pipeline || return 1

    package_list=$(<"$PACKAGE_FILE")

    if ! process_packages "$package_list" "system"; then
        print -r -- '[!] TEST ERROR: system dry-run pipeline failed.' >&2
        return 1
    fi

    assert_eq "$SYSTEM_PKGS_COUNT" 8 "System-mode parsed system packages" || failures=1
    assert_eq "$USER_PKGS_COUNT" 0 "System-mode parsed user packages" || failures=1
    assert_eq "$TOTAL_SKIPPED" 4 "System-mode skipped unchanged" || failures=1
    assert_eq "$TOTAL_WOULD_COMPILE" 3 "System-mode would compile" || failures=1
    assert_eq "$TOTAL_FAILED" 0 "System-mode compilation failures" || failures=1
    assert_eq "$TOTAL_INVALID" 1 "System-mode invalid records" || failures=1
    assert_empty "$CURRENT_RUN_STATE" "System dry-run current-run state path" || failures=1

    return "$failures"
}

test_empty_user_list() {
    typeset failures=0

    setup_case 1

    if ! process_packages "" "speed-profile"; then
        print -r -- '[!] TEST ASSERTION FAILED: empty user package list should succeed.' >&2
        return 1
    fi

    assert_eq "$USER_PKGS_COUNT" 0 "Empty user-list package count" || failures=1
    assert_eq "$TOTAL_SKIPPED" 0 "Empty user-list skipped count" || failures=1
    assert_eq "$TOTAL_WOULD_COMPILE" 0 "Empty user-list would-compile count" || failures=1
    assert_empty "$CURRENT_RUN_STATE" "Empty user-list state path" || failures=1
    assert_empty "$RUN_ERROR_TMPFILE" "Empty user-list maintenance-error tempfile" || failures=1

    return "$failures"
}

test_empty_system_list() {
    typeset empty_output empty_rc failures=0

    setup_case 1

    empty_output=$(process_packages "" "system" 2>&1)
    empty_rc=$?

    assert_eq "$empty_rc" 1 "Empty system-list return code" || failures=1
    assert_eq "$SYSTEM_PKGS_COUNT" 0 "Empty system-list package count" || failures=1
    assert_text_contains "$empty_output" "unexpectedly empty" \
        "Empty system-list emits fail-closed error" || failures=1
    assert_empty "$RUN_ERROR_TMPFILE" \
        "Dry-run empty-system maintenance-error tempfile" || failures=1

    return "$failures"
}

test_real_run_success() {
    typeset package_list failures=0

    setup_case 0
    prepare_pipeline || return 1

    MOCK_CMD_LOG=$(mktemp "${TMPDIR}/mock_cmd.$$.XXXXXX") || return 1
    MOCK_FAIL_PACKAGE=""
    package_list=$(<"$PACKAGE_FILE")

    if ! process_packages "$package_list" "speed-profile"; then
        print -r -- '[!] TEST ERROR: mocked real-run pipeline failed.' >&2
        return 1
    fi

    assert_eq "$USER_PKGS_COUNT" 8 "Real-run parsed user packages" || failures=1
    assert_eq "$TOTAL_COMPILED" 3 "Real-run compiled successfully" || failures=1
    assert_eq "$TOTAL_SKIPPED" 4 "Real-run skipped unchanged" || failures=1
    assert_eq "$TOTAL_FAILED" 0 "Real-run compilation failures" || failures=1
    assert_eq "$TOTAL_INVALID" 1 "Real-run invalid records" || failures=1
    assert_eq "$TOTAL_WOULD_COMPILE" 0 "Real-run would-compile count" || failures=1

    assert_file_lines "$CURRENT_RUN_STATE" 7 "Real-run state fingerprint count" || failures=1
    assert_file_eq "$CURRENT_RUN_STATE" "$EXPECTED_STATE_FILE" \
        "Real-run state exactly matches expected fingerprints" || failures=1

    assert_file_lines "$MOCK_CMD_LOG" 3 "Real-run mocked compile command count" || failures=1
    assert_file_contains_line "$MOCK_CMD_LOG" \
        "package compile -m speed-profile -f com.test.changed" \
        "Changed package compiled with speed-profile" || failures=1
    assert_file_contains_line "$MOCK_CMD_LOG" \
        "package compile -m speed-profile -f com.test.parentfallback" \
        "Parent-fallback package compiled with speed-profile" || failures=1
    assert_file_contains_line "$MOCK_CMD_LOG" \
        "package compile -m speed-profile -f com.test.unavailable" \
        "Unavailable-metadata package compiled with speed-profile" || failures=1

    assert_empty "$ERROR_TMPFILE" "Successful real-run compile-error tempfile path" || failures=1
    assert_empty "$RUN_ERROR_TMPFILE" "Successful real-run maintenance-error tempfile path" || failures=1

    return "$failures"
}

test_real_run_compile_failure() {
    typeset package_list failures=0

    setup_case 0
    prepare_pipeline || return 1

    MOCK_CMD_LOG=$(mktemp "${TMPDIR}/mock_cmd.$$.XXXXXX") || return 1
    MOCK_FAIL_PACKAGE="com.test.changed"
    package_list=$(<"$PACKAGE_FILE")

    if ! process_packages "$package_list" "speed-profile"; then
        print -r -- '[!] TEST ERROR: compile-failure laboratory pipeline returned fatal failure.' >&2
        return 1
    fi

    assert_eq "$USER_PKGS_COUNT" 8 "Failure-run parsed user packages" || failures=1
    assert_eq "$TOTAL_COMPILED" 2 "Failure-run successful compilations" || failures=1
    assert_eq "$TOTAL_SKIPPED" 4 "Failure-run skipped unchanged" || failures=1
    assert_eq "$TOTAL_FAILED" 1 "Failure-run compilation failures" || failures=1
    assert_eq "$TOTAL_INVALID" 1 "Failure-run invalid records" || failures=1

    assert_file_lines "$CURRENT_RUN_STATE" 6 "Failure-run state fingerprint count" || failures=1
    assert_file_eq "$CURRENT_RUN_STATE" "$EXPECTED_FAILURE_STATE_FILE" \
        "Failed package omitted from current-run state" || failures=1

    assert_nonempty_file "$ERROR_TMPFILE" \
        "Compile-error tempfile created lazily after failure" || failures=1
    assert_file_contains_line "$MOCK_CMD_LOG" \
        "package compile -m speed-profile -f com.test.changed" \
        "Failed package reached mocked compiler" || failures=1

    if [ -n "$ERROR_TMPFILE" ] && [ -f "$ERROR_TMPFILE" ]; then
        if ! grep -Fq "FAIL (1): com.test.changed" "$ERROR_TMPFILE"; then
            print -r -- '[!] TEST ASSERTION FAILED: compile-error tempfile missing failure record' >&2
            failures=1
        else
            print -r -- '[+] Assertion passed: compile-error tempfile contains failure record'
        fi
    fi

    assert_empty "$RUN_ERROR_TMPFILE" "Failure-run maintenance-error tempfile path" || failures=1

    return "$failures"
}

# ============================================================================
# INPUT VALIDATION
# ============================================================================

for required_file in \
    "$PACKAGE_FILE" \
    "$STATE_FILE" \
    "$EXPECTED_STATE_FILE" \
    "$EXPECTED_FAILURE_STATE_FILE"; do

    if [ ! -r "$required_file" ]; then
        print -r -- "[!] TEST ERROR: Cannot read required fixture: $required_file" >&2
        exit 1
    fi
done

# ============================================================================
# RUN TEST MATRIX
# ============================================================================

print -r -- ''
print -r -- '============================================================'
print -r -- ' ART PACKAGE PIPELINE LABORATORY'
print -r -- '============================================================'
print -r -- " Package input:          $PACKAGE_FILE"
print -r -- " State baseline:         $STATE_FILE"
print -r -- " Expected success state: $EXPECTED_STATE_FILE"
print -r -- " Expected failure state: $EXPECTED_FAILURE_STATE_FILE"
print -r -- '============================================================'

TEST_FAILURES=0
TEST_CASES=0

run_case() {
    typeset case_label="$1"
    typeset case_function="$2"

    TEST_CASES=$((TEST_CASES + 1))

    print -r -- ''
    print -r -- '------------------------------------------------------------'
    print -r -- " TEST $TEST_CASES: $case_label"
    print -r -- '------------------------------------------------------------'

    if (
        "$case_function"
    ); then
        print -r -- "[+] TEST PASSED: $case_label"
    else
        print -r -- "[!] TEST FAILED: $case_label" >&2
        TEST_FAILURES=$((TEST_FAILURES + 1))
    fi
}

run_case 'Dry-run speed-profile pipeline' test_dry_run_speed_profile
run_case 'Dry-run system pipeline' test_dry_run_system
run_case 'Empty user package list succeeds' test_empty_user_list
run_case 'Empty system package list fails closed' test_empty_system_list
run_case 'Mocked real-run state generation' test_real_run_success
run_case 'Mocked real-run compilation failure' test_real_run_compile_failure

print -r -- ''
print -r -- '============================================================'
print -r -- ' PACKAGE PIPELINE LABORATORY SUMMARY'
print -r -- '============================================================'
print -r -- " Test cases: $TEST_CASES"
print -r -- " Passed:     $((TEST_CASES - TEST_FAILURES))"
print -r -- " Failed:     $TEST_FAILURES"
print -r -- '============================================================'

if [ "$TEST_FAILURES" -ne 0 ]; then
    print -r -- '[!] PACKAGE PIPELINE LABORATORY FAILED' >&2
    exit 1
fi

print -r -- '[+] All package-pipeline laboratory tests passed.'
exit 0
