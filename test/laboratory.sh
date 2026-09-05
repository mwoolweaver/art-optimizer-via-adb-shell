#!/system/bin/sh
# shellcheck shell=ksh

# ============================================================================
# ART MAINTENANCE LABORATORY
# Purpose: Exercise maintenance.sh's package pipeline, ART Final Status parsing,
#          lazy ART capability discovery, dry-run probing, JSON output, policy gates,
#          legacy fallback, and scope-specific state using deterministic mocks.
# ============================================================================

TEST_DIR="${0%/*}"
[ "$TEST_DIR" = "$0" ] && TEST_DIR="."

# maintenance.sh lives one directory above test/.
REPO_ROOT="${TEST_DIR}/.."

PACKAGE_FILE="${1-${TEST_DIR}/test_packages_list.txt}"
STATE_FILE="${2-${TEST_DIR}/test_last_optimized}"
EXPECTED_STATE_FILE="${3-${TEST_DIR}/test_expected_state.txt}"
EXPECTED_FAILURE_STATE_FILE="${4-${TEST_DIR}/test_expected_state_failed.txt}"
MALFORMED_PACKAGE_FILE="${TEST_DIR}/test_packages_malformed.txt"
CLI_SYSTEM_PACKAGE_FILE="${TEST_DIR}/test_cli_system_packages.txt"
CLI_USER_PACKAGE_FILE="${TEST_DIR}/test_cli_user_packages.txt"
CLI_FULL_STATE_FILE="${TEST_DIR}/test_cli_full_state.txt"
CLI_USER_STATE_FILE="${TEST_DIR}/test_cli_user_state.txt"

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

assert_str_eq() {
    typeset actual="$1"
    typeset expected="$2"
    typeset label="$3"

    if [ "$actual" != "$expected" ]; then
        print -r -- "[!] TEST ASSERTION FAILED: $label: expected '$expected', got '$actual'" >&2
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

assert_text_not_contains() {
    typeset text="$1"
    typeset unexpected="$2"
    typeset label="$3"

    case "$text" in
    *"$unexpected"*)
        print -r -- "[!] TEST ASSERTION FAILED: $label" >&2
        print -r -- "    Unexpected text: $unexpected" >&2
        return 1
        ;;
    *)
        print -r -- "[+] Assertion passed: $label"
        return 0
        ;;
    esac
}

assert_file_exists() {
    typeset file="$1"
    typeset label="$2"

    if [ ! -f "$file" ]; then
        print -r -- "[!] TEST ASSERTION FAILED: $label: file is missing" >&2
        return 1
    fi

    print -r -- "[+] Assertion passed: $label"
    return 0
}

assert_file_missing() {
    typeset file="$1"
    typeset label="$2"

    if [ -e "$file" ]; then
        print -r -- "[!] TEST ASSERTION FAILED: $label: unexpected path exists: $file" >&2
        return 1
    fi

    print -r -- "[+] Assertion passed: $label"
    return 0
}

assert_file_empty() {
    typeset file="$1"
    typeset label="$2"

    if [ -s "$file" ]; then
        print -r -- "[!] TEST ASSERTION FAILED: $label: expected empty file" >&2
        cat "$file" >&2
        return 1
    fi

    print -r -- "[+] Assertion passed: $label"
    return 0
}

# ============================================================================
# TEST-CASE RUNTIME HELPERS
# ============================================================================

case_cleanup() {
    exec 3>&- 2>/dev/null || true
    exec 4>&- 2>/dev/null || true

    for tmpfile in \
        "${CURRENT_RUN_STATE:-}" \
        "${STAGE_PATHS:-}" \
        "${STAGE_STATS:-}" \
        "${STAGE_MERGED:-}" \
        "${ERROR_TMPFILE:-}" \
        "${RUN_ERROR_TMPFILE:-}" \
        "${MOCK_CMD_LOG:-}" \
        "${QUIET_STDOUT:-}" \
        "${QUIET_STDERR:-}"; do

        if [ -n "$tmpfile" ] && [ -e "$tmpfile" ]; then
            rm -f "$tmpfile" 2>/dev/null || true
        fi
    done

    if [ -n "${CLI_CASE_ROOT:-}" ] && [ -d "$CLI_CASE_ROOT" ]; then
        rm -rf "$CLI_CASE_ROOT" 2>/dev/null || true
    fi
}

setup_case() {
    DRY_RUN="$1"
    DEBUG=1
    NO_USER=0

    trap 'case_cleanup' EXIT
    runtime_setup

    # Direct pipeline tests default to the modern ART Service contract. Individual
    # legacy tests deliberately turn this off after setup.
    ART_VERBOSE_RESULTS=1
    ART_RESULT_MODE="final-status"

    MOCK_ART_DEFAULT_STATUS="PERFORMED"
    MOCK_ART_SPECIAL_PACKAGE=""
    MOCK_ART_SPECIAL_STATUS=""
    MOCK_ART_SPECIAL_EXTRA=""
    MOCK_ART_SPECIAL_EXIT=0
    MOCK_ART_SPECIAL_OMIT_STATUS=0
    MOCK_ART_SPECIAL_DUPLICATE_STATUS=0
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

prepare_cli_case() {
    typeset print_shim

    trap 'case_cleanup' EXIT

    CLI_CASE_ROOT=$(mktemp -d "${TMPDIR}/art_cli_case.$$.XXXXXX") || return 1
    CLI_RUN_DIR="${CLI_CASE_ROOT}/run"
    CLI_TMP_DIR="${CLI_CASE_ROOT}/tmp"
    CLI_MOCK_BIN="${CLI_CASE_ROOT}/mock-bin"
    CLI_PM_LOG="${CLI_CASE_ROOT}/pm.log"
    CLI_CMD_LOG="${CLI_CASE_ROOT}/cmd.log"
    CLI_STDOUT="${CLI_CASE_ROOT}/stdout.log"
    CLI_STDERR="${CLI_CASE_ROOT}/stderr.log"

    mkdir -p "$CLI_RUN_DIR" "$CLI_TMP_DIR" "$CLI_MOCK_BIN" || return 1
    cp "${REPO_ROOT}/maintenance.sh" "${CLI_RUN_DIR}/maintenance.sh" || return 1

    : >"$CLI_PM_LOG"
    : >"$CLI_CMD_LOG"
    : >"$CLI_STDOUT"
    : >"$CLI_STDERR"

    # Bash is available on GitHub's Ubuntu runner and accepts the script's ksh
    # syntax. Android device runs prefer the actual /system/bin/sh when present.
    if [ -x /system/bin/sh ]; then
        CLI_SHELL=/system/bin/sh
    elif command -v bash >/dev/null 2>&1; then
        CLI_SHELL=$(command -v bash)
    else
        print -r -- '[!] TEST ERROR: No suitable shell found for mocked CLI integration tests.' >&2
        return 1
    fi

    # Bash lacks ksh's print builtin, so provide a tiny compatible external shim.
    print_shim="${CLI_MOCK_BIN}/print"
    cat >"$print_shim" <<'EOF_PRINT'
#!/bin/sh
[ "${1-}" = "-r" ] && shift
[ "${1-}" = "--" ] && shift
if [ "$#" -eq 0 ]; then
    printf '\n'
else
    printf '%s' "$1"
    shift
    for arg in "$@"; do
        printf ' %s' "$arg"
    done
    printf '\n'
fi
EOF_PRINT

    cat >"${CLI_MOCK_BIN}/getprop" <<'EOF_GETPROP'
#!/bin/sh
case "${1-}" in
sys.boot_completed) printf '1\n' ;;
ro.build.version.release) printf '17\n' ;;
ro.build.version.sdk) printf '37\n' ;;
*) printf '\n' ;;
esac
EOF_GETPROP

    cat >"${CLI_MOCK_BIN}/service" <<'EOF_SERVICE'
