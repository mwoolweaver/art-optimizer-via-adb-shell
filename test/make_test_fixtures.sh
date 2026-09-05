#!/system/bin/sh
# shellcheck shell=ksh

# ============================================================================
# ART PACKAGE PIPELINE TEST FIXTURE GENERATOR
# Purpose: Build deterministic package/state inputs for the maintenance laboratory,
#          including versionCode lineage and ART-result verification cases.
# ============================================================================

TEST_DIR="${0%/*}"
[ "$TEST_DIR" = "$0" ] && TEST_DIR="."

LAB_ROOT="${LAB_ROOT:-/data/local/tmp/art-pipeline-lab}"

PACKAGE_FILE="${TEST_DIR}/test_packages_list.txt"
MALFORMED_PACKAGE_FILE="${TEST_DIR}/test_packages_malformed.txt"
STATE_FILE="${TEST_DIR}/test_last_optimized"
EXPECTED_STATE_FILE="${TEST_DIR}/test_expected_state.txt"
EXPECTED_FAILURE_STATE_FILE="${TEST_DIR}/test_expected_state_failed.txt"
CLI_SYSTEM_PACKAGE_FILE="${TEST_DIR}/test_cli_system_packages.txt"
CLI_USER_PACKAGE_FILE="${TEST_DIR}/test_cli_user_packages.txt"
CLI_FULL_STATE_FILE="${TEST_DIR}/test_cli_full_state.txt"
CLI_USER_STATE_FILE="${TEST_DIR}/test_cli_user_state.txt"

# Stable opaque package identities. Equality matters; ordering does not.
V_EXACT=1001
V_CHANGED=1002
V_EQUALS=1003
V_DUPLICATE=1004
V_PARENT=1005
V_UNAVAILABLE=1006
V_CRLF=1007

