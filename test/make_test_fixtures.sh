#!/system/bin/sh
# shellcheck shell=ksh

# ============================================================================
# ART PACKAGE PIPELINE TEST FIXTURE GENERATOR
# Purpose: Build deterministic package/state inputs for the maintenance laboratory.
# ============================================================================

TEST_DIR="${0%/*}"
[ "$TEST_DIR" = "$0" ] && TEST_DIR="."

# Android uses /data/local/tmp by default. CI overrides LAB_ROOT with /tmp.
LAB_ROOT="${LAB_ROOT:-/data/local/tmp/art-pipeline-lab}"

PACKAGE_FILE="${TEST_DIR}/test_packages_list.txt"
STATE_FILE="${TEST_DIR}/test_last_optimized"
EXPECTED_STATE_FILE="${TEST_DIR}/test_expected_state.txt"
EXPECTED_FAILURE_STATE_FILE="${TEST_DIR}/test_expected_state_failed.txt"
CLI_SYSTEM_PACKAGE_FILE="${TEST_DIR}/test_cli_system_packages.txt"
CLI_USER_PACKAGE_FILE="${TEST_DIR}/test_cli_user_packages.txt"
CLI_FULL_STATE_FILE="${TEST_DIR}/test_cli_full_state.txt"
CLI_USER_STATE_FILE="${TEST_DIR}/test_cli_user_state.txt"