#!/bin/sh
if [ "${1-}" = "check" ] && [ "${2-}" = "package" ]; then
    printf 'Service package: found\n'
    exit 0
fi
exit 1
EOF_SERVICE

    cat >"${CLI_MOCK_BIN}/dumpsys" <<'EOF_DUMPSYS'
#!/bin/sh
case "${1-}" in
thermalservice)
    printf 'Thermal Status: 0\n'
    ;;
battery)
    if [ "${MOCK_CHARGING:-1}" -eq 1 ]; then
        ac=true
    else
        ac=false
    fi
    printf 'AC powered: %s\n' "$ac"
    printf 'USB powered: false\n'
    printf 'Wireless powered: false\n'
    printf 'Dock powered: false\n'
    printf 'level: %s\n' "${MOCK_BATTERY_LEVEL:-80}"
    printf 'temperature: 300\n'
    ;;
hardware_properties)
    ;;
esac
EOF_DUMPSYS

    cat >"${CLI_MOCK_BIN}/df" <<'EOF_DF'
#!/bin/sh
free_kb="${MOCK_FREE_KB:-5000000}"
printf 'Filesystem 1K-blocks Used Available Use%% Mounted on\n'
printf '/dev/mock 6000000 1000000 %s 17%% /data\n' "$free_kb"
EOF_DF

    cat >"${CLI_MOCK_BIN}/pm" <<'EOF_PM'
#!/bin/sh
printf '%s\n' "$*" >>"$MOCK_PM_LOG"
case "$*" in
'trim-caches 99999999999')
    exit 0
    ;;
'list packages -f -s --show-versioncode')
    cat "$MOCK_SYSTEM_PACKAGE_FILE"
    ;;
'list packages -f -3 --show-versioncode')
    cat "$MOCK_USER_PACKAGE_FILE"
    ;;
*)
    printf 'unexpected mocked pm invocation: %s\n' "$*" >&2
    exit 1
    ;;
esac
EOF_PM

    cat >"${CLI_MOCK_BIN}/cmd" <<'EOF_CMD'
#!/bin/sh
printf '%s\n' "$*" >>"$MOCK_CMD_LOG"

case "$*" in
'package help')
    if [ "${MOCK_ART_HELP_VERBOSE:-1}" -eq 1 ]; then
        printf '%s\n' '-v Verbose mode. This mode prints detailed results.'
    else
        printf '%s\n' 'Package compile help (legacy mock; no verbose result mode).'
    fi
    exit 0
    ;;
package\ compile\ *)
    mock_pkg=""
    mock_verbose=0

    while [ "$#" -gt 0 ]; do
        case "$1" in
        -v)
            mock_verbose=1
            ;;
        -f)
            if [ "$#" -ge 2 ]; then
                mock_pkg="$2"
                shift
            fi
            ;;
        esac
        shift
    done

    mock_status="${MOCK_ART_DEFAULT_STATUS:-PERFORMED}"
    mock_extra=""
    mock_exit=0
    mock_omit=0
    mock_duplicate=0

    if [ -n "${MOCK_ART_SPECIAL_PACKAGE:-}" ] &&
        [ "$mock_pkg" = "$MOCK_ART_SPECIAL_PACKAGE" ]; then

        [ -n "${MOCK_ART_SPECIAL_STATUS:-}" ] &&
            mock_status="$MOCK_ART_SPECIAL_STATUS"
        mock_extra="${MOCK_ART_SPECIAL_EXTRA:-}"
        mock_exit="${MOCK_ART_SPECIAL_EXIT:-0}"
        mock_omit="${MOCK_ART_SPECIAL_OMIT_STATUS:-0}"
        mock_duplicate="${MOCK_ART_SPECIAL_DUPLICATE_STATUS:-0}"
    fi

    if [ "$mock_verbose" -eq 1 ]; then
        if [ "$mock_omit" -eq 0 ]; then
            printf 'Final Status: %s\n' "$mock_status"
            if [ "$mock_duplicate" -eq 1 ]; then
                printf 'Final Status: %s\n' "$mock_status"
            fi
        fi

        if [ -n "$mock_extra" ]; then
            printf 'Extended Status: [%s]\n' "$mock_extra"
        fi
    fi

    exit "$mock_exit"
    ;;
*)
    printf 'unexpected mocked cmd invocation: %s\n' "$*" >&2
    exit 1
    ;;
