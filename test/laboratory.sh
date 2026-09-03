#!/system/bin/sh
# shellcheck shell=ksh

# ============================================================================
# ART PACKAGE PIPELINE LABORATORY
# Purpose: Exercise maintenance.sh's real process_packages() pipeline using
#          controlled package-list and previous-state inputs.
# ============================================================================

TEST_DIR="${0%/*}"
[ "$TEST_DIR" = "$0" ] && TEST_DIR="."

# maintenance.sh lives one directory above test/.
REPO_ROOT="${TEST_DIR}/.."

PACKAGE_FILE="${1-${TEST_DIR}/test_packages_list.txt}"
STATE_FILE="${2-${TEST_DIR}/test_last_optimized}"
TEST_MODE="${3-speed-profile}"

# Load maintenance.sh functions without executing normal maintenance.
MAINTENANCE_SOURCE_ONLY=1
. "${REPO_ROOT}/maintenance.sh"

# Match the production shell/runtime environment.
DEBUG=1
DRY_RUN=1
NO_USER=0
runtime_setup

lab_cleanup() {
    lab_exit=$?

    exec 3>&- 2>/dev/null || true

    for tmpfile in \
        "${CURRENT_RUN_STATE:-}" \
        "${STAGE_PATHS:-}" \
        "${STAGE_STATS:-}" \
        "${STAGE_MERGED:-}" \
        "${ERROR_TMPFILE:-}"; do

        if [ -n "$tmpfile" ] && [ -e "$tmpfile" ]; then
            rm -f "$tmpfile" 2>/dev/null || true
        fi
    done

    exit "$lab_exit"
}

trap 'lab_cleanup' EXIT

case "$TEST_MODE" in
system | speed-profile)
    ;;
*)
    printf '[!] TEST ERROR: Invalid mode: %s\n' "$TEST_MODE" >&2
    exit 1
    ;;
esac

if [ ! -r "$PACKAGE_FILE" ]; then
    printf '[!] TEST ERROR: Cannot read package list: %s\n' "$PACKAGE_FILE" >&2
    exit 1
fi

if [ ! -r "$STATE_FILE" ]; then
    printf '[!] TEST ERROR: Cannot read previous state: %s\n' "$STATE_FILE" >&2
    exit 1
fi

# Create exactly the temporary files required by process_packages().
if ! package_pipeline_setup; then
    exit 1
fi

# Load controlled package-manager input.
package_list=$(<"$PACKAGE_FILE")

# Match maintenance.sh's PREV_STATE representation: leading/trailing newlines
# allow exact whole-line fingerprint matching.
PREV_STATE="
$(<"$STATE_FILE")
"

printf '\n'
printf '============================================================\n'
printf ' ART PACKAGE PIPELINE LABORATORY\n'
printf '============================================================\n'
printf ' Package input:  %s\n' "$PACKAGE_FILE"
printf ' State baseline: %s\n' "$STATE_FILE"
printf ' Mode:           %s\n' "$TEST_MODE"
printf '============================================================\n\n'

if ! process_packages "$package_list" "$TEST_MODE"; then
    printf '\n[!] PACKAGE PIPELINE TEST FAILED\n' >&2
    exit 1
fi

printf '\n'
printf '============================================================\n'
printf ' PACKAGE PIPELINE TEST COMPLETED\n'
printf '============================================================\n'
printf ' Parsed system packages: %d\n' "$SYSTEM_PKGS_COUNT"
printf ' Parsed user packages:   %d\n' "$USER_PKGS_COUNT"
printf ' Skipped unchanged:      %d\n' "$TOTAL_SKIPPED"
printf ' Would compile:          %d\n' "$TOTAL_WOULD_COMPILE"
printf ' Invalid:                %d\n' "$TOTAL_INVALID"
printf '============================================================\n'

if [ -s "$CURRENT_RUN_STATE" ]; then
    printf '\nState produced by the pipeline:\n'
    printf '%s\n' '------------------------------------------------------------'
    cat "$CURRENT_RUN_STATE"
    printf '%s\n' '------------------------------------------------------------'
else
    printf '\nState produced by the pipeline: [empty]\n'
fi
