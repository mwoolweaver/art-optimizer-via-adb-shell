#!/system/bin/sh
# shellcheck shell=ksh

# ============================================================================
# ART PACKAGE PIPELINE TEST FIXTURE GENERATOR
# Purpose: Build deterministic package/state inputs for laboratory.sh.
# ============================================================================

TEST_DIR="${0%/*}"
[ "$TEST_DIR" = "$0" ] && TEST_DIR="."

# Android uses /data/local/tmp by default. CI overrides LAB_ROOT with /tmp.
LAB_ROOT="${LAB_ROOT:-/data/local/tmp/art-pipeline-lab}"

PACKAGE_FILE="${TEST_DIR}/test_packages_list.txt"
STATE_FILE="${TEST_DIR}/test_last_optimized"

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
EOF_PACKAGES

# Add one otherwise-valid record with a literal CR before the newline.
printf 'package:%s/crlf/base.apk=com.test.crlf\r\n' \
    "$LAB_ROOT" >>"$PACKAGE_FILE"

EXACT_META=$(stat -c '%Y:%s:%i' "$LAB_ROOT/exact/base.apk")
EQUALS_META=$(stat -c '%Y:%s:%i' "$LAB_ROOT/equals==path/base.apk")
DUPLICATE_META=$(stat -c '%Y:%s:%i' "$LAB_ROOT/duplicate/base.apk")
CRLF_META=$(stat -c '%Y:%s:%i' "$LAB_ROOT/crlf/base.apk")

cat >"$STATE_FILE" <<EOF_STATE
com.test.exact|$LAB_ROOT/exact/base.apk|$EXACT_META
com.test.changed|$LAB_ROOT/changed/base.apk|1:1:1
com.test.equals|$LAB_ROOT/equals==path/base.apk|$EQUALS_META
com.test.duplicate|$LAB_ROOT/duplicate/base.apk|$DUPLICATE_META
com.test.crlf|$LAB_ROOT/crlf/base.apk|$CRLF_META
com.test.unavailable|$LAB_ROOT/no-parent/base.apk|1234567890:123:456
EOF_STATE

printf '[+] Created test fixtures:\n'
printf '    Package input:  %s\n' "$PACKAGE_FILE"
printf '    State baseline: %s\n' "$STATE_FILE"
printf '    Laboratory root: %s\n' "$LAB_ROOT"

printf '\n[+] Expected special cases:\n'
printf '    Exact duplicate        -> normalized away\n'
printf '    com.test.parentfallback -> parent-directory fallback\n'
printf '    com.test.unavailable    -> UNAVAILABLE metadata\n'