case "$LAB_ROOT" in
/*) ;;
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
    "$LAB_ROOT/crlf" \
    "$LAB_ROOT/parent-fallback"

: >"$LAB_ROOT/exact/base.apk"
: >"$LAB_ROOT/changed/base.apk"
: >"$LAB_ROOT/equals==path/base.apk"
: >"$LAB_ROOT/duplicate/base.apk"
: >"$LAB_ROOT/crlf/base.apk"

# Intentionally absent:
#   parent-fallback/base.apk -> parent-directory fallback
#   no-parent/               -> UNAVAILABLE metadata

cat >"$PACKAGE_FILE" <<EOF_PACKAGES
package:$LAB_ROOT/exact/base.apk=com.test.exact versionCode:$V_EXACT
package:$LAB_ROOT/changed/base.apk=com.test.changed versionCode:$V_CHANGED
package:$LAB_ROOT/equals==path/base.apk=com.test.equals versionCode:$V_EQUALS
package:$LAB_ROOT/duplicate/base.apk=com.test.duplicate versionCode:$V_DUPLICATE
package:$LAB_ROOT/duplicate/base.apk=com.test.duplicate versionCode:$V_DUPLICATE
package:$LAB_ROOT/parent-fallback/base.apk=com.test.parentfallback versionCode:$V_PARENT
package:$LAB_ROOT/no-parent/base.apk=com.test.unavailable versionCode:$V_UNAVAILABLE
EOF_PACKAGES

CR=$'\r'
print -r -- "package:$LAB_ROOT/crlf/base.apk=com.test.crlf versionCode:$V_CRLF${CR}" >>"$PACKAGE_FILE"

# Modern normalization is deliberately fail-closed. Keep malformed PM output
# separate so the normal pipeline fixture remains trustworthy.
cat >"$MALFORMED_PACKAGE_FILE" <<EOF_MALFORMED
package:$LAB_ROOT/exact/base.apk=com.test.exact
package:$LAB_ROOT/changed/base.apk=com.test.changed versionCode:$V_CHANGED
EOF_MALFORMED

EXACT_META=$(stat -c '%Y:%s:%i' "$LAB_ROOT/exact/base.apk")
CHANGED_META=$(stat -c '%Y:%s:%i' "$LAB_ROOT/changed/base.apk")
EQUALS_META=$(stat -c '%Y:%s:%i' "$LAB_ROOT/equals==path/base.apk")
DUPLICATE_META=$(stat -c '%Y:%s:%i' "$LAB_ROOT/duplicate/base.apk")
CRLF_META=$(stat -c '%Y:%s:%i' "$LAB_ROOT/crlf/base.apk")
PARENT_MTIME=$(stat -c '%Y' "$LAB_ROOT/parent-fallback")
PARENT_INODE=$(stat -c '%i' "$LAB_ROOT/parent-fallback")
PARENT_META="${PARENT_MTIME}:0:${PARENT_INODE}"

cat >"$STATE_FILE" <<EOF_STATE
com.test.exact|$LAB_ROOT/exact/base.apk|$V_EXACT|$EXACT_META
com.test.changed|$LAB_ROOT/changed/base.apk|$V_CHANGED|1:1:1
com.test.equals|$LAB_ROOT/equals==path/base.apk|$V_EQUALS|$EQUALS_META
com.test.duplicate|$LAB_ROOT/duplicate/base.apk|$V_DUPLICATE|$DUPLICATE_META
com.test.crlf|$LAB_ROOT/crlf/base.apk|$V_CRLF|$CRLF_META
com.test.unavailable|$LAB_ROOT/no-parent/base.apk|$V_UNAVAILABLE|1234567890:123:456
EOF_STATE

cat >"$EXPECTED_STATE_FILE" <<EOF_EXPECTED
com.test.exact|$LAB_ROOT/exact/base.apk|$V_EXACT|$EXACT_META
com.test.changed|$LAB_ROOT/changed/base.apk|$V_CHANGED|$CHANGED_META
com.test.equals|$LAB_ROOT/equals==path/base.apk|$V_EQUALS|$EQUALS_META
com.test.duplicate|$LAB_ROOT/duplicate/base.apk|$V_DUPLICATE|$DUPLICATE_META
com.test.parentfallback|$LAB_ROOT/parent-fallback/base.apk|$V_PARENT|$PARENT_META
com.test.unavailable|$LAB_ROOT/no-parent/base.apk|$V_UNAVAILABLE|1234567890:123:456
com.test.crlf|$LAB_ROOT/crlf/base.apk|$V_CRLF|$CRLF_META
EOF_EXPECTED

# Any untrustworthy result for com.test.changed omits it so the next run retries.
cat >"$EXPECTED_FAILURE_STATE_FILE" <<EOF_EXPECTED_FAILURE
com.test.exact|$LAB_ROOT/exact/base.apk|$V_EXACT|$EXACT_META
com.test.equals|$LAB_ROOT/equals==path/base.apk|$V_EQUALS|$EQUALS_META
com.test.duplicate|$LAB_ROOT/duplicate/base.apk|$V_DUPLICATE|$DUPLICATE_META
com.test.parentfallback|$LAB_ROOT/parent-fallback/base.apk|$V_PARENT|$PARENT_META
com.test.unavailable|$LAB_ROOT/no-parent/base.apk|$V_UNAVAILABLE|1234567890:123:456
com.test.crlf|$LAB_ROOT/crlf/base.apk|$V_CRLF|$CRLF_META
EOF_EXPECTED_FAILURE

cat >"$CLI_SYSTEM_PACKAGE_FILE" <<EOF_CLI_SYSTEM
package:$LAB_ROOT/exact/base.apk=com.test.exact versionCode:$V_EXACT
package:$LAB_ROOT/changed/base.apk=com.test.changed versionCode:$V_CHANGED
EOF_CLI_SYSTEM

cat >"$CLI_USER_PACKAGE_FILE" <<EOF_CLI_USER
package:$LAB_ROOT/equals==path/base.apk=com.test.equals versionCode:$V_EQUALS
package:$LAB_ROOT/crlf/base.apk=com.test.crlf versionCode:$V_CRLF
EOF_CLI_USER

cat >"$CLI_FULL_STATE_FILE" <<EOF_CLI_FULL_STATE
com.test.exact|$LAB_ROOT/exact/base.apk|$V_EXACT|$EXACT_META
com.test.changed|$LAB_ROOT/changed/base.apk|$V_CHANGED|$CHANGED_META
com.test.equals|$LAB_ROOT/equals==path/base.apk|$V_EQUALS|$EQUALS_META
com.test.crlf|$LAB_ROOT/crlf/base.apk|$V_CRLF|$CRLF_META
EOF_CLI_FULL_STATE

cat >"$CLI_USER_STATE_FILE" <<EOF_CLI_USER_STATE
com.test.equals|$LAB_ROOT/equals==path/base.apk|$V_EQUALS|$EQUALS_META
com.test.crlf|$LAB_ROOT/crlf/base.apk|$V_CRLF|$CRLF_META
EOF_CLI_USER_STATE

print -r -- '[+] Created test fixtures:'
print -r -- "    Package input:         $PACKAGE_FILE"
print -r -- "    Malformed PM input:    $MALFORMED_PACKAGE_FILE"
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
print -r -- '    Missing versionCode     -> entire normalization fails closed'
print -r -- '    Equals signs in path    -> final "=" separator parsed correctly'
print -r -- '    Parent fallback         -> parent-directory metadata'
print -r -- '    Unavailable metadata    -> compile + preserve trusted old state'
print -r -- '    CRLF package record     -> normalized correctly'
print -r -- '    ART PERFORMED           -> trustworthy success + state'
print -r -- '    ART SKIPPED             -> trustworthy no-work result + state'
print -r -- '    ART failed/unknown      -> no state; retry next run'
print -r -- '    Storage-low SKIPPED     -> no state; retry next run'