# LAB_ROOT is recursively deleted below. Require an absolute, non-system root.
case "$LAB_ROOT" in
/*)
    ;;
*)
    print -r -- "[!] TEST ERROR: LAB_ROOT must be an absolute path: $LAB_ROOT" >&2
    exit 1
    ;;
esac

case "$LAB_ROOT" in
/ | /tmp | /data | /data/local | /data/local/tmp)
    print -r -- "[!] TEST ERROR: Refusing unsafe LAB_ROOT: $LAB_ROOT" >&2
    exit 1
    ;;
esac

rm -rf "$LAB_ROOT"

mkdir -p \
    "$LAB_ROOT/exact" \
    "$LAB_ROOT/changed" \
    "$LAB_ROOT/equals==path" \
    "$LAB_ROOT/duplicate" \
    "$LAB_ROOT/whitespace" \
    "$LAB_ROOT/crlf" \
    "$LAB_ROOT/parent-fallback"

: >"$LAB_ROOT/exact/base.apk"
: >"$LAB_ROOT/changed/base.apk"
: >"$LAB_ROOT/equals==path/base.apk"
: >"$LAB_ROOT/duplicate/base.apk"
: >"$LAB_ROOT/whitespace/base.apk"
: >"$LAB_ROOT/crlf/base.apk"

# Intentionally DO NOT create:
#
#   $LAB_ROOT/parent-fallback/base.apk
#   $LAB_ROOT/no-parent/
#
# These exercise:
#
#   missing APK + existing parent -> parent-directory fallback
#   missing APK + missing parent  -> UNAVAILABLE

cat >"$PACKAGE_FILE" <<EOF_PACKAGES
package:$LAB_ROOT/exact/base.apk=com.test.exact
package:$LAB_ROOT/changed/base.apk=com.test.changed
package:$LAB_ROOT/equals==path/base.apk=com.test.equals
package:$LAB_ROOT/duplicate/base.apk=com.test.duplicate
package:$LAB_ROOT/duplicate/base.apk=com.test.duplicate
package:$LAB_ROOT/whitespace/base.apk=com.test.bad name
package:$LAB_ROOT/parent-fallback/base.apk=com.test.parentfallback
package:$LAB_ROOT/no-parent/base.apk=com.test.unavailable
garbage-without-equals
package:=com.test.empty.path
package:$LAB_ROOT/exact/base.apk=
package:relative/path/base.apk=com.test.relative
package:$LAB_ROOT/pipe|path/base.apk=com.test.pipepath
package:$LAB_ROOT/exact/base.apk=com.test|pipepkg
EOF_PACKAGES

# Add one otherwise-valid record with a literal CR before the newline.
CR=$'\r'
print -r -- "package:$LAB_ROOT/crlf/base.apk=com.test.crlf${CR}" >>"$PACKAGE_FILE"

EXACT_META=$(stat -c '%Y:%s:%i' "$LAB_ROOT/exact/base.apk")
CHANGED_META=$(stat -c '%Y:%s:%i' "$LAB_ROOT/changed/base.apk")
EQUALS_META=$(stat -c '%Y:%s:%i' "$LAB_ROOT/equals==path/base.apk")
DUPLICATE_META=$(stat -c '%Y:%s:%i' "$LAB_ROOT/duplicate/base.apk")
CRLF_META=$(stat -c '%Y:%s:%i' "$LAB_ROOT/crlf/base.apk")
PARENT_MTIME=$(stat -c '%Y' "$LAB_ROOT/parent-fallback")
PARENT_INODE=$(stat -c '%i' "$LAB_ROOT/parent-fallback")
PARENT_META="${PARENT_MTIME}:0:${PARENT_INODE}"

# Previous state intentionally contains stale metadata for com.test.changed and
# a trustworthy old fingerprint for com.test.unavailable.
cat >"$STATE_FILE" <<EOF_STATE
com.test.exact|$LAB_ROOT/exact/base.apk|$EXACT_META
com.test.changed|$LAB_ROOT/changed/base.apk|1:1:1
com.test.equals|$LAB_ROOT/equals==path/base.apk|$EQUALS_META
com.test.duplicate|$LAB_ROOT/duplicate/base.apk|$DUPLICATE_META
com.test.crlf|$LAB_ROOT/crlf/base.apk|$CRLF_META
com.test.unavailable|$LAB_ROOT/no-parent/base.apk|1234567890:123:456
EOF_STATE

# Expected state after a successful mocked real run. The unavailable package
# preserves its previous trustworthy fingerprint only after compilation succeeds.
cat >"$EXPECTED_STATE_FILE" <<EOF_EXPECTED
com.test.exact|$LAB_ROOT/exact/base.apk|$EXACT_META
com.test.changed|$LAB_ROOT/changed/base.apk|$CHANGED_META
com.test.equals|$LAB_ROOT/equals==path/base.apk|$EQUALS_META
com.test.duplicate|$LAB_ROOT/duplicate/base.apk|$DUPLICATE_META
com.test.parentfallback|$LAB_ROOT/parent-fallback/base.apk|$PARENT_META
com.test.unavailable|$LAB_ROOT/no-parent/base.apk|1234567890:123:456
com.test.crlf|$LAB_ROOT/crlf/base.apk|$CRLF_META
EOF_EXPECTED

# Expected state when com.test.changed is forced to fail compilation. Failed
# packages are omitted so they are retried on the next maintenance run.
cat >"$EXPECTED_FAILURE_STATE_FILE" <<EOF_EXPECTED_FAILURE
com.test.exact|$LAB_ROOT/exact/base.apk|$EXACT_META
com.test.equals|$LAB_ROOT/equals==path/base.apk|$EQUALS_META
com.test.duplicate|$LAB_ROOT/duplicate/base.apk|$DUPLICATE_META
com.test.parentfallback|$LAB_ROOT/parent-fallback/base.apk|$PARENT_META
com.test.unavailable|$LAB_ROOT/no-parent/base.apk|1234567890:123:456
com.test.crlf|$LAB_ROOT/crlf/base.apk|$CRLF_META
EOF_EXPECTED_FAILURE

# Small deterministic package sets for mocked full-CLI integration tests.
# These use only directly stat-able APKs so CLI/state lifecycle assertions stay
# independent of the pipeline laboratory's fallback and invalid-record cases.
cat >"$CLI_SYSTEM_PACKAGE_FILE" <<EOF_CLI_SYSTEM
package:$LAB_ROOT/exact/base.apk=com.test.exact
package:$LAB_ROOT/changed/base.apk=com.test.changed
EOF_CLI_SYSTEM

cat >"$CLI_USER_PACKAGE_FILE" <<EOF_CLI_USER
package:$LAB_ROOT/equals==path/base.apk=com.test.equals
package:$LAB_ROOT/crlf/base.apk=com.test.crlf
EOF_CLI_USER

cat >"$CLI_FULL_STATE_FILE" <<EOF_CLI_FULL_STATE
com.test.exact|$LAB_ROOT/exact/base.apk|$EXACT_META
com.test.changed|$LAB_ROOT/changed/base.apk|$CHANGED_META
com.test.equals|$LAB_ROOT/equals==path/base.apk|$EQUALS_META
com.test.crlf|$LAB_ROOT/crlf/base.apk|$CRLF_META
EOF_CLI_FULL_STATE

cat >"$CLI_USER_STATE_FILE" <<EOF_CLI_USER_STATE
com.test.equals|$LAB_ROOT/equals==path/base.apk|$EQUALS_META
com.test.crlf|$LAB_ROOT/crlf/base.apk|$CRLF_META
EOF_CLI_USER_STATE

print -r -- '[+] Created test fixtures:'
print -r -- "    Package input:         $PACKAGE_FILE"
print -r -- "    State baseline:        $STATE_FILE"
print -r -- "    Expected state:        $EXPECTED_STATE_FILE"
print -r -- "    Expected failed state: $EXPECTED_FAILURE_STATE_FILE"
print -r -- "    CLI system packages:   $CLI_SYSTEM_PACKAGE_FILE"
print -r -- "    CLI user packages:     $CLI_USER_PACKAGE_FILE"
print -r -- "    CLI full state:        $CLI_FULL_STATE_FILE"
print -r -- "    CLI user state:        $CLI_USER_STATE_FILE"
print -r -- "    Laboratory root:       $LAB_ROOT"

print -r -- ''
print -r -- '[+] Expected special cases:'
print -r -- '    Exact duplicate         -> normalized away'
print -r -- '    Relative path           -> rejected during normalization'
print -r -- '    Reserved pipe delimiter -> rejected during normalization'
print -r -- '    Whitespace package      -> rejected during Stage 3'
print -r -- '    Parent fallback         -> parent-directory metadata'
print -r -- '    Unavailable metadata    -> compile + preserve trusted old state'
print -r -- '    CRLF package record     -> normalized correctly'