esac
EOF_CMD

    chmod +x "${CLI_MOCK_BIN}"/* || return 1

    CLI_MOCK_BATTERY_LEVEL=80
    CLI_MOCK_CHARGING=1
    CLI_MOCK_FREE_KB=5000000
    CLI_MOCK_ART_HELP_VERBOSE=1
    CLI_MOCK_ART_DEFAULT_STATUS="PERFORMED"
    CLI_MOCK_ART_SPECIAL_PACKAGE=""
    CLI_MOCK_ART_SPECIAL_STATUS=""
    CLI_MOCK_ART_SPECIAL_EXTRA=""
    CLI_MOCK_ART_SPECIAL_EXIT=0
    CLI_MOCK_ART_SPECIAL_OMIT_STATUS=0
    CLI_MOCK_ART_SPECIAL_DUPLICATE_STATUS=0
    CLI_RC=0
    return 0
}

run_cli() {
    : >"$CLI_PM_LOG"
    : >"$CLI_CMD_LOG"
    : >"$CLI_STDOUT"
    : >"$CLI_STDERR"

    env \
        USER_ID=2000 \
        TMPDIR="$CLI_TMP_DIR" \
        PATH="${CLI_MOCK_BIN}:$PATH" \
        MOCK_PM_LOG="$CLI_PM_LOG" \
        MOCK_CMD_LOG="$CLI_CMD_LOG" \
        MOCK_SYSTEM_PACKAGE_FILE="$CLI_SYSTEM_PACKAGE_FILE" \
        MOCK_USER_PACKAGE_FILE="$CLI_USER_PACKAGE_FILE" \
        MOCK_BATTERY_LEVEL="$CLI_MOCK_BATTERY_LEVEL" \
        MOCK_CHARGING="$CLI_MOCK_CHARGING" \
        MOCK_FREE_KB="$CLI_MOCK_FREE_KB" \
        MOCK_ART_HELP_VERBOSE="$CLI_MOCK_ART_HELP_VERBOSE" \
        MOCK_ART_DEFAULT_STATUS="$CLI_MOCK_ART_DEFAULT_STATUS" \
        MOCK_ART_SPECIAL_PACKAGE="$CLI_MOCK_ART_SPECIAL_PACKAGE" \
        MOCK_ART_SPECIAL_STATUS="$CLI_MOCK_ART_SPECIAL_STATUS" \
        MOCK_ART_SPECIAL_EXTRA="$CLI_MOCK_ART_SPECIAL_EXTRA" \
        MOCK_ART_SPECIAL_EXIT="$CLI_MOCK_ART_SPECIAL_EXIT" \
        MOCK_ART_SPECIAL_OMIT_STATUS="$CLI_MOCK_ART_SPECIAL_OMIT_STATUS" \
        MOCK_ART_SPECIAL_DUPLICATE_STATUS="$CLI_MOCK_ART_SPECIAL_DUPLICATE_STATUS" \
        "$CLI_SHELL" "${CLI_RUN_DIR}/maintenance.sh" "$@" \
        >"$CLI_STDOUT" 2>"$CLI_STDERR"
    CLI_RC=$?

    return 0
}

# Mock Android's cmd package compile for direct pipeline laboratory cases.
# Modern tests emit an ART Final Status transcript; legacy tests deliberately
# disable ART_VERBOSE_RESULTS and exercise exit-code compatibility.
cmd() {
    typeset mock_pkg="" mock_verbose=0 mock_status mock_extra mock_exit mock_omit mock_duplicate

    print -r -- "$*" >>"$MOCK_CMD_LOG"

    case "$*" in
    "package help")
        if [ "${MOCK_ART_HELP_VERBOSE:-1}" -eq 1 ]; then
            print -r -- '-v Verbose mode. This mode prints detailed results.'
        else
            print -r -- 'Package compile help (legacy mock).'
        fi
        return 0
        ;;
    esac

    while [ "$#" -gt 0 ]; do
        case "$1" in
        -v)
            mock_verbose=1
            ;;
        -f)
            if [ "$#" -ge 2 ]; then
                mock_pkg="$2"
                shift
            fi
            ;;
        esac
        shift
    done

    mock_status="${MOCK_ART_DEFAULT_STATUS:-PERFORMED}"
    mock_extra=""
    mock_exit=0
    mock_omit=0
    mock_duplicate=0

    if [ -n "${MOCK_ART_SPECIAL_PACKAGE:-}" ] &&
        [ "$mock_pkg" = "$MOCK_ART_SPECIAL_PACKAGE" ]; then

        [ -n "${MOCK_ART_SPECIAL_STATUS:-}" ] &&
            mock_status="$MOCK_ART_SPECIAL_STATUS"
        mock_extra="${MOCK_ART_SPECIAL_EXTRA:-}"
        mock_exit="${MOCK_ART_SPECIAL_EXIT:-0}"
        mock_omit="${MOCK_ART_SPECIAL_OMIT_STATUS:-0}"
        mock_duplicate="${MOCK_ART_SPECIAL_DUPLICATE_STATUS:-0}"
    fi

    if [ "$mock_verbose" -eq 1 ]; then
        if [ "$mock_omit" -eq 0 ]; then
            print -r -- "Final Status: $mock_status"
            if [ "$mock_duplicate" -eq 1 ]; then
                print -r -- "Final Status: $mock_status"
            fi
        fi

        if [ -n "$mock_extra" ]; then
            print -r -- "Extended Status: [$mock_extra]"
        fi
    fi

    return "$mock_exit"
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
    assert_eq "$USER_PKGS_COUNT" 7 "Dry-run parsed user packages" || failures=1
    assert_eq "$TOTAL_COMPILED" 0 "Dry-run performed packages" || failures=1
    assert_eq "$TOTAL_ART_SKIPPED" 0 "Dry-run ART-skipped packages" || failures=1
    assert_eq "$TOTAL_SKIPPED" 4 "Dry-run cached skips" || failures=1
    assert_eq "$TOTAL_WOULD_COMPILE" 3 "Dry-run would compile" || failures=1
    assert_eq "$TOTAL_FAILED" 0 "Dry-run compilation failures" || failures=1
    assert_eq "$TOTAL_INVALID" 0 "Dry-run invalid records" || failures=1

    assert_empty "$CURRENT_RUN_STATE" "Dry-run current-run state path" || failures=1
    assert_empty "$ERROR_TMPFILE" "Dry-run compile-error tempfile path" || failures=1
    assert_empty "$RUN_ERROR_TMPFILE" "Dry-run maintenance-error tempfile path" || failures=1

    assert_text_contains "$(<"$STAGE_MERGED")" "com.test.equals|" \
        "Equals-containing APK path survives last-separator parsing" || failures=1

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

    assert_eq "$SYSTEM_PKGS_COUNT" 7 "System-mode parsed system packages" || failures=1
    assert_eq "$USER_PKGS_COUNT" 0 "System-mode parsed user packages" || failures=1
    assert_eq "$TOTAL_SKIPPED" 4 "System-mode cached skips" || failures=1
    assert_eq "$TOTAL_WOULD_COMPILE" 3 "System-mode would compile" || failures=1
    assert_eq "$TOTAL_FAILED" 0 "System-mode compilation failures" || failures=1
    assert_eq "$TOTAL_INVALID" 0 "System-mode invalid records" || failures=1
    assert_empty "$CURRENT_RUN_STATE" "System dry-run current-run state path" || failures=1

    return "$failures"
}


test_malformed_versioncode_fails_closed() {
    typeset malformed_list output rc failures=0

    setup_case 1
    prepare_pipeline || return 1

    malformed_list=$(<"$MALFORMED_PACKAGE_FILE")
    output=$(process_packages "$malformed_list" "speed-profile" 2>&1)
    rc=$?

    assert_eq "$rc" 1 "Malformed versionCode batch return code" || failures=1
    assert_text_contains "$output" "Package normalization failed" \
        "Missing versionCode fails normalization closed" || failures=1
    assert_eq "$TOTAL_COMPILED" 0 "Malformed batch performed count" || failures=1
    assert_eq "$TOTAL_ART_SKIPPED" 0 "Malformed batch ART-skipped count" || failures=1
    assert_eq "$TOTAL_SKIPPED" 0 "Malformed batch cached-skip count" || failures=1
    assert_eq "$TOTAL_FAILED" 0 "Malformed batch compile-failure count" || failures=1
    assert_empty "$CURRENT_RUN_STATE" "Malformed batch writes no current-run state" || failures=1

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
    package_list=$(<"$PACKAGE_FILE")

    if ! process_packages "$package_list" "speed-profile"; then
        print -r -- '[!] TEST ERROR: mocked modern ART real-run pipeline failed.' >&2
        return 1
    fi

    assert_eq "$USER_PKGS_COUNT" 7 "Real-run parsed user packages" || failures=1
    assert_eq "$TOTAL_COMPILED" 3 "Real-run ART PERFORMED count" || failures=1
    assert_eq "$TOTAL_ART_SKIPPED" 0 "Real-run ART SKIPPED count" || failures=1
    assert_eq "$TOTAL_SKIPPED" 4 "Real-run cached skips" || failures=1
    assert_eq "$TOTAL_FAILED" 0 "Real-run compilation failures" || failures=1
    assert_eq "$TOTAL_INVALID" 0 "Real-run invalid records" || failures=1
    assert_eq "$TOTAL_WOULD_COMPILE" 0 "Real-run would-compile count" || failures=1

    assert_file_lines "$CURRENT_RUN_STATE" 7 "Real-run state fingerprint count" || failures=1
    assert_file_eq "$CURRENT_RUN_STATE" "$EXPECTED_STATE_FILE" \
        "PERFORMED outcomes earn the expected fingerprints" || failures=1

    assert_file_lines "$MOCK_CMD_LOG" 3 "Real-run mocked compile command count" || failures=1
    assert_file_contains_line "$MOCK_CMD_LOG" \
        "package compile -v -m speed-profile -f com.test.changed" \
        "Changed package uses verbose ART result mode" || failures=1
    assert_file_contains_line "$MOCK_CMD_LOG" \
        "package compile -v -m speed-profile -f com.test.parentfallback" \
        "Parent-fallback package uses verbose ART result mode" || failures=1
    assert_file_contains_line "$MOCK_CMD_LOG" \
        "package compile -v -m speed-profile -f com.test.unavailable" \
        "Unavailable-metadata package uses verbose ART result mode" || failures=1

    assert_empty "$ERROR_TMPFILE" "Successful real-run compile-error tempfile path" || failures=1
    assert_empty "$RUN_ERROR_TMPFILE" "Successful real-run maintenance-error tempfile path" || failures=1

    return "$failures"
}


test_real_run_compile_failure() {
    typeset package_list failures=0

    setup_case 0
    prepare_pipeline || return 1

    MOCK_CMD_LOG=$(mktemp "${TMPDIR}/mock_cmd.$$.XXXXXX") || return 1
    MOCK_ART_SPECIAL_PACKAGE="com.test.changed"
    MOCK_ART_SPECIAL_STATUS="FAILED"
    package_list=$(<"$PACKAGE_FILE")

    if ! process_packages "$package_list" "speed-profile"; then
        print -r -- '[!] TEST ERROR: ART-FAILED laboratory pipeline returned fatal failure.' >&2
        return 1
    fi

    assert_eq "$USER_PKGS_COUNT" 7 "Failure-run parsed user packages" || failures=1
    assert_eq "$TOTAL_COMPILED" 2 "Failure-run ART PERFORMED count" || failures=1
    assert_eq "$TOTAL_ART_SKIPPED" 0 "Failure-run ART SKIPPED count" || failures=1
    assert_eq "$TOTAL_SKIPPED" 4 "Failure-run cached skips" || failures=1
    assert_eq "$TOTAL_FAILED" 1 "ART Final Status FAILED count" || failures=1
    assert_eq "$TOTAL_INVALID" 0 "Failure-run invalid records" || failures=1

    assert_file_lines "$CURRENT_RUN_STATE" 6 "Failure-run state fingerprint count" || failures=1
    assert_file_eq "$CURRENT_RUN_STATE" "$EXPECTED_FAILURE_STATE_FILE" \
        "ART-FAILED package omitted from current-run state" || failures=1

    assert_nonempty_file "$ERROR_TMPFILE" \
        "Compile-error tempfile created lazily after ART failure" || failures=1
    assert_file_contains_line "$MOCK_CMD_LOG" \
        "package compile -v -m speed-profile -f com.test.changed" \
        "ART-failed package reached verbose compiler" || failures=1

    if [ -n "$ERROR_TMPFILE" ] && [ -f "$ERROR_TMPFILE" ]; then
        if ! grep -Fq "result=FAILED; reason=ART Final Status: FAILED): com.test.changed" "$ERROR_TMPFILE"; then
            print -r -- '[!] TEST ASSERTION FAILED: compile-error tempfile missing ART failure verdict' >&2
            failures=1
        else
            print -r -- '[+] Assertion passed: compile-error tempfile contains ART failure verdict'
        fi
    fi

    assert_empty "$RUN_ERROR_TMPFILE" "Failure-run maintenance-error tempfile path" || failures=1

    return "$failures"
}



test_art_result_parser() {
    typeset rc failures=0 transcript

    setup_case 1

    transcript='DexoptResult:
Final Status: PERFORMED'
    parse_art_compile_result "$transcript"
    rc=$?
    assert_eq "$rc" 0 "PERFORMED parser return code" || failures=1
    assert_str_eq "$ART_FINAL_STATUS" "PERFORMED" "PERFORMED parser status" || failures=1
    assert_eq "$ART_FINAL_STATUS_COUNT" 1 "PERFORMED status count" || failures=1

    transcript='DexoptResult:
Final Status: SKIPPED'
    parse_art_compile_result "$transcript"
    rc=$?
    assert_eq "$rc" 0 "SKIPPED parser return code" || failures=1
    assert_str_eq "$ART_FINAL_STATUS" "SKIPPED" "SKIPPED parser status" || failures=1
    assert_eq "$ART_SKIPPED_STORAGE_LOW" 0 "Ordinary SKIPPED storage-low flag" || failures=1

    transcript='DexoptResult:
Extended Status: [EXTENDED_SKIPPED_STORAGE_LOW]
Final Status: SKIPPED'
    parse_art_compile_result "$transcript"
    rc=$?
    assert_eq "$rc" 0 "Storage-low SKIPPED parser return code" || failures=1
    assert_str_eq "$ART_FINAL_STATUS" "SKIPPED" "Storage-low parser status" || failures=1
    assert_eq "$ART_SKIPPED_STORAGE_LOW" 1 "Storage-low skip flag" || failures=1

    transcript='DexoptResult:
Final Status: FAILED'
    parse_art_compile_result "$transcript"
    rc=$?
    assert_eq "$rc" 0 "FAILED parser return code" || failures=1
    assert_str_eq "$ART_FINAL_STATUS" "FAILED" "FAILED parser status" || failures=1

    transcript='DexoptResult:
Final Status: CANCELLED'
    parse_art_compile_result "$transcript"
    rc=$?
    assert_eq "$rc" 0 "CANCELLED parser return code" || failures=1
    assert_str_eq "$ART_FINAL_STATUS" "CANCELLED" "CANCELLED parser status" || failures=1

    transcript='DexoptResult:
Final Status: SOMETHING_NEW'
    parse_art_compile_result "$transcript"
    rc=$?
    assert_eq "$rc" 1 "Unknown-status parser fails closed" || failures=1
    assert_str_eq "$ART_FINAL_STATUS" "UNKNOWN" "Unknown-status normalized verdict" || failures=1
    assert_str_eq "$ART_FINAL_STATUS_RAW" "SOMETHING_NEW" "Unknown-status raw token preserved" || failures=1

    transcript='DexoptResult:
No final verdict here'
    parse_art_compile_result "$transcript"
    rc=$?
    assert_eq "$rc" 1 "Missing-status parser fails closed" || failures=1
    assert_eq "$ART_FINAL_STATUS_COUNT" 0 "Missing-status count" || failures=1

    transcript='Final Status: PERFORMED
Final Status: PERFORMED'
    parse_art_compile_result "$transcript"
    rc=$?
    assert_eq "$rc" 1 "Duplicate Final Status fails closed" || failures=1
    assert_eq "$ART_FINAL_STATUS_COUNT" 2 "Duplicate Final Status count" || failures=1
    assert_str_eq "$ART_FINAL_STATUS" "UNKNOWN" "Duplicate Final Status normalized verdict" || failures=1

    return "$failures"
}

test_real_run_art_skipped_earns_state() {
    typeset package_list failures=0

    setup_case 0
    prepare_pipeline || return 1

    MOCK_CMD_LOG=$(mktemp "${TMPDIR}/mock_cmd.$$.XXXXXX") || return 1
    MOCK_ART_SPECIAL_PACKAGE="com.test.changed"
    MOCK_ART_SPECIAL_STATUS="SKIPPED"
    package_list=$(<"$PACKAGE_FILE")

    if ! process_packages "$package_list" "speed-profile"; then
        print -r -- '[!] TEST ERROR: ART-SKIPPED laboratory pipeline returned fatal failure.' >&2
        return 1
    fi

    assert_eq "$TOTAL_COMPILED" 2 "ART-SKIPPED run PERFORMED count" || failures=1
    assert_eq "$TOTAL_ART_SKIPPED" 1 "ART-SKIPPED run ART skip count" || failures=1
    assert_eq "$TOTAL_SKIPPED" 4 "ART-SKIPPED run cached-skip count" || failures=1
    assert_eq "$TOTAL_FAILED" 0 "ART-SKIPPED run failure count" || failures=1
    assert_file_eq "$CURRENT_RUN_STATE" "$EXPECTED_STATE_FILE" \
        "Ordinary ART SKIPPED earns persistent lineage" || failures=1
    assert_empty "$ERROR_TMPFILE" "ART-SKIPPED run compile-error tempfile" || failures=1

    return "$failures"
}

test_storage_low_skip_retries() {
    typeset package_list failures=0

    setup_case 0
    prepare_pipeline || return 1

    MOCK_CMD_LOG=$(mktemp "${TMPDIR}/mock_cmd.$$.XXXXXX") || return 1
    MOCK_ART_SPECIAL_PACKAGE="com.test.changed"
    MOCK_ART_SPECIAL_STATUS="SKIPPED"
    MOCK_ART_SPECIAL_EXTRA="EXTENDED_SKIPPED_STORAGE_LOW"
    package_list=$(<"$PACKAGE_FILE")

    if ! process_packages "$package_list" "speed-profile"; then
        print -r -- '[!] TEST ERROR: storage-low SKIPPED pipeline returned fatal failure.' >&2
        return 1
    fi

    assert_eq "$TOTAL_COMPILED" 2 "Storage-low run PERFORMED count" || failures=1
    assert_eq "$TOTAL_ART_SKIPPED" 0 "Storage-low SKIPPED is not counted as satisfied ART skip" || failures=1
    assert_eq "$TOTAL_FAILED" 1 "Storage-low SKIPPED becomes retryable failure" || failures=1
    assert_file_eq "$CURRENT_RUN_STATE" "$EXPECTED_FAILURE_STATE_FILE" \
        "Storage-low SKIPPED earns no fingerprint" || failures=1
    assert_nonempty_file "$ERROR_TMPFILE" "Storage-low SKIPPED creates error log" || failures=1

    if [ -n "$ERROR_TMPFILE" ] && [ -f "$ERROR_TMPFILE" ]; then
        if ! grep -Fq "storage low; retry required" "$ERROR_TMPFILE"; then
            print -r -- '[!] TEST ASSERTION FAILED: storage-low retry reason missing from error log' >&2
            failures=1
        else
            print -r -- '[+] Assertion passed: storage-low retry reason recorded'
        fi
    fi

    return "$failures"
}

test_missing_final_status_fails_closed() {
    typeset package_list failures=0

    setup_case 0
    prepare_pipeline || return 1

    MOCK_CMD_LOG=$(mktemp "${TMPDIR}/mock_cmd.$$.XXXXXX") || return 1
    MOCK_ART_SPECIAL_PACKAGE="com.test.changed"
    MOCK_ART_SPECIAL_OMIT_STATUS=1
    package_list=$(<"$PACKAGE_FILE")

    if ! process_packages "$package_list" "speed-profile"; then
        print -r -- '[!] TEST ERROR: missing-status pipeline returned fatal failure.' >&2
        return 1
    fi

    assert_eq "$TOTAL_COMPILED" 2 "Missing-status run PERFORMED count" || failures=1
    assert_eq "$TOTAL_ART_SKIPPED" 0 "Missing-status run ART skip count" || failures=1
    assert_eq "$TOTAL_FAILED" 1 "Missing Final Status fails closed" || failures=1
    assert_file_eq "$CURRENT_RUN_STATE" "$EXPECTED_FAILURE_STATE_FILE" \
        "Missing Final Status earns no fingerprint" || failures=1

    if [ -n "$ERROR_TMPFILE" ] && [ -f "$ERROR_TMPFILE" ]; then
        if ! grep -Fq "missing ART Final Status" "$ERROR_TMPFILE"; then
            print -r -- '[!] TEST ASSERTION FAILED: missing-status reason absent from error log' >&2
            failures=1
        else
            print -r -- '[+] Assertion passed: missing-status reason recorded'
        fi
    else
        print -r -- '[!] TEST ASSERTION FAILED: missing-status run created no compile-error tempfile' >&2
        failures=1
    fi

    return "$failures"
}

test_nonzero_exit_overrides_performed() {
    typeset package_list failures=0

    setup_case 0
    prepare_pipeline || return 1

    MOCK_CMD_LOG=$(mktemp "${TMPDIR}/mock_cmd.$$.XXXXXX") || return 1
    MOCK_ART_SPECIAL_PACKAGE="com.test.changed"
    MOCK_ART_SPECIAL_STATUS="PERFORMED"
    MOCK_ART_SPECIAL_EXIT=7
    package_list=$(<"$PACKAGE_FILE")

    if ! process_packages "$package_list" "speed-profile"; then
        print -r -- '[!] TEST ERROR: nonzero-exit pipeline returned fatal failure.' >&2
        return 1
    fi

    assert_eq "$TOTAL_COMPILED" 2 "Nonzero-exit run trusted PERFORMED count" || failures=1
    assert_eq "$TOTAL_FAILED" 1 "Nonzero command exit overrides PERFORMED text" || failures=1
    assert_file_eq "$CURRENT_RUN_STATE" "$EXPECTED_FAILURE_STATE_FILE" \
        "Nonzero command exit earns no fingerprint" || failures=1

    return "$failures"
}

test_legacy_exit_code_fallback() {
    typeset package_list failures=0

    setup_case 0
    prepare_pipeline || return 1

    ART_VERBOSE_RESULTS=0
    ART_RESULT_MODE="legacy-exit-code"

    MOCK_CMD_LOG=$(mktemp "${TMPDIR}/mock_cmd.$$.XXXXXX") || return 1
    package_list=$(<"$PACKAGE_FILE")

    if ! process_packages "$package_list" "speed-profile"; then
        print -r -- '[!] TEST ERROR: legacy result-mode pipeline failed.' >&2
        return 1
    fi

    assert_eq "$TOTAL_COMPILED" 3 "Legacy zero-exit compile-success count" || failures=1
    assert_eq "$TOTAL_ART_SKIPPED" 0 "Legacy mode ART skip count" || failures=1
    assert_eq "$TOTAL_FAILED" 0 "Legacy mode failure count" || failures=1
    assert_file_eq "$CURRENT_RUN_STATE" "$EXPECTED_STATE_FILE" \
        "Legacy zero-exit fallback still earns state" || failures=1
    assert_file_contains_line "$MOCK_CMD_LOG" \
        "package compile -m speed-profile -f com.test.changed" \
        "Legacy mode omits unsupported -v flag" || failures=1
    assert_file_not_contains "$MOCK_CMD_LOG" "package compile -v" \
        "Legacy mode never sends verbose compile flag" || failures=1

    return "$failures"
}

test_force_bypasses_cache() {
    typeset package_list failures=0

    setup_case 1
    prepare_pipeline || return 1

    FORCE=1
    QUIET=1
    DEBUG=0
    package_list=$(<"$PACKAGE_FILE")

    if ! process_packages "$package_list" "speed-profile"; then
        print -r -- '[!] TEST ERROR: forced dry-run pipeline failed.' >&2
        return 1
    fi

    assert_eq "$TOTAL_SKIPPED" 0 "Force-mode cached skips" || failures=1
    assert_eq "$TOTAL_WOULD_COMPILE" 7 "Force-mode would compile" || failures=1
    assert_eq "$TOTAL_INVALID" 0 "Force-mode invalid records" || failures=1
    assert_eq "$USER_PKGS_COUNT" 7 "Force-mode parsed user packages" || failures=1

    return "$failures"
}


test_quiet_suppresses_routine_progress() {
    typeset package_list quiet_text failures=0

    setup_case 1
    prepare_pipeline || return 1

    QUIET=1
    DEBUG=0
    QUIET_STDOUT=$(mktemp "${TMPDIR}/quiet_stdout.$$.XXXXXX") || return 1
    QUIET_STDERR=$(mktemp "${TMPDIR}/quiet_stderr.$$.XXXXXX") || return 1
    package_list=$(<"$PACKAGE_FILE")

    if ! process_packages "$package_list" "speed-profile" \
        >"$QUIET_STDOUT" 2>"$QUIET_STDERR"; then
        print -r -- '[!] TEST ERROR: quiet dry-run pipeline failed.' >&2
        return 1
    fi

    quiet_text=$(<"$QUIET_STDOUT")

    assert_text_not_contains "$quiet_text" "Skipping unchanged:" \
        "Quiet mode suppresses cached-package progress" || failures=1
    assert_text_not_contains "$quiet_text" "Would compile" \
        "Quiet mode suppresses dry-run compile progress" || failures=1
    assert_eq "$TOTAL_SKIPPED" 4 "Quiet-mode cached skips" || failures=1
    assert_eq "$TOTAL_WOULD_COMPILE" 3 "Quiet-mode would compile" || failures=1
    assert_eq "$TOTAL_INVALID" 0 "Quiet-mode invalid records" || failures=1

    return "$failures"
}

test_health_json_and_battery_policies() {
    typeset output errors failures=0

    prepare_cli_case || return 1

    run_cli --health-only --json
    output=$(<"$CLI_STDOUT")
    errors=$(<"$CLI_STDERR")

    assert_eq "$CLI_RC" 0 "Health-only JSON return code" || failures=1
    assert_file_lines "$CLI_STDOUT" 1 "Health-only JSON stdout line count" || failures=1
    assert_text_contains "$output" '"success":true' \
        "Health-only JSON reports success" || failures=1
    assert_text_contains "$output" '"mode":"health-only"' \
        "Health-only JSON mode" || failures=1
    assert_text_contains "$output" '"scope":"none"' \
        "Health-only JSON scope" || failures=1
    assert_text_contains "$output" '"cache_trim":null' \
        "Health-only cache trim is not applicable" || failures=1
    assert_text_contains "$output" '"charging":true' \
        "Health-only JSON reports charging state" || failures=1
    assert_file_empty "$CLI_PM_LOG" \
        "Health-only mode performs no Package Manager operations" || failures=1
    assert_file_empty "$CLI_CMD_LOG" \
        "Health-only mode never interrogates ART capability" || failures=1
    assert_text_not_contains "$output" "HEALTH CHECK" \
        "JSON stdout contains no human health report" || failures=1
    assert_text_not_contains "$errors" "HEALTH CHECK" \
        "Successful non-debug JSON suppresses human stderr report" || failures=1

    run_cli --health-only --json --require-charging --min-battery=50
    output=$(<"$CLI_STDOUT")

    assert_eq "$CLI_RC" 0 "Satisfied battery-policy return code" || failures=1
    assert_text_contains "$output" '"success":true' \
        "Satisfied battery policies preserve success" || failures=1
    assert_text_contains "$output" '"require_charging":true' \
        "Satisfied charging policy is represented in JSON" || failures=1
    assert_text_contains "$output" '"min_battery_percent":50' \
        "Equals-form minimum battery is represented in JSON" || failures=1
    assert_text_contains "$output" '"battery_percent":80' \
        "Satisfied minimum-battery policy reports observed level" || failures=1
    assert_text_contains "$output" '"charging":true' \
        "Satisfied charging policy reports external power" || failures=1
    assert_file_empty "$CLI_PM_LOG" \
        "Satisfied health-only policies perform no PM operations" || failures=1

    CLI_MOCK_BATTERY_LEVEL=40
    run_cli --health-only --json --min-battery 50
    output=$(<"$CLI_STDOUT")
    errors=$(<"$CLI_STDERR")

    assert_eq "$CLI_RC" 1 "Minimum-battery rejection return code" || failures=1
    assert_text_contains "$output" '"success":false' \
        "Minimum-battery rejection emits failure JSON" || failures=1
    assert_text_contains "$output" '"min_battery_percent":50' \
        "Minimum-battery JSON threshold" || failures=1
    assert_text_contains "$output" '"battery_percent":40' \
        "Minimum-battery JSON observed level" || failures=1
    assert_text_contains "$errors" "below required minimum 50%" \
        "Minimum-battery rejection remains visible on stderr" || failures=1
    assert_file_empty "$CLI_PM_LOG" \
        "Rejected health-only battery policy performs no PM operations" || failures=1

    CLI_MOCK_BATTERY_LEVEL=80
    CLI_MOCK_CHARGING=0
    run_cli --health-only --json --require-charging
    output=$(<"$CLI_STDOUT")
    errors=$(<"$CLI_STDERR")

    assert_eq "$CLI_RC" 1 "Require-charging rejection return code" || failures=1
    assert_text_contains "$output" '"success":false' \
        "Require-charging rejection emits failure JSON" || failures=1
    assert_text_contains "$output" '"charging":false' \
        "Require-charging JSON reports unplugged state" || failures=1
    assert_text_contains "$errors" "External power is required" \
        "Require-charging rejection remains visible on stderr" || failures=1

    CLI_MOCK_CHARGING=1
    run_cli --health-only --json --debug
    output=$(<"$CLI_STDOUT")
    errors=$(<"$CLI_STDERR")

    assert_eq "$CLI_RC" 0 "Debug JSON health return code" || failures=1
    assert_file_lines "$CLI_STDOUT" 1 "Debug JSON stdout line count" || failures=1
    assert_text_contains "$output" '"success":true' \
        "Debug JSON keeps machine-readable stdout" || failures=1
    assert_text_contains "$errors" "[DEBUG]" \
        "Debug JSON retains diagnostics on stderr" || failures=1
    assert_text_contains "$errors" "HEALTH CHECK" \
        "Debug JSON retains human health report on stderr" || failures=1

    return "$failures"
}


test_no_trim_json_cli() {
    typeset output errors failures=0

    prepare_cli_case || return 1
    cp "$CLI_FULL_STATE_FILE" "${CLI_RUN_DIR}/.last_optimized" || return 1

    run_cli --no-trim --json
    output=$(<"$CLI_STDOUT")
    errors=$(<"$CLI_STDERR")

    assert_eq "$CLI_RC" 0 "No-trim JSON return code" || failures=1
    assert_file_lines "$CLI_STDOUT" 1 "No-trim JSON stdout line count" || failures=1
    assert_text_contains "$output" '"scope":"full"' \
        "No-trim JSON full scope" || failures=1
    assert_text_contains "$output" '"cache_trim":false' \
        "No-trim JSON reports cache trim disabled" || failures=1
    assert_text_contains "$output" '"compiled":0' \
        "No-trim cached run PERFORMED count" || failures=1
    assert_text_contains "$output" '"art_skipped":0' \
        "No-trim cached run ART-skipped count" || failures=1
    assert_text_contains "$output" '"skipped":4' \
        "No-trim cached run compatibility skipped count" || failures=1
    assert_text_contains "$output" '"cached_skipped":4' \
        "No-trim cached run explicit cached-skip count" || failures=1
    assert_text_contains "$output" '"art_result_mode":"not-determined"' \
        "Fully cached real run leaves ART result mode undetermined" || failures=1
    assert_text_contains "$output" '"scanned":4' \
        "No-trim cached run scanned count" || failures=1
    assert_text_not_contains "$output" "[+]" \
        "No-trim JSON stdout contains no human progress" || failures=1
    assert_file_empty "$CLI_STDERR" \
        "Successful non-debug JSON emits no routine stderr output" || failures=1

    assert_file_contains_line "$CLI_PM_LOG" "list packages -f -s --show-versioncode" \
        "No-trim run queries system packages with versionCode" || failures=1
    assert_file_contains_line "$CLI_PM_LOG" "list packages -f -3 --show-versioncode" \
        "No-trim run queries user packages with versionCode" || failures=1
    assert_file_not_contains "$CLI_PM_LOG" "trim-caches" \
        "No-trim run never calls pm trim-caches" || failures=1

    assert_file_empty "$CLI_CMD_LOG" \
        "Fully cached real run performs no ART capability probe or compile" || failures=1

    assert_file_eq "${CLI_RUN_DIR}/.last_optimized" "$CLI_FULL_STATE_FILE" \
        "No-trim run preserves authoritative full state" || failures=1

    return "$failures"
}


test_user_only_state_lifecycle() {
    typeset output failures=0

    prepare_cli_case || return 1
    cp "$CLI_FULL_STATE_FILE" "${CLI_RUN_DIR}/.last_optimized" || return 1

    # With no dedicated user-only cache yet, the complete state is the trusted
    # baseline. The user-only run should skip both user packages and create only
    # the dedicated user-scope state file.
    run_cli --user-only --no-trim --json
    output=$(<"$CLI_STDOUT")

    assert_eq "$CLI_RC" 0 "Initial user-only return code" || failures=1
    assert_text_contains "$output" '"scope":"user-only"' \
        "Initial user-only JSON scope" || failures=1
    assert_text_contains "$output" '"compiled":0' \
        "Initial user-only PERFORMED count" || failures=1
    assert_text_contains "$output" '"art_skipped":0' \
        "Initial user-only ART-skipped count" || failures=1
    assert_text_contains "$output" '"cached_skipped":2' \
        "Initial user-only reuses complete-state baseline" || failures=1
    assert_text_contains "$output" '"art_result_mode":"not-determined"' \
        "Initial cached user-only run leaves ART mode undetermined" || failures=1
    assert_text_contains "$output" '"scanned":2' \
        "Initial user-only scans only user packages" || failures=1
    assert_file_contains_line "$CLI_PM_LOG" "list packages -f -3 --show-versioncode" \
        "User-only run queries user packages with versionCode" || failures=1
    assert_file_not_contains "$CLI_PM_LOG" "list packages -f -s --show-versioncode" \
        "User-only run skips system package query" || failures=1
    assert_file_exists "${CLI_RUN_DIR}/.last_optimized_user" \
        "Initial user-only run creates dedicated state" || failures=1
    assert_file_eq "${CLI_RUN_DIR}/.last_optimized_user" "$CLI_USER_STATE_FILE" \
        "Dedicated user-only state contains only user fingerprints" || failures=1
    assert_file_eq "${CLI_RUN_DIR}/.last_optimized" "$CLI_FULL_STATE_FILE" \
        "User-only run leaves authoritative full state untouched" || failures=1
    assert_file_empty "$CLI_CMD_LOG" \
        "Initial cached user-only run does not interrogate ART" || failures=1

    # The next identical user-only run must use its dedicated cache directly.
    run_cli --user-only --no-trim --json
    output=$(<"$CLI_STDOUT")

    assert_eq "$CLI_RC" 0 "Repeated user-only return code" || failures=1
    assert_text_contains "$output" '"compiled":0' \
        "Repeated user-only PERFORMED count" || failures=1
    assert_text_contains "$output" '"cached_skipped":2' \
        "Repeated user-only uses dedicated cache" || failures=1
    assert_text_contains "$output" '"art_result_mode":"not-determined"' \
        "Repeated cached user-only run still leaves ART mode undetermined" || failures=1
    assert_file_empty "$CLI_CMD_LOG" \
        "Repeated cached user-only run performs no ART probe or compile" || failures=1
    assert_file_eq "${CLI_RUN_DIR}/.last_optimized_user" "$CLI_USER_STATE_FILE" \
        "Repeated user-only state remains stable" || failures=1

    # A successful complete run supersedes scope-specific caches.
    run_cli --no-trim --json
    output=$(<"$CLI_STDOUT")

    assert_eq "$CLI_RC" 0 "Full run after user-only return code" || failures=1
    assert_text_contains "$output" '"scope":"full"' \
        "Full run restores full JSON scope" || failures=1
    assert_text_contains "$output" '"cached_skipped":4' \
        "Full run reuses authoritative full state" || failures=1
    assert_text_contains "$output" '"art_result_mode":"not-determined"' \
        "Fully cached complete run leaves ART mode undetermined" || failures=1
    assert_file_empty "$CLI_CMD_LOG" \
        "Fully cached complete run performs no ART probe or compile" || failures=1
    assert_file_missing "${CLI_RUN_DIR}/.last_optimized_user" \
        "Successful full run removes superseded user-only state" || failures=1
    assert_file_eq "${CLI_RUN_DIR}/.last_optimized" "$CLI_FULL_STATE_FILE" \
        "Successful full run leaves authoritative state current" || failures=1

    return "$failures"
}


test_cached_dry_run_probes_result_mode() {
    typeset output failures=0

    prepare_cli_case || return 1
    cp "$CLI_FULL_STATE_FILE" "${CLI_RUN_DIR}/.last_optimized" || return 1

    # Dry-run is the deliberate exception: it rehearses which ART result path a
    # real compile would use even though every package is already cached.
    run_cli --dry-run --no-trim --json
    output=$(<"$CLI_STDOUT")

    assert_eq "$CLI_RC" 0 "Cached dry-run return code" || failures=1
    assert_text_contains "$output" '"dry_run":true' \
        "Cached dry-run JSON mode" || failures=1
    assert_text_contains "$output" '"art_result_mode":"final-status"' \
        "Cached dry-run proactively learns modern ART result mode" || failures=1
    assert_text_contains "$output" '"would_compile":0' \
        "Cached dry-run has no packages needing ART" || failures=1
    assert_text_contains "$output" '"cached_skipped":4' \
        "Cached dry-run preserves cache accounting" || failures=1
    assert_file_contains_line "$CLI_CMD_LOG" "package help" \
        "Cached dry-run probes ART capability for rehearsal" || failures=1
    assert_file_not_contains "$CLI_CMD_LOG" "package compile" \
        "Cached dry-run never performs compilation" || failures=1
    assert_file_eq "${CLI_RUN_DIR}/.last_optimized" "$CLI_FULL_STATE_FILE" \
        "Cached dry-run leaves persistent state untouched" || failures=1

    return "$failures"
}


test_cli_modern_result_detection_when_needed() {
    typeset output failures=0

    prepare_cli_case || return 1

    # No prior state means packages must reach ART. Capability discovery should
    # therefore happen lazily at the first real compile, then be reused.
    run_cli --no-trim --json
    output=$(<"$CLI_STDOUT")

    assert_eq "$CLI_RC" 0 "Modern lazy capability-detection return code" || failures=1
    assert_text_contains "$output" '"art_result_mode":"final-status"' \
        "First ART-bound package selects Final Status verification" || failures=1
    assert_text_contains "$output" '"compiled":4' \
        "Modern lazy-detection run performs all uncached packages" || failures=1
    assert_text_contains "$output" '"cached_skipped":0' \
        "Modern lazy-detection run has no cached skips" || failures=1
    assert_file_contains_line "$CLI_CMD_LOG" "package help" \
        "Modern capability is discovered when ART is first needed" || failures=1
    assert_file_lines "$CLI_CMD_LOG" 5 \
        "Modern lazy detection probes once plus four compile calls" || failures=1
    assert_file_contains_line "$CLI_CMD_LOG" \
        "package compile -v -m speed -f com.test.exact" \
        "Modern system compile uses verbose Final Status mode" || failures=1
    assert_file_contains_line "$CLI_CMD_LOG" \
        "package compile -v -m speed-profile -f com.test.equals" \
        "Modern user compile reuses verbose Final Status mode" || failures=1
    assert_file_eq "${CLI_RUN_DIR}/.last_optimized" "$CLI_FULL_STATE_FILE" \
        "Modern lazy-detection run commits complete state" || failures=1

    return "$failures"
}


test_cli_legacy_result_detection_when_needed() {
    typeset output failures=0

    prepare_cli_case || return 1

    CLI_MOCK_ART_HELP_VERBOSE=0
    run_cli --no-trim --json
    output=$(<"$CLI_STDOUT")

    assert_eq "$CLI_RC" 0 "Legacy lazy capability-detection return code" || failures=1
    assert_text_contains "$output" '"art_result_mode":"legacy-exit-code"' \
        "First ART-bound package selects legacy exit-code fallback" || failures=1
    assert_text_contains "$output" '"compiled":4' \
        "Legacy lazy-detection run accepts four zero-exit successes" || failures=1
    assert_text_contains "$output" '"cached_skipped":0' \
        "Legacy lazy-detection run has no cached skips" || failures=1
    assert_file_contains_line "$CLI_CMD_LOG" "package help" \
        "Legacy capability is discovered only when ART is needed" || failures=1
    assert_file_lines "$CLI_CMD_LOG" 5 \
        "Legacy lazy detection probes once plus four compile calls" || failures=1
    assert_file_not_contains "$CLI_CMD_LOG" "package compile -v" \
        "Legacy compile path never sends unsupported -v" || failures=1
    assert_file_contains_line "$CLI_CMD_LOG" \
        "package compile -m speed -f com.test.exact" \
        "Legacy system compile uses exit-code mode" || failures=1
    assert_file_eq "${CLI_RUN_DIR}/.last_optimized" "$CLI_FULL_STATE_FILE" \
        "Legacy lazy-detection run commits complete state" || failures=1

    return "$failures"
}

test_cli_option_validation() {
    typeset errors failures=0

    prepare_cli_case || return 1

    run_cli --no-user --user-only
    errors=$(<"$CLI_STDERR")

    assert_eq "$CLI_RC" 1 "Mutually exclusive scope options return code" || failures=1
    assert_text_contains "$errors" "mutually exclusive" \
        "Mutually exclusive scope options fail clearly" || failures=1
    assert_file_empty "$CLI_PM_LOG" \
        "Scope-option conflict fails before PM operations" || failures=1

    run_cli --min-battery 101
    errors=$(<"$CLI_STDERR")

    assert_eq "$CLI_RC" 1 "Out-of-range minimum battery return code" || failures=1
    assert_text_contains "$errors" "between 0 and 100" \
        "Out-of-range minimum battery fails clearly" || failures=1
    assert_file_empty "$CLI_PM_LOG" \
        "Invalid minimum battery fails before PM operations" || failures=1

    return "$failures"
}

# ============================================================================
# INPUT VALIDATION
# ============================================================================

for required_file in \
    "$PACKAGE_FILE" \
    "$MALFORMED_PACKAGE_FILE" \
    "$STATE_FILE" \
    "$EXPECTED_STATE_FILE" \
    "$EXPECTED_FAILURE_STATE_FILE" \
    "$CLI_SYSTEM_PACKAGE_FILE" \
    "$CLI_USER_PACKAGE_FILE" \
    "$CLI_FULL_STATE_FILE" \
    "$CLI_USER_STATE_FILE"; do

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
print -r -- ' ART MAINTENANCE LABORATORY'
print -r -- '============================================================'
print -r -- " Package input:          $PACKAGE_FILE"
print -r -- " Malformed PM input:     $MALFORMED_PACKAGE_FILE"
print -r -- " State baseline:         $STATE_FILE"
print -r -- " Expected success state: $EXPECTED_STATE_FILE"
print -r -- " Expected failure state: $EXPECTED_FAILURE_STATE_FILE"
print -r -- " CLI system packages:    $CLI_SYSTEM_PACKAGE_FILE"
print -r -- " CLI user packages:      $CLI_USER_PACKAGE_FILE"
print -r -- " CLI full state:         $CLI_FULL_STATE_FILE"
print -r -- " CLI user state:         $CLI_USER_STATE_FILE"
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
run_case 'Missing versionCode normalization fails closed' test_malformed_versioncode_fails_closed
run_case 'Empty user package list succeeds' test_empty_user_list
run_case 'Empty system package list fails closed' test_empty_system_list
run_case 'ART Final Status parser matrix' test_art_result_parser
run_case 'Modern ART PERFORMED earns state' test_real_run_success
run_case 'Modern ART SKIPPED earns state' test_real_run_art_skipped_earns_state
run_case 'ART Final Status FAILED earns no state' test_real_run_compile_failure
run_case 'Storage-low ART SKIPPED retries' test_storage_low_skip_retries
run_case 'Missing ART Final Status fails closed' test_missing_final_status_fails_closed
run_case 'Nonzero command exit overrides PERFORMED text' test_nonzero_exit_overrides_performed
run_case 'Legacy exit-code fallback remains compatible' test_legacy_exit_code_fallback
run_case 'Force bypasses fingerprint cache' test_force_bypasses_cache
run_case 'Quiet suppresses routine package progress' test_quiet_suppresses_routine_progress
run_case 'Health-only JSON and battery policy gates' test_health_json_and_battery_policies
run_case 'Fully cached real run leaves ART capability unknown' test_no_trim_json_cli
run_case 'User-only state lifecycle' test_user_only_state_lifecycle
run_case 'Cached dry-run probes would-use ART result mode' test_cached_dry_run_probes_result_mode
run_case 'CLI lazily detects modern ART mode when needed' test_cli_modern_result_detection_when_needed
run_case 'CLI lazily detects legacy ART mode when needed' test_cli_legacy_result_detection_when_needed
run_case 'CLI option validation' test_cli_option_validation

print -r -- ''
print -r -- '============================================================'
print -r -- ' ART MAINTENANCE LABORATORY SUMMARY'
print -r -- '============================================================'
print -r -- " Test cases: $TEST_CASES"
print -r -- " Passed:     $((TEST_CASES - TEST_FAILURES))"
print -r -- " Failed:     $TEST_FAILURES"
print -r -- '============================================================'

if [ "$TEST_FAILURES" -ne 0 ]; then
    print -r -- '[!] ART MAINTENANCE LABORATORY FAILED' >&2
    exit 1
fi

print -r -- '[+] All ART maintenance laboratory tests passed.'
exit 0
