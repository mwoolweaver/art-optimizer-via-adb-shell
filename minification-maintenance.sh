DEBUG="${DEBUG-0}"
DRY_RUN="${DRY_RUN-0}"
NO_USER="${NO_USER-0}"
QUIET=0
FORCE=0
NO_TRIM=0
REQUIRE_CHARGING=0
MIN_BATTERY=""
JSON=0
HEALTH_ONLY=0
USER_ONLY=0
JSON_OUTPUT_OPEN=0
show_help(){
print -r -- 'ART Smart Maintenance Script

Usage:
    maintenance.sh [OPTIONS]

Options:
    --no-user          Keep user apps offstage and use the system-only state cache.
    --user-only        Give the stage to user apps and use the user-only state cache.
    --dry-run          Rehearse maintenance without compiling packages or rewriting persistent state.
    --quiet            Dismiss per-package chatter; keep warnings, stages, and the final verdict.
    --force            Give selected packages an encore even when their fingerprints are unchanged.
    --no-trim          Excuse only Package Manager cache trimming; ART package work still proceeds.
    --require-charging Require verified external power before maintenance begins.
    --min-battery N    Require a verified battery level of N% (0-100) or higher before maintenance begins.
    --json             Give stdout one JSON result; routine prose disappears; diagnostics stay on stderr.
    --health-only      Inspect health, battery policy, and storage without performing package maintenance.
    --debug            Open the backstage ledger with verbose diagnostics.
    --help             Display this built-in usage guide and exit.

Environment variables:
    DEBUG=0|1
    DRY_RUN=0|1
    NO_USER=0|1
    TMPDIR=/path/to/writable/temp/directory'
}
debug_print(){
if [ "$DEBUG" -eq 1 ];then
echo "[DEBUG] $1" >&2
fi
}
report_error(){
print -r -- "$1" >&2
if [ "${DRY_RUN:-0}" -ne 0 ];then
return 0
fi
if [ -z "${RUN_ERROR_TMPFILE:-}" ];then
RUN_ERROR_TMPFILE=$(mktemp "$TMPDIR/run_errors.$$.XXXXXX" 2>/dev/null)
run_error_tmp_exit=$?
if [ "$run_error_tmp_exit" -ne 0 ]||[ -z "$RUN_ERROR_TMPFILE" ]||[ ! -f "$RUN_ERROR_TMPFILE" ];then
RUN_ERROR_TMPFILE=""
print -r -- '    [!] CRITICAL: Failed to create maintenance error log tempfile.' >&2
return 0
fi
debug_print "Created maintenance error tempfile: $RUN_ERROR_TMPFILE"
fi
if ! print -r -- "$1" >>"$RUN_ERROR_TMPFILE" 2>/dev/null;then
print -r -- '    [!] CRITICAL: Failed to write to maintenance error log tempfile.' >&2
fi
return 0
}
check_deps(){
missing=""
for req in awk cmd cmp cp df dumpsys getprop head mkdir mktemp mv pm rm rmdir service sleep stat tr wc xargs;do
if ! command -v "$req" >/dev/null 2>&1;then
missing="$missing$req "
debug_print "Missing required dependency: $req"
fi
done
if [ -n "$missing" ];then
echo "[!] FATAL: Required commands missing: $missing" >&2
exit 1
fi
}
detect_art_result_reporting(){
case "${ART_RESULT_MODE:-not-determined}" in
not-determined)
;;
*)debug_print "ART result reporting already determined: $ART_RESULT_MODE"
return 0
esac
ART_VERBOSE_RESULTS=0
ART_RESULT_MODE="legacy-exit-code"
ART_HELP_OUTPUT=$(cmd package help 2>&1)
ART_HELP_EXIT=$?
if [ "$ART_HELP_EXIT" -eq 0 ];then
case "$ART_HELP_OUTPUT" in
*"-v Verbose mode. This mode prints detailed results."*)ART_VERBOSE_RESULTS=1
ART_RESULT_MODE="final-status"
debug_print "ART verbose result reporting detected; Final Status will be authoritative."
;;
*)debug_print "ART verbose result reporting not advertised; using legacy compile exit-code semantics."
esac
else
debug_print "Unable to inspect package help (Exit: $ART_HELP_EXIT); using legacy compile exit-code semantics."
fi
ART_HELP_OUTPUT=""
return 0
}
parse_art_compile_result(){
ART_FINAL_STATUS="UNKNOWN"
ART_FINAL_STATUS_RAW=""
ART_FINAL_STATUS_COUNT=0
ART_SKIPPED_STORAGE_LOW=0
ART_RESULT_TEXT="$1"
art_parse_old_ifs="$IFS"
IFS='
'
case "$-" in
*f*)art_parse_noglob_was_set=1;;
*)art_parse_noglob_was_set=0
esac
set -f
for art_result_line in $ART_RESULT_TEXT;do
art_result_line="${art_result_line%$CR}"
case "$art_result_line" in
"Final Status: "*)ART_FINAL_STATUS_COUNT=$((ART_FINAL_STATUS_COUNT+1))
ART_FINAL_STATUS_RAW="${art_result_line#Final Status: }"
case "$ART_FINAL_STATUS_RAW" in
PERFORMED|SKIPPED|FAILED|CANCELLED)ART_FINAL_STATUS="$ART_FINAL_STATUS_RAW"
;;
*)ART_FINAL_STATUS="UNKNOWN"
esac
esac
case "$art_result_line" in
*EXTRA_SKIPPED_STORAGE_LOW*|*EXTENDED_SKIPPED_STORAGE_LOW*)ART_SKIPPED_STORAGE_LOW=1
esac
done
if [ "$art_parse_noglob_was_set" -eq 0 ];then
set +f
fi
IFS="$art_parse_old_ifs"
ART_RESULT_TEXT=""
if [ "$ART_FINAL_STATUS_COUNT" -ne 1 ];then
ART_FINAL_STATUS="UNKNOWN"
return 1
fi
case "$ART_FINAL_STATUS" in
PERFORMED|SKIPPED|FAILED|CANCELLED)return 0
;;
*)return 1
esac
}
cleanup(){
cleanup_exit=$?
trap - EXIT
trap '' INT TERM
debug_print "Executing cleanup handler (SUCCESSFUL_RUN=$SUCCESSFUL_RUN)..."
if [ "${DRY_RUN:-0}" -eq 0 ];then
if [ "$SUCCESSFUL_RUN" -eq 0 ];then
if [ -n "${CURRENT_RUN_STATE:-}" ]&&[ -f "$CURRENT_RUN_STATE" ]&&[ -s "$CURRENT_RUN_STATE" ];then
debug_print "Saving latest failed-run snapshot to: $SCRIPT_DIR/.early_exit"
if ! cp "$CURRENT_RUN_STATE" "$SCRIPT_DIR/.early_exit" 2>/dev/null;then
report_error "    [!] Warning: Failed to save early exit snapshot to $SCRIPT_DIR/.early_exit"
fi
elif [ -f "$SCRIPT_DIR/.early_exit" ];then
debug_print "Removing stale early-exit snapshot: $SCRIPT_DIR/.early_exit"
if ! rm -f "$SCRIPT_DIR/.early_exit" 2>/dev/null;then
report_error "    [!] Warning: Failed to remove stale early exit snapshot $SCRIPT_DIR/.early_exit"
fi
fi
else
if [ -f "$SCRIPT_DIR/.early_exit" ];then
debug_print "Removing stale early-exit snapshot: $SCRIPT_DIR/.early_exit"
if ! rm -f "$SCRIPT_DIR/.early_exit" 2>/dev/null;then
report_error "    [!] Warning: Failed to remove stale early exit snapshot $SCRIPT_DIR/.early_exit"
fi
fi
fi
if [ -n "${ERROR_TMPFILE:-}" ]&&[ -f "$ERROR_TMPFILE" ]&&[ -s "$ERROR_TMPFILE" ];then
debug_print "Saving latest run compile error log to: $ERROR_LOG"
if ! mv "$ERROR_TMPFILE" "$ERROR_LOG" 2>/dev/null;then
report_error "    [!] Warning: Failed to save compile error log to $ERROR_LOG"
fi
elif [ -f "$ERROR_LOG" ];then
debug_print "Removing stale compile error log from previous run: $ERROR_LOG"
if ! rm -f "$ERROR_LOG" 2>/dev/null;then
report_error "    [!] Warning: Failed to remove stale compile error log $ERROR_LOG"
fi
fi
fi
for tmpfile in \
"${CURRENT_RUN_STATE:-}" \
"${STATE_STAGE_TMP:-}" \
"${STAGE_PATHS:-}" \
"${STAGE_STATS:-}" \
"${STAGE_MERGED:-}" \
"${ERROR_TMPFILE:-}";do
if [ -n "$tmpfile" ]&&[ -e "$tmpfile" ];then
debug_print "Cleaning up temporary file: $tmpfile"
if ! rm -f "$tmpfile" 2>/dev/null;then
report_error "    [!] Warning: Failed to clean up $tmpfile"
fi
fi
done
if [ "${DRY_RUN:-0}" -eq 0 ];then
if [ -n "${RUN_ERROR_TMPFILE:-}" ]&&[ -f "$RUN_ERROR_TMPFILE" ]&&[ -s "$RUN_ERROR_TMPFILE" ];then
debug_print "Saving latest maintenance error log to: $RUN_ERROR_LOG"
if ! mv "$RUN_ERROR_TMPFILE" "$RUN_ERROR_LOG" 2>/dev/null;then
print -r -- "    [!] Warning: Failed to save maintenance error log to $RUN_ERROR_LOG" >&2
fi
elif [ -f "$RUN_ERROR_LOG" ];then
debug_print "Removing stale maintenance error log from previous run: $RUN_ERROR_LOG"
if ! rm -f "$RUN_ERROR_LOG" 2>/dev/null;then
print -r -- "    [!] Warning: Failed to remove stale maintenance error log $RUN_ERROR_LOG" >&2
fi
fi
fi
if [ -n "${RUN_ERROR_TMPFILE:-}" ]&&[ -e "$RUN_ERROR_TMPFILE" ];then
debug_print "Cleaning up maintenance error tempfile: $RUN_ERROR_TMPFILE"
if ! rm -f "$RUN_ERROR_TMPFILE" 2>/dev/null;then
print -r -- "    [!] Warning: Failed to clean up $RUN_ERROR_TMPFILE" >&2
fi
fi
if [ -n "${LOCK_DIR:-}" ]&&[ -d "$LOCK_DIR" ];then
debug_print "Releasing concurrency lock at $LOCK_DIR"
if ! rmdir "$LOCK_DIR" 2>/dev/null;then
lock_error="    [!] CRITICAL: Failed to release lock at $LOCK_DIR. Manual deletion required."
print -r -- "$lock_error" >&2
if [ "${DRY_RUN:-0}" -eq 0 ];then
print -r -- "$lock_error" >>"$RUN_ERROR_LOG" 2>/dev/null||true
fi
if [ "$cleanup_exit" -eq 0 ];then
cleanup_exit=1
fi
fi
fi
exit "$cleanup_exit"
}
get_thermal_status(){
therm_status=$(dumpsys thermalservice 2>/dev/null|awk '/^Thermal Status:/ {print $3; exit}')
if [ -n "$therm_status" ]&&[ "$therm_status" -eq "$therm_status" ] 2>/dev/null;then
debug_print "Parsed global thermal status code: $therm_status"
print -r -- "status:$therm_status"
return 0
fi
out=$(dumpsys hardware_properties 2>/dev/null)
if [ -n "$out" ];then
debug_print "Parsed thermal status from hardware_properties dumpsys."
temp=$(print -r -- "$out"|awk '
            /CPU temperatures:/ {
                if (match($0, /\[[^]]*\]/)) {
                    line = substr($0, RSTART + 1, RLENGTH - 2)
                    n = split(line, temps, ",[ ]*")
                    max_t = 0

                    for (i = 1; i <= n; i++) {
                        if (temps[i] ~ /^[0-9]+$/) {
                            t = temps[i] + 0
                            if (t > max_t && t < 120)
                                max_t = t
                        }
                    }

                    if (max_t > 0) {
                        printf "%d", max_t
                        exit
                    }
                }
            }

            /Skin temperatures:/ {
                if (match($0, /\[[^]]*\]/)) {
                    line = substr($0, RSTART + 1, RLENGTH - 2)

                    if (line ~ /^[0-9]+$/) {
                        t = line + 0

                        if (t > 0 && t < 120) {
                            printf "%d", t
                            exit
                        }
                    }
                }
            }
        ')
if [ -n "$temp" ];then
print -r -- "temp:$temp"
return 0
fi
fi
case "$-" in
*f*)battery_noglob_was_set=1;;
*)battery_noglob_was_set=0
esac
set -f
set -- $(dumpsys battery 2>/dev/null)
if [ "$battery_noglob_was_set" -eq 0 ];then
set +f
fi
prev1=""
for i in "$@";do
if [ "$prev1" = "temperature:" ];then
case "$i" in
''|*[!0-9]*)debug_print "Invalid battery temperature value from dumpsys battery: $i"
;;
*)bat_temp=$((i/10))
if [ "$bat_temp" -gt 0 ];then
print -r -- "temp:$bat_temp"
return 0
fi
esac
fi
prev1="$i"
done
for f in /sys/class/thermal/thermal_zone*/temp;do
[ -r "$f" ]||continue
val_out=$(<"$f" 2>&1)
val_exit=$?
if [ "$val_exit" -ne 0 ];then
debug_print "Failed to read thermal zone $f (Exit: $val_exit): $val_out"
continue
fi
[ -z "$val_out" ]&&continue
case "$val_out" in *[!0-9]*)continue;esac
debug_print "Read thermal zone from sysfs: $f = $val_out"
if [ "$val_out" -gt 1000 ];then
print -r -- "temp:$((val_out/1000))"
else
print -r -- "temp:$val_out"
fi
return 0
done
debug_print "Thermal sensors unavailable, returning N/A."
print -r -- 'N/A'
}
get_memory_pressure(){
if [ -r /proc/meminfo ];then
t=""
a=""
while read -r key val _rest;do
case "$key" in
MemTotal:)t="$val";;
MemAvailable:)a="$val"
esac
[ -n "$t" ]&&[ -n "$a" ]&&break
done </proc/meminfo
if [ -n "$t" ]&&[ -n "$a" ]&&[ "$t" -gt 0 ];then
print -r -- "$(((t - a)*100/t))"
else
print -r -- 'N/A'
fi
else
print -r -- 'N/A'
fi
}
get_battery_level(){
batt_path="/sys/class/power_supply/battery/capacity"
if [ -r "$batt_path" ];then
cap_out=$(<"$batt_path" 2>&1)
cap_exit=$?
case "$cap_out" in
''|*[!0-9]*)
;;
*)if
[ "$cap_exit" -eq 0 ]&&[ "$cap_out" -le 100 ]
then
print -r -- "$cap_out"
return 0
fi
esac
debug_print "Failed to read a valid battery capacity (Exit: $cap_exit): $cap_out"
fi
battery_level_dump=$(dumpsys battery 2>/dev/null)
if [ -n "$battery_level_dump" ];then
case "$-" in
*f*)battery_level_noglob_was_set=1;;
*)battery_level_noglob_was_set=0
esac
set -f
set -- $battery_level_dump
if [ "$battery_level_noglob_was_set" -eq 0 ];then
set +f
fi
battery_level_prev=""
for battery_level_token in "$@";do
if [ "$battery_level_prev" = "level:" ];then
case "$battery_level_token" in
''|*[!0-9]*)
;;
*)if
[ "$battery_level_token" -le 100 ]
then
print -r -- "$battery_level_token"
return 0
fi
esac
fi
battery_level_prev="$battery_level_token"
done
fi
print -r -- 'N/A'
}
get_charging_status(){
battery_dump=$(dumpsys battery 2>/dev/null)
if [ -n "$battery_dump" ];then
case "$battery_dump" in
*"AC powered: true"*|*"USB powered: true"*|*"Wireless powered: true"*|*"Dock powered: true"*)print -r -- '1'
return 0
;;
*"AC powered:"*|*"USB powered:"*|*"Wireless powered:"*|*"Dock powered:"*)print -r -- '0'
return 0
esac
fi
charge_status_path="/sys/class/power_supply/battery/status"
if [ -r "$charge_status_path" ];then
charge_status=$(<"$charge_status_path" 2>/dev/null)
case "$charge_status" in
Charging|Full)print -r -- '1'
return 0
;;
Discharging|"Not charging")print -r -- '0'
return 0
esac
fi
print -r -- 'N/A'
}
check_battery_requirements(){
BATTERY_POLICY_ERROR=""
if [ -n "$MIN_BATTERY" ];then
current_battery="${LAST_BATTERY:-N/A}"
case "$current_battery" in
''|*[!0-9]*)current_battery=$(get_battery_level)
esac
case "$current_battery" in
''|*[!0-9]*)BATTERY_POLICY_ERROR="Unable to verify battery level required by --min-battery."
return 1
esac
if [ "$current_battery" -gt 100 ];then
BATTERY_POLICY_ERROR="Invalid battery level reported by device: $current_battery%."
return 1
fi
LAST_BATTERY="$current_battery"
if [ "$current_battery" -lt "$MIN_BATTERY" ];then
BATTERY_POLICY_ERROR="Battery level $current_battery% is below required minimum $MIN_BATTERY%."
return 1
fi
debug_print "Minimum-battery requirement satisfied: $current_battery% >= $MIN_BATTERY%."
fi
if [ "$REQUIRE_CHARGING" -eq 1 ];then
case "${LAST_CHARGING:-N/A}" in
0|1)charging_state="$LAST_CHARGING"
;;
*)charging_state=$(get_charging_status)
esac
LAST_CHARGING="$charging_state"
case "$charging_state" in
1)debug_print "Charging requirement satisfied: external power detected."
;;
0)BATTERY_POLICY_ERROR="External power is required by --require-charging, but the device is not charging."
return 1
;;
*)BATTERY_POLICY_ERROR="Unable to verify charging state required by --require-charging."
return 1
esac
fi
return 0
}
check_data_storage(){
FREE_KB=""
prev1=""
prev2=""
case "$-" in
*f*)df_noglob_was_set=1;;
*)df_noglob_was_set=0
esac
set -f
set -- $(df -k /data 2>/dev/null)
if [ "$df_noglob_was_set" -eq 0 ];then
set +f
fi
for i in "$@";do
case "$i" in
/data*)FREE_KB="$prev2"
break
esac
prev2="${prev1:-}"
prev1="$i"
done
case "$FREE_KB" in
''|*[!0-9]*)FREE_KB=""
STORAGE_STATUS="unknown"
debug_print "Available storage on /data: N/A KB"
return 0
esac
debug_print "Available storage on /data: $FREE_KB KB"
if [ "$FREE_KB" -lt 512000 ];then
STORAGE_STATUS="low"
return 1
fi
STORAGE_STATUS="ok"
return 0
}
emit_json_summary(){
[ "$JSON" -eq 1 ]||return 0
[ "${JSON_OUTPUT_OPEN:-0}" -eq 1 ]||return 0
json_success=true
[ "${1:-1}" -eq 1 ]||json_success=false
if [ "$HEALTH_ONLY" -eq 1 ];then
json_mode="health-only"
json_scope="none"
json_state="not-applicable"
else
json_mode="maintenance"
if [ "$USER_ONLY" -eq 1 ];then
json_scope="user-only"
elif [ "$NO_USER" -eq 1 ];then
json_scope="system-only"
else
json_scope="full"
fi
if [ "$DRY_RUN" -eq 1 ];then
json_state="not-modified"
elif [ "$STATE_COMMIT_SAFE" -eq 1 ];then
json_state="current"
else
json_state="incomplete"
fi
fi
json_dry_run=false
[ "$DRY_RUN" -eq 1 ]&&json_dry_run=true
json_force=false
[ "$FORCE" -eq 1 ]&&json_force=true
json_cache_trim=true
if [ "$HEALTH_ONLY" -eq 1 ];then
json_cache_trim=null
elif [ "$NO_TRIM" -eq 1 ];then
json_cache_trim=false
fi
json_require_charging=false
[ "$REQUIRE_CHARGING" -eq 1 ]&&json_require_charging=true
case "${MIN_BATTERY:-}" in
''|*[!0-9]*)json_min_battery=null;;
*)json_min_battery="$MIN_BATTERY"
esac
case "${LAST_MEMORY:-}" in
''|*[!0-9]*)json_memory=null;;
*)json_memory="$LAST_MEMORY"
esac
case "${LAST_BATTERY:-}" in
''|*[!0-9]*)json_battery=null;;
*)json_battery="$LAST_BATTERY"
esac
case "${FREE_KB:-}" in
''|*[!0-9]*)json_storage=null;;
*)json_storage="$FREE_KB"
esac
case "${LAST_CHARGING:-N/A}" in
1)json_charging=true;;
0)json_charging=false;;
*)json_charging=null
esac
print -r -- \
"{\"success\":$json_success,\"mode\":\"$json_mode\",\"scope\":\"$json_scope\",\"dry_run\":$json_dry_run,\"force\":$json_force,\"cache_trim\":$json_cache_trim,\"require_charging\":$json_require_charging,\"min_battery_percent\":$json_min_battery,\"thermal\":\"${LAST_THERMAL:-N/A}\",\"memory_percent\":$json_memory,\"battery_percent\":$json_battery,\"charging\":$json_charging,\"data_free_kb\":$json_storage,\"compiled\":${TOTAL_COMPILED:-0},\"art_skipped\":${TOTAL_ART_SKIPPED:-0},\"would_compile\":${TOTAL_WOULD_COMPILE:-0},\"skipped\":${TOTAL_SKIPPED:-0},\"cached_skipped\":${TOTAL_SKIPPED:-0},\"failed\":${TOTAL_FAILED:-0},\"invalid\":${TOTAL_INVALID:-0},\"scanned\":${TOTAL_SCANNED:-0},\"art_result_mode\":\"${ART_RESULT_MODE:-not-determined}\",\"duration_seconds\":${TOTAL_DURATION:-0},\"state\":\"$json_state\"}" >&4
return 0
}
print_system_status(){
label="$1"
LAST_THERMAL="N/A"
LAST_MEMORY="N/A"
LAST_BATTERY="N/A"
print -r -- ''
print -r -- '    ─────────────────────────────────'
print -r -- "    $label"
print -r -- '    ─────────────────────────────────'
thermal=$(get_thermal_status)
LAST_THERMAL="$thermal"
case "$thermal" in
N/A)print -r -- "[*] Thermal:  N/A"
;;
status:*)thermal_status="${thermal#status:}"
if [ "$thermal_status" -ge 3 ];then
print -r -- "[!] Thermal:  Status $thermal_status (CRITICAL)"
return 1
elif [ "$thermal_status" -ge 1 ];then
print -r -- "[!] Thermal:  Status $thermal_status (WARM)"
else
print -r -- "[*] Thermal:  Status $thermal_status (OK)"
fi
;;
temp:*)thermal_temp="${thermal#temp:}"
if [ "$thermal_temp" -gt 55 ];then
print -r -- "[!] Thermal:  $thermal_temp°C (CRITICAL)"
return 1
elif [ "$thermal_temp" -gt 45 ];then
print -r -- "[!] Thermal:  $thermal_temp°C (WARM)"
else
print -r -- "[*] Thermal:  $thermal_temp°C (OK)"
fi
;;
*)debug_print "Unexpected thermal result: $thermal"
print -r -- '[*] Thermal:  N/A'
esac
memory=$(get_memory_pressure)
LAST_MEMORY="$memory"
if [ "$memory" = "N/A" ];then
print -r -- "[*] Memory:   $memory"
elif [ "$memory" -gt 99 ];then
print -r -- "[!] Memory:   $memory% (HIGH)"
return 1
elif [ "$memory" -gt 85 ];then
print -r -- "[!] Memory:   $memory% (MODERATE)"
else
print -r -- "[*] Memory:   $memory% (OK)"
fi
battery=$(get_battery_level)
LAST_BATTERY="$battery"
if [ "$battery" = "N/A" ];then
print -r -- '[*] Battery:  N/A'
else
print -r -- "[*] Battery:  $battery%"
fi
print -r -- '    ─────────────────────────────────'
print -r -- ''
return 0
}
process_packages(){
pkg_list="$1"
default_mode="$2"
if [ -z "$pkg_list" ];then
if [ "$default_mode" = "speed-profile" ];then
USER_PKGS_COUNT=0
debug_print "No user/third-party packages found; user stage completed with 0 packages."
return 0
fi
report_error "    [!] ERROR: Package list for mode '$default_mode' is unexpectedly empty."
return 1
fi
debug_print "Normalizing package list to package|path|versionCode format..."
pkg_list="${pkg_list//package:/}"
pkg_list="${pkg_list//$CR/}"
normalized_pkg_list=$(print -r -- "$pkg_list"|awk '
            {
                line = $0
                idx = 0

                # Since Android paths can contain "=" themselves,
                # use the LAST "=" rather than the first one.
                for (i = 1; i <= length(line); i++) {
                    if (substr(line, i, 1) == "=")
                        idx = i
                }

                if (idx <= 0) {
                    invalid_records++
                    next
                }

                path = substr(line, 1, idx - 1)
                rhs  = substr(line, idx + 1)

                # --show-versioncode appends exactly:
                #
                #   " versionCode:<digits>"
                #
                # Parse it from the end so package-name handling stays simple.
                if (!match(rhs, / versionCode:[0-9]+$/)) {
                    invalid_records++
                    next
                }

                pkg = substr(rhs, 1, RSTART - 1)
                version = substr(rhs, RSTART + 13)

                # Admit only a valid internal package record.
                # The versionCode regex above has already guaranteed that
                # version contains one or more decimal digits.
                if (pkg == "" ||
                    path !~ /^\// ||
                    index(path, "|") != 0 ||
                    index(pkg, "|") != 0 ||
                    pkg ~ /[[:space:]]/) {

                    invalid_records++
                    next
                }

                identity = pkg "|" path

                if (identity in seen_version) {
                    if (seen_version[identity] != version)
                        invalid_records++
                    next
                }

                seen_version[identity] = version
                print identity "|" version
            }

            END {
                # A requested versionCode is part of the trusted fingerprint.
                # If any PM record lacks a valid one, fail the entire
                # normalization step rather than silently dropping a package.
                if (invalid_records > 0)
                    exit 2
            }
        ')
normalize_exit=$?
if [ "$normalize_exit" -ne 0 ];then
report_error "    [!] ERROR: Package normalization failed (Exit Code: $normalize_exit)."
return 1
fi
pkg_list="$normalized_pkg_list"
if [ -z "$pkg_list" ];then
report_error "    [!] ERROR: Package list became empty during normalization."
return 1
fi
total_pkgs=0
OLD_IFS="$IFS"
IFS='
'
case "$-" in
*f*)package_noglob_was_set=1;;
*)package_noglob_was_set=0
esac
set -f
for item in $pkg_list;do
[ -n "$item" ]&&total_pkgs=$((total_pkgs+1))
done
if [ "$package_noglob_was_set" -eq 0 ];then
set +f
fi
IFS="$OLD_IFS"
if [ "$DEBUG" -eq 1 ];then
debug_print "===== DEBUG NORMALIZED PACKAGE LIST ====="
debug_print "Total packages parsed for '$default_mode': $total_pkgs"
debug_print "--- first 10 records ---"
echo "$pkg_list"|head -n 10 >&2
debug_print "--- end DEBUG NORMALIZED PACKAGE LIST ---"
fi
if [ "$default_mode" = "system" ];then
SYSTEM_PKGS_COUNT="$total_pkgs"
else
USER_PKGS_COUNT="$total_pkgs"
fi
debug_print "Running STAGE 1: Extracting file paths..."
STAGE_PATHS="$STAGE_STATS.paths"
print -r -- "$pkg_list"|awk -F '|' '
        {
            if (NF != 3)
                next

            path = $2

            # Basic sanity checks
            if (path == "" || length(path) > 1024)
                next

            # Deduplicate APK/file paths
            if (!seen[path]++) {
                print path
            }

            # Extract parent directory
            if (match(path, /.*\//)) {
                dir = substr(path, 1, RLENGTH - 1)

                if (dir != "" &&
                    length(dir) <= 1024 &&
                    !seen[dir]++) {
                    print dir
                }
            }
        }
    ' >"$STAGE_PATHS"
stage1_exit=$?
if [ "$stage1_exit" -ne 0 ];then
report_error "    [!] ERROR: Stage 1 path extraction failed (Exit Code: $stage1_exit)."
return 1
fi
if [ "$DEBUG" -eq 1 ];then
STAGE_PATH_COUNT=$(wc -l <"$STAGE_PATHS")
debug_print "===== DEBUG STAGE 1 PATHS ====="
debug_print "Paths: $STAGE_PATH_COUNT"
debug_print "--- first 20 paths ---"
head -n 20 "$STAGE_PATHS" >&2
debug_print "--- end DEBUG STAGE 1 PATHS ---"
fi
debug_print "Running stat on unique paths..."
tr '\n' '\0' <"$STAGE_PATHS"|xargs -0 -r stat -c '%n=%Y:%s:%i' > \
"$STAGE_STATS"
stage1b_exit=$?
if [ "$stage1b_exit" -ne 0 ];then
debug_print "Stage 1b stat completed with missing/unreadable paths (Exit Code: $stage1b_exit)."
fi
if [ ! -s "$STAGE_STATS" ];then
report_error "    [!] ERROR: stat produced no output. Persistent state will not be updated."
return 1
fi
if [ "$DEBUG" -eq 1 ];then
STAGE_STAT_COUNT=$(wc -l <"$STAGE_STATS")
debug_print "===== DEBUG STAGE 1b: STAT ACCOUNTING ====="
debug_print "Unique paths submitted to stat: $STAGE_PATH_COUNT"
debug_print "Stat records produced:          $STAGE_STAT_COUNT"
if [ "$STAGE_STAT_COUNT" -ne "$STAGE_PATH_COUNT" ];then
debug_print "[!] WARNING: stat record count differs from path count."
debug_print "    Missing/failed stat records: $((STAGE_PATH_COUNT-STAGE_STAT_COUNT))"
else
debug_print "[+] Stat accounting: path count matches stat count."
fi
debug_print "--- end DEBUG STAGE 1b ACCOUNTING ---"
fi
debug_print "Running STAGE 2: Matching packages to stat metadata..."
print -r -- "$pkg_list"|awk -F '|' -v OFS='|' -v sf="$STAGE_STATS" -v debug="$DEBUG" '
        BEGIN {
            # Load stat cache into memory.
            #
            # IMPORTANT:
            # stat output uses "=" between path and metadata.
            #
            # Since Android paths can contain "=" themselves, use the LAST
            # "=" rather than the first one.

            while ((getline line < sf) > 0) {
                stat_records++
                idx = 0

                for (i = 1; i <= length(line); i++) {
                    if (substr(line, i, 1) == "=")
                        idx = i
                }

                if (idx > 0) {
                    p = substr(line, 1, idx - 1)
                    m = substr(line, idx + 1)

                    # Validate expected metadata format:
                    #
                    #   mtime:size:inode
                    #
                    # mtime may theoretically be negative for dates before
                    # the Unix epoch. Size and inode must be non-negative.
                    n = split(m, stat_meta, ":")

                    if (p != "" &&
                        n == 3 &&
                        stat_meta[1] ~ /^-?[0-9]+$/ &&
                        stat_meta[2] ~ /^[0-9]+$/ &&
                        stat_meta[3] ~ /^[0-9]+$/) {

                        if (p in stats)
                            duplicate_stat_paths++

                        stats[p] = m
                        valid_stat_records++
                    } else {
                        invalid_stat_records++
                    }
                } else {
                    invalid_stat_records++
                }
            }

            close(sf)
        }

        {
            input_records++

            if (NF != 3) {
                invalid_package_records++
                next
            }

            pkg     = $1
            path    = $2
            version = $3

            if (pkg == "" ||
                path == "" ||
                version !~ /^[0-9]+$/) {
                invalid_package_records++
                next
            }

            accepted_packages++

            # Look up metadata for the exact APK path.
            meta = stats[path]

            if (meta != "") {
                direct_matches++
            } else {
                # APK metadata unavailable.
                #
                # Prof. JWST fallback: if the APK itself is absent from the catalog, consult
                # its parent directory so split/partial installation changes remain detectable.

                dir = path
                sub("/[^/]+/?$", "", dir)

                d_meta = stats[dir]

                if (d_meta != "") {
                    n = split(d_meta, dir_meta, ":")

                    if (n == 3 &&
                        dir_meta[1] ~ /^-?[0-9]+$/ &&
                        dir_meta[2] ~ /^[0-9]+$/ &&
                        dir_meta[3] ~ /^[0-9]+$/) {

                        # Preserve directory mtime and inode.
                        # Use zero for size because this is directory
                        # fallback metadata.
                        meta = dir_meta[1] ":0:" dir_meta[3]
                        directory_fallbacks++
                    } else {
                        meta = "UNAVAILABLE"
                        unavailable++
                    }
                } else {
                    meta = "UNAVAILABLE"
                    unavailable++
                }
            }

            print pkg, path, version, meta
            merged_records++
        }

        END {
            # Debug diagnostics go to stderr so they never contaminate
            # STAGE_MERGED, which receives stdout.

            if (debug == 1) {
                print "" > "/dev/stderr"
                print "===== DEBUG STAGE 2: MATCH ACCOUNTING =====" > "/dev/stderr"

                printf "Stat records read:          %d\n", stat_records > "/dev/stderr"
                printf "Valid stat records:         %d\n", valid_stat_records > "/dev/stderr"
                printf "Invalid stat records:       %d\n", invalid_stat_records > "/dev/stderr"
                printf "Duplicate stat paths:       %d\n", duplicate_stat_paths > "/dev/stderr"

                printf "Package records received:   %d\n", input_records > "/dev/stderr"
                printf "Package records accepted:   %d\n", accepted_packages > "/dev/stderr"
                printf "Invalid package records:    %d\n", invalid_package_records > "/dev/stderr"

                printf "Direct APK matches:         %d\n", direct_matches > "/dev/stderr"
                printf "Parent directory fallbacks: %d\n", directory_fallbacks > "/dev/stderr"
                printf "Unavailable metadata:       %d\n", unavailable > "/dev/stderr"

                printf "Merged records produced:    %d\n", merged_records > "/dev/stderr"

                print "" > "/dev/stderr"

                # ------------------------------------------------------------
                # Verify stat accounting
                # ------------------------------------------------------------
                if (stat_records == valid_stat_records + invalid_stat_records) {
                    print "[+] Stat accounting verified." > "/dev/stderr"
                } else {
                    printf "[!] WARNING: Stat accounting mismatch: %d != %d + %d\n",
                        stat_records,
                        valid_stat_records,
                        invalid_stat_records > "/dev/stderr"
                }

                # ------------------------------------------------------------
                # Verify package-input accounting
                # ------------------------------------------------------------
                if (input_records == accepted_packages + invalid_package_records) {
                    print "[+] Package-input accounting verified." > "/dev/stderr"
                } else {
                    printf "[!] WARNING: Package-input accounting mismatch: %d != %d + %d\n",
                        input_records,
                        accepted_packages,
                        invalid_package_records > "/dev/stderr"
                }

                # ------------------------------------------------------------
                # Verify metadata-resolution accounting
                # ------------------------------------------------------------
                resolved_packages = direct_matches + directory_fallbacks + unavailable

                if (accepted_packages == resolved_packages) {
                    print "[+] Metadata-resolution accounting verified." > "/dev/stderr"
                } else {
                    printf "[!] WARNING: Metadata-resolution mismatch: %d accepted != %d resolved.\n",
                        accepted_packages,
                        resolved_packages > "/dev/stderr"
                }

                # ------------------------------------------------------------
                # Verify merge accounting
                # ------------------------------------------------------------
                if (accepted_packages == merged_records) {
                    print "[+] Merge accounting verified." > "/dev/stderr"
                } else {
                    printf "[!] WARNING: Merge accounting mismatch: %d accepted != %d merged.\n",
                        accepted_packages,
                        merged_records > "/dev/stderr"
                }

                print "===== END DEBUG STAGE 2 ACCOUNTING =====" > "/dev/stderr"
                print "" > "/dev/stderr"
            }
        }
    ' >"$STAGE_MERGED"
stage2_exit=$?
if [ "$stage2_exit" -ne 0 ];then
report_error "    [!] ERROR: Stage 2 metadata merge failed (Exit Code: $stage2_exit)."
return 1
fi
if [ ! -s "$STAGE_MERGED" ];then
report_error "    [!] ERROR: Stage 2 produced no merged package records."
return 1
fi
if [ "$DEBUG" -eq 1 ];then
MERGED_LINE_COUNT=$(wc -l <"$STAGE_MERGED")
debug_print "===== DEBUG STAGE 2: STAGE_MERGED ====="
debug_print "STAGE_MERGED: $STAGE_MERGED"
debug_print "Merged: $MERGED_LINE_COUNT"
debug_print "--- first 10 records ---"
head -n 10 "$STAGE_MERGED" >&2
debug_print "--- end DEBUG STAGE_MERGED ---"
fi
debug_print "Running STAGE 3: Processing package compilation sequence..."
current=0
stage3_skipped=0
stage3_art_skipped=0
stage3_compiled=0
stage3_failed=0
stage3_unverified=0
stage3_invalid=0
stage3_would_compile=0
stage3_state_error=0
if [ "$DRY_RUN" -eq 0 ];then
if ! exec 3>>"$CURRENT_RUN_STATE";then
report_error "    [!] ERROR: Unable to open current-run state file for writing."
return 1
fi
fi
while IFS='|' read -r pkg_name apk_path version_code file_meta;do
current=$((current+1))
if [ -z "$pkg_name" ]||[ -z "$apk_path" ];then
stage3_invalid=$((stage3_invalid+1))
continue
fi
case "$version_code" in
''|*[!0-9]*)echo "    [!] Skipping package with invalid versionCode: $pkg_name" >&2
stage3_invalid=$((stage3_invalid+1))
continue
esac
case "$pkg_name" in
*[[:space:]]*)echo "    [!] Skipping package with whitespace in name: $pkg_name" >&2
stage3_invalid=$((stage3_invalid+1))
continue
esac
compile_mode="$default_mode"
if [ "$default_mode" = "system" ];then
if [ "$apk_path" != "${apk_path#/data/}" ];then
compile_mode="speed-profile"
else
compile_mode="speed"
fi
fi
state_writable=1
preserved_fingerprint=""
fingerprint="$pkg_name|$apk_path|$version_code|$file_meta"
case "$file_meta" in
UNAVAILABLE)echo "    [!] ($current/$total_pkgs) Unable to verify metadata: $pkg_name" >&2
echo "    [+] ($current/$total_pkgs) Treating as changed: $pkg_name" >&2
stage3_unverified=$((stage3_unverified+1))
state_writable=0
state_key="$pkg_name|$apk_path|$version_code|"
state_old_ifs="$IFS"
IFS='
'
case "$-" in
*f*)state_noglob_was_set=1;;
*)state_noglob_was_set=0
esac
set -f
for prev_fingerprint in $PREV_STATE;do
case "$prev_fingerprint" in
"$state_key"*)case "$prev_fingerprint" in
*"|UNAVAILABLE")
;;
*)preserved_fingerprint="$prev_fingerprint"
debug_print "Found previous trustworthy fingerprint for [$pkg_name]; preserving only after successful compilation."
esac
break
esac
done
if [ "$state_noglob_was_set" -eq 0 ];then
set +f
fi
IFS="$state_old_ifs"
;;
*)debug_print "Fingerprint evaluation for [$pkg_name]: $fingerprint"
if [ "$FORCE" -eq 0 ];then
case "$PREV_STATE" in
*"
$fingerprint
"*)stage3_skipped=$((stage3_skipped+1))
if [ "$DRY_RUN" -eq 0 ];then
if ! print -r -- "$fingerprint" >&3;then
report_error "    [!] ERROR: Failed to write current-run state for $pkg_name."
stage3_state_error=1
break
fi
fi
if [ "$QUIET" -eq 0 ];then
echo "    [~] ($current/$total_pkgs) Skipping unchanged: $pkg_name"
fi
continue
esac
else
debug_print "Force mode bypassing cached fingerprint for [$pkg_name]."
fi
esac
if [ "$DRY_RUN" -eq 1 ];then
if [ "$QUIET" -eq 0 ];then
print -r -- "    [DRY-RUN] ($current/$total_pkgs) Would compile (-m $compile_mode): $pkg_name"
fi
stage3_would_compile=$((stage3_would_compile+1))
else
if [ "$QUIET" -eq 0 ];then
if [ "$compile_mode" = "speed" ];then
print -r -- "    [+] ($current/$total_pkgs) Core system compile (-m speed): $pkg_name"
elif [ "$default_mode" = "system" ];then
print -r -- "    [-] ($current/$total_pkgs) Updated system app compile (-m speed-profile): $pkg_name"
else
print -r -- "    [+] ($current/$total_pkgs) User app compile (-m speed-profile): $pkg_name"
fi
fi
if [ "$ART_RESULT_MODE" = "not-determined" ];then
debug_print "First package requires ART; determining result-reporting capability now."
detect_art_result_reporting
fi
if [ "$ART_VERBOSE_RESULTS" -eq 1 ];then
debug_print "Executing command: cmd package compile -v -m $compile_mode -f $pkg_name"
err_output=$(cmd package compile -v -m "$compile_mode" -f "$pkg_name" 2>&1 3>&-)
else
debug_print "Executing command: cmd package compile -m $compile_mode -f $pkg_name (legacy result mode)"
err_output=$(cmd package compile -m "$compile_mode" -f "$pkg_name" 2>&1 3>&-)
fi
compile_exit=$?
compile_outcome="FAILED"
compile_failure_reason=""
art_parse_exit=0
ART_FINAL_STATUS="N/A"
ART_FINAL_STATUS_RAW=""
ART_FINAL_STATUS_COUNT=0
ART_SKIPPED_STORAGE_LOW=0
if [ "$ART_VERBOSE_RESULTS" -eq 1 ];then
parse_art_compile_result "$err_output"
art_parse_exit=$?
debug_print "ART result for [$pkg_name]: exit=$compile_exit final=$ART_FINAL_STATUS count=$ART_FINAL_STATUS_COUNT storage_low=$ART_SKIPPED_STORAGE_LOW"
fi
if [ "$compile_exit" -ne 0 ];then
compile_failure_reason="command exit $compile_exit"
elif [ "$ART_VERBOSE_RESULTS" -eq 0 ];then
compile_outcome="LEGACY_SUCCESS"
elif [ "$art_parse_exit" -ne 0 ];then
if [ "$ART_FINAL_STATUS_COUNT" -eq 0 ];then
compile_failure_reason="missing ART Final Status"
elif [ "$ART_FINAL_STATUS_COUNT" -gt 1 ];then
compile_failure_reason="multiple ART Final Status records ($ART_FINAL_STATUS_COUNT)"
elif [ -n "$ART_FINAL_STATUS_RAW" ];then
compile_failure_reason="unknown ART Final Status: $ART_FINAL_STATUS_RAW"
else
compile_failure_reason="invalid ART Final Status"
fi
else
case "$ART_FINAL_STATUS" in
PERFORMED)compile_outcome="PERFORMED"
;;
SKIPPED)if
[ "$ART_SKIPPED_STORAGE_LOW" -eq 1 ]
then
compile_failure_reason="ART Final Status: SKIPPED (storage low; retry required)"
else
compile_outcome="SKIPPED"
fi
;;
FAILED|CANCELLED)compile_failure_reason="ART Final Status: $ART_FINAL_STATUS"
;;
*)compile_failure_reason="unexpected ART Final Status: $ART_FINAL_STATUS"
esac
fi
case "$compile_outcome" in
PERFORMED)if
[ "$QUIET" -eq 0 ]
then
print -r -- "    [+] ($current/$total_pkgs) ART performed compilation: $pkg_name"
fi
stage3_compiled=$((stage3_compiled+1))
;;
SKIPPED)if
[ "$QUIET" -eq 0 ]
then
print -r -- "    [~] ($current/$total_pkgs) ART skipped compilation (already satisfied/no work): $pkg_name"
fi
stage3_art_skipped=$((stage3_art_skipped+1))
;;
LEGACY_SUCCESS)if
[ "$QUIET" -eq 0 ]
then
print -r -- "    [+] ($current/$total_pkgs) Compile command succeeded (legacy result mode): $pkg_name"
fi
stage3_compiled=$((stage3_compiled+1))
;;
*)print -r -- "    [!] ($current/$total_pkgs) Failed: $pkg_name ($compile_failure_reason)" >&2
stage3_failed=$((stage3_failed+1))
if [ -z "$ERROR_TMPFILE" ];then
ERROR_TMPFILE=$(mktemp "$TMPDIR/errors.$$.XXXXXX")
error_tmp_exit=$?
if [ "$error_tmp_exit" -ne 0 ]||[ -z "$ERROR_TMPFILE" ]||[ ! -f "$ERROR_TMPFILE" ];then
ERROR_TMPFILE=""
report_error "    [!] CRITICAL: Failed to create compile error tempfile in $TMPDIR."
if [ -n "$err_output" ];then
report_error "        Compile output: $err_output"
fi
else
debug_print "Created compile error tempfile: $ERROR_TMPFILE"
fi
fi
if [ -n "$ERROR_TMPFILE" ];then
if ! print -r -- "FAIL (exit=$compile_exit; result=${ART_FINAL_STATUS:-N/A}; reason=$compile_failure_reason): $pkg_name
$err_output" >>"$ERROR_TMPFILE" 2>/dev/null;then
report_error "    [!] CRITICAL: Failed to write to compile error log! Storage may be full."
fi
fi
esac
if [ "$compile_outcome" != "FAILED" ];then
if [ "$state_writable" -eq 1 ];then
if ! print -r -- "$fingerprint" >&3;then
report_error "    [!] ERROR: Failed to write current-run state for $pkg_name."
stage3_state_error=1
break
fi
elif [ -n "$preserved_fingerprint" ];then
if ! print -r -- "$preserved_fingerprint" >&3;then
report_error "    [!] ERROR: Failed to preserve current-run state for $pkg_name."
stage3_state_error=1
break
fi
debug_print "Preserved previous trustworthy fingerprint for [$pkg_name] after trustworthy ART outcome."
fi
fi
fi
done <"$STAGE_MERGED"
if [ "$DEBUG" -eq 1 ];then
debug_print "===== DEBUG STAGE 3: COMPILATION ====="
debug_print "Stage 3 input records: $current"
debug_print "Skipped unchanged:     $stage3_skipped"
if [ "$DRY_RUN" -eq 1 ];then
debug_print "Would compile:          $stage3_would_compile"
else
debug_print "ART performed/legacy success: $stage3_compiled"
debug_print "ART skipped:                  $stage3_art_skipped"
debug_print "Compilation failures:         $stage3_failed"
fi
debug_print "Metadata unavailable:  $stage3_unverified"
debug_print "Invalid records:        $stage3_invalid"
if [ "$DRY_RUN" -eq 1 ];then
stage3_accounted=$((stage3_skipped+stage3_would_compile+stage3_invalid))
debug_print "Accounting check:      $stage3_skipped + $stage3_would_compile + $stage3_invalid = $stage3_accounted"
if [ "$current" -eq "$stage3_accounted" ];then
debug_print "[+] Stage 3 accounting verified."
else
debug_print "[!] WARNING: Stage 3 accounting mismatch."
fi
else
stage3_accounted=$((stage3_skipped+stage3_art_skipped+stage3_compiled+stage3_failed+stage3_invalid))
debug_print "Accounting check:      $stage3_skipped + $stage3_art_skipped + $stage3_compiled + $stage3_failed + $stage3_invalid = $stage3_accounted"
if [ "$current" -eq "$stage3_accounted" ];then
debug_print "[+] Stage 3 accounting verified."
else
debug_print "[!] WARNING: Stage 3 accounting mismatch."
fi
fi
debug_print "--- end DEBUG STAGE 3 ---"
fi
if [ "$DRY_RUN" -eq 0 ];then
if ! exec 3>&-;then
report_error "    [!] ERROR: Failed to close current-run state file."
stage3_state_error=1
fi
fi
TOTAL_COMPILED=$((TOTAL_COMPILED+stage3_compiled))
TOTAL_ART_SKIPPED=$((TOTAL_ART_SKIPPED+stage3_art_skipped))
TOTAL_WOULD_COMPILE=$((TOTAL_WOULD_COMPILE+stage3_would_compile))
TOTAL_SKIPPED=$((TOTAL_SKIPPED+stage3_skipped))
TOTAL_FAILED=$((TOTAL_FAILED+stage3_failed))
TOTAL_INVALID=$((TOTAL_INVALID+stage3_invalid))
if [ "$stage3_state_error" -ne 0 ];then
return 1
fi
return 0
}
runtime_setup(){
set -u
umask 077
export LC_ALL=C
DEBUG="${DEBUG-0}"
DRY_RUN="${DRY_RUN-0}"
NO_USER="${NO_USER-0}"
QUIET=0
FORCE=0
NO_TRIM=0
REQUIRE_CHARGING=0
MIN_BATTERY=""
JSON=0
HEALTH_ONLY=0
USER_ONLY=0
JSON_OUTPUT_OPEN=0
export TMPDIR="${TMPDIR:-/data/local/tmp}"
debug_print "Using TMPDIR: $TMPDIR"
MIN_SDK=24
SUCCESSFUL_RUN=0
STATE_COMMIT_SAFE=1
SYSTEM_PKGS_COUNT=0
USER_PKGS_COUNT=0
TOTAL_COMPILED=0
TOTAL_ART_SKIPPED=0
TOTAL_SKIPPED=0
TOTAL_FAILED=0
TOTAL_INVALID=0
TOTAL_WOULD_COMPILE=0
TOTAL_SCANNED=0
LAST_THERMAL="N/A"
LAST_MEMORY="N/A"
LAST_BATTERY="N/A"
LAST_CHARGING="N/A"
FREE_KB=""
STORAGE_STATUS="unknown"
BATTERY_POLICY_ERROR=""
ART_VERBOSE_RESULTS=0
ART_RESULT_MODE="not-determined"
ART_FINAL_STATUS="N/A"
ART_FINAL_STATUS_RAW=""
ART_FINAL_STATUS_COUNT=0
ART_SKIPPED_STORAGE_LOW=0
PREV_STATE=""
CURRENT_RUN_STATE=""
STAGE_PATHS=""
STAGE_STATS=""
STAGE_MERGED=""
ERROR_TMPFILE=""
RUN_ERROR_TMPFILE=""
STATE_STAGE_TMP=""
LOCK_DIR=""
CR=$'\r'
readonly CR
}
package_pipeline_setup(){
if ! command -v mktemp >/dev/null 2>&1;then
report_error "[!] FATAL: Required command missing: mktemp"
return 1
fi
if ! [ -d "$TMPDIR" ]||! [ -w "$TMPDIR" ];then
report_error "[!] FATAL: Temporary directory $TMPDIR is missing or not writable."
return 1
fi
if [ "$DRY_RUN" -eq 0 ];then
CURRENT_RUN_STATE=$(mktemp "$TMPDIR/opt_state.$$.XXXXXX")
fi
STAGE_STATS=$(mktemp "$TMPDIR/opt_stats.$$.XXXXXX")
STAGE_MERGED=$(mktemp "$TMPDIR/opt_merged.$$.XXXXXX")
if [ "$DRY_RUN" -eq 0 ];then
debug_print "Created package-pipeline temp files: state=$CURRENT_RUN_STATE, stats=$STAGE_STATS, merged=$STAGE_MERGED"
else
debug_print "Created dry-run package-pipeline temp files: stats=$STAGE_STATS, merged=$STAGE_MERGED"
fi
if [ -z "$STAGE_STATS" ]||[ -z "$STAGE_MERGED" ];then
report_error "[!] FATAL: One or more package-pipeline temporary file paths are empty."
return 1
fi
if [ ! -f "$STAGE_STATS" ]||[ ! -f "$STAGE_MERGED" ];then
report_error "[!] FATAL: Failed to create one or more package-pipeline temporary files in $TMPDIR."
return 1
fi
if [ "$DRY_RUN" -eq 0 ];then
if [ -z "$CURRENT_RUN_STATE" ]||[ ! -f "$CURRENT_RUN_STATE" ];then
report_error "[!] FATAL: Failed to create current-run state tempfile in $TMPDIR."
return 1
fi
fi
return 0
}
main(){
runtime_setup
for setting in DEBUG DRY_RUN NO_USER;do
case "$setting" in
DEBUG)setting_value="$DEBUG";;
DRY_RUN)setting_value="$DRY_RUN";;
NO_USER)setting_value="$NO_USER"
esac
case "$setting_value" in
0|1)
;;
*)print -r -- "[!] FATAL: $setting must be 0 or 1 (received: $setting_value)." >&2
print -r -- '' >&2
show_help >&2
exit 1
esac
done
while [ "$#" -gt 0 ];do
case "$1" in
--debug)DEBUG=1
;;
--dry-run)DRY_RUN=1
;;
--no-user)NO_USER=1
;;
--user-only)USER_ONLY=1
;;
--quiet)QUIET=1
;;
--force)FORCE=1
;;
--no-trim)NO_TRIM=1
;;
--require-charging)REQUIRE_CHARGING=1
;;
--min-battery)if
[ "$#" -lt 2 ]
then
print -r -- '[!] FATAL: --min-battery requires a value from 0 to 100.' >&2
exit 1
fi
MIN_BATTERY="$2"
shift
;;
--min-battery=*)MIN_BATTERY="${1#--min-battery=}"
;;
--json)JSON=1
;;
--health-only)HEALTH_ONLY=1
;;
--help)show_help
exit 0
;;
*)print -r -- "[!] FATAL: Unknown option: $1" >&2
print -r -- '' >&2
show_help >&2
exit 1
esac
shift
done
case "$MIN_BATTERY" in
'')
;;
*[!0-9]*)print -r -- "[!] FATAL: --min-battery must be an integer from 0 to 100 (received: $MIN_BATTERY)." >&2
exit 1
;;
*)if
[ "$MIN_BATTERY" -gt 100 ]
then
print -r -- "[!] FATAL: --min-battery must be between 0 and 100 (received: $MIN_BATTERY)." >&2
exit 1
fi
esac
if [ "$NO_USER" -eq 1 ]&&[ "$USER_ONLY" -eq 1 ];then
print -r -- '[!] FATAL: --no-user and --user-only are mutually exclusive.' >&2
exit 1
fi
if [ "$JSON" -eq 1 ];then
exec 4>&1
if [ "$DEBUG" -eq 1 ];then
exec 1>&2
else
exec 1>/dev/null
fi
JSON_OUTPUT_OPEN=1
fi
debug_print "Debug/Verbose mode initialized."
if [ "$DRY_RUN" -eq 1 ];then
debug_print "Dry-run mode enabled."
fi
if [ "$NO_USER" -eq 1 ];then
debug_print "User app optimization disabled (--no-user)."
fi
if [ "$USER_ONLY" -eq 1 ];then
debug_print "System package optimization disabled (--user-only)."
fi
if [ "$QUIET" -eq 1 ];then
debug_print "Quiet mode enabled; routine per-package progress will be suppressed."
fi
if [ "$FORCE" -eq 1 ];then
debug_print "Force mode enabled; unchanged-package fingerprint skips will be bypassed."
fi
if [ "$NO_TRIM" -eq 1 ];then
debug_print "Cache trimming disabled (--no-trim)."
fi
if [ "$REQUIRE_CHARGING" -eq 1 ];then
debug_print "Charging policy enabled (--require-charging)."
fi
if [ -n "$MIN_BATTERY" ];then
debug_print "Minimum battery policy enabled: $MIN_BATTERY%."
fi
if [ "$JSON" -eq 1 ];then
debug_print "JSON summary mode enabled; routine human-readable stdout suppressed unless --debug is active."
fi
if [ "$HEALTH_ONLY" -eq 1 ];then
debug_print "Health-only mode enabled; package maintenance will be skipped."
fi
SCRIPT_UID=${USER_ID:-1}
debug_print "Checked user ID: $SCRIPT_UID"
if [ "$SCRIPT_UID" -ne 0 ]&&[ "$SCRIPT_UID" -ne 2000 ];then
echo "[!] FATAL: Elevated privileges required (root or adb shell). Aborting." >&2
exit 1
fi
check_deps
BOOT_WAIT_ELAPSED=0
while [ "$(getprop sys.boot_completed)" != "1" ];do
if [ "$BOOT_WAIT_ELAPSED" -ge 300 ];then
echo "[!] FATAL: Device failed to report boot completion after 300 seconds. Aborting." >&2
exit 1
fi
sleep 2
BOOT_WAIT_ELAPSED=$((BOOT_WAIT_ELAPSED+2))
debug_print "Waiting for boot completion... elapsed: ${BOOT_WAIT_ELAPSED}s"
done
TOTAL_START_TIME=$SECONDS
android_version=$(getprop ro.build.version.release 2>/dev/null)
sdk_version=$(getprop ro.build.version.sdk 2>/dev/null)
android_version="${android_version:-Unknown}"
case "$sdk_version" in
''|*[!0-9]*)sdk_version=0
esac
debug_print "Detected Android version: $android_version (SDK: $sdk_version)"
if [ "$sdk_version" -lt "$MIN_SDK" ];then
echo "[!] FATAL: Android 7.0 (API $MIN_SDK) or higher required. Current API: $sdk_version" >&2
exit 1
fi
if [ "$DRY_RUN" -eq 1 ]&&[ "$HEALTH_ONLY" -eq 0 ];then
detect_art_result_reporting
fi
if [ "$HEALTH_ONLY" -eq 1 ];then
echo "[+] Starting ART Smart Maintenance health check on Android $android_version (SDK $sdk_version)..."
elif [ "$DRY_RUN" -eq 1 ];then
echo "[+] Starting ART Smart Maintenance (DRY RUN) on Android $android_version (SDK $sdk_version)..."
else
echo "[+] Starting ART Smart Maintenance on Android $android_version (SDK $sdk_version)..."
fi
if [ "$HEALTH_ONLY" -eq 1 ];then
TOTAL_START_TIME=$SECONDS
if ! print_system_status "HEALTH CHECK";then
print -r -- '[!] FATAL: System health check failed.' >&2
TOTAL_DURATION=$((SECONDS-TOTAL_START_TIME))
emit_json_summary 0
return 1
fi
LAST_CHARGING=$(get_charging_status)
case "$LAST_CHARGING" in
1)print -r -- '[*] Charging: Yes';;
0)print -r -- '[*] Charging: No';;
*)print -r -- '[*] Charging: N/A'
esac
if check_data_storage;then
case "$STORAGE_STATUS" in
ok)print -r -- "[*] /data free: $((FREE_KB/1024)) MB (OK)"
;;
*)print -r -- '[!] /data free: N/A (unable to verify)' >&2
esac
else
print -r -- "[!] /data free: $((FREE_KB/1024)) MB (LOW; 500 MB required)" >&2
TOTAL_DURATION=$((SECONDS-TOTAL_START_TIME))
emit_json_summary 0
return 1
fi
if ! check_battery_requirements;then
print -r -- "[!] FATAL: $BATTERY_POLICY_ERROR" >&2
TOTAL_DURATION=$((SECONDS-TOTAL_START_TIME))
emit_json_summary 0
return 1
fi
TOTAL_DURATION=$((SECONDS-TOTAL_START_TIME))
print -r -- "[+] Health-only checks completed in ${TOTAL_DURATION}s."
emit_json_summary 1
return 0
fi
case "$(service check package 2>/dev/null)" in
*"not found"*|"")echo "[!] FATAL: Package manager service is not running or unresponsive. Aborting." >&2
exit 1
esac
if ! [ -d "$TMPDIR" ]||! [ -w "$TMPDIR" ];then
echo "[!] FATAL: Temporary directory $TMPDIR is missing or not writable. Aborting." >&2
exit 1
fi
case "$0" in
*/*)script_path="$0"
;;
*)if
[ -f "$0" ]
then
script_path="./$0"
else
script_path=$(command -v "$0" 2>/dev/null)
fi
esac
case "$script_path" in
*/*)
;;
*)echo "[!] FATAL: Unable to resolve script path for $0. Aborting." >&2
exit 1
esac
script_dir="${script_path%/*}"
[ -n "$script_dir" ]||script_dir="/"
if ! SCRIPT_DIR=$(cd "$script_dir" 2>/dev/null&&pwd -P);then
echo "[!] FATAL: Unable to resolve script directory for $script_path. Aborting." >&2
exit 1
fi
readonly SCRIPT_DIR
debug_print "Resolved SCRIPT_DIR to $SCRIPT_DIR"
if [ "$DRY_RUN" -eq 0 ]&&[ ! -w "$SCRIPT_DIR" ];then
echo "[!] FATAL: Script directory $SCRIPT_DIR is not writable. Aborting." >&2
exit 1
fi
FULL_STATE_FILE="$SCRIPT_DIR/.last_optimized"
NO_USER_STATE_FILE="$SCRIPT_DIR/.last_optimized_system"
USER_ONLY_STATE_FILE="$SCRIPT_DIR/.last_optimized_user"
readonly FULL_STATE_FILE NO_USER_STATE_FILE USER_ONLY_STATE_FILE
if [ "$NO_USER" -eq 1 ];then
STATE_FILE="$NO_USER_STATE_FILE"
elif [ "$USER_ONLY" -eq 1 ];then
STATE_FILE="$USER_ONLY_STATE_FILE"
else
STATE_FILE="$FULL_STATE_FILE"
fi
readonly STATE_FILE
ERROR_LOG="$SCRIPT_DIR/compile_errors.log"
readonly ERROR_LOG
RUN_ERROR_LOG="$SCRIPT_DIR/maintenance_errors.log"
readonly RUN_ERROR_LOG
trap 'report_error "    [!] Interrupted by user (SIGINT). Cleaning up..."; exit 130' INT
trap 'report_error "    [!] Terminated by system (SIGTERM). Cleaning up..."; exit 143' TERM
LOCK_DIR="$TMPDIR/art_maintenance.lock"
debug_print "Acquiring lock directory at $LOCK_DIR"
if ! mkdir "$LOCK_DIR" 2>/dev/null;then
print -r -- '[!] FATAL: Another instance is already running (Lock exists). Aborting.' >&2
exit 1
fi
trap 'cleanup' EXIT
if ! print_system_status "PRE-FLIGHT CHECK";then
report_error "[!] FATAL: Pre-flight system health check failed. Aborting."
exit 1
fi
if ! check_battery_requirements;then
report_error "[!] FATAL: $BATTERY_POLICY_ERROR"
exit 1
fi
if ! check_data_storage;then
report_error "[!] FATAL: Insufficient storage on /data ($((FREE_KB/1024)) MB available, 500 MB required). Aborting."
exit 1
fi
if [ "$STORAGE_STATUS" = "unknown" ];then
report_error "    [!] WARNING: Could not determine free storage on /data. Proceeding with caution."
fi
if ! package_pipeline_setup;then
exit 1
fi
STATE_READ_FILE="$STATE_FILE"
if [ "$NO_USER" -eq 1 ]&&[ ! -r "$NO_USER_STATE_FILE" ];then
STATE_READ_FILE="$FULL_STATE_FILE"
elif [ "$USER_ONLY" -eq 1 ]&&[ ! -r "$USER_ONLY_STATE_FILE" ];then
STATE_READ_FILE="$FULL_STATE_FILE"
fi
if [ -r "$STATE_READ_FILE" ];then
debug_print "Loading persistent state baseline from $STATE_READ_FILE"
PREV_STATE="
$(<"$STATE_READ_FILE")
"
elif [ "$NO_USER" -eq 1 ];then
debug_print "No system-only or complete state file found. Full system optimization expected."
elif [ "$USER_ONLY" -eq 1 ];then
debug_print "No user-only or complete state file found. Full user-app optimization expected."
else
debug_print "No existing complete state file found. Full optimization run expected."
fi
STEP1_START=$SECONDS
if [ "$NO_TRIM" -eq 1 ];then
print -r -- '[+] Step 1: Cache trimming disabled (--no-trim).'
elif [ "$DRY_RUN" -eq 1 ];then
print -r -- '[+] Step 1: (DRY RUN) Would trim system and app caches...'
else
print -r -- '[+] Step 1: Trimming system and app caches...'
trim_out=$(pm trim-caches 99999999999 2>&1)
trim_exit=$?
if [ $trim_exit -ne 0 ];then
report_error "    [!] WARNING: Cache trim failed (Exit Code: $trim_exit)."
if [ -n "$trim_out" ];then
report_error "        Output: $trim_out"
fi
fi
fi
STEP1_DURATION=$((SECONDS-STEP1_START))
if [ "$NO_TRIM" -eq 0 ];then
print -r -- "[+] Cache trim finished in ${STEP1_DURATION}s."
fi
STEP2_START=$SECONDS
if [ "$USER_ONLY" -eq 1 ];then
SYSTEM_PKGS_COUNT=0
if [ "$DRY_RUN" -eq 1 ];then
print -r -- '[+] Step 2: (DRY RUN) System package optimization disabled (--user-only).'
else
print -r -- '[+] Step 2: System package optimization disabled (--user-only).'
fi
debug_print "Skipping system package query and processing because --user-only is enabled."
else
if [ "$DRY_RUN" -eq 1 ];then
print -r -- '[+] Step 2: (DRY RUN) Smart-optimizing system packages...'
else
print -r -- '[+] Step 2: Smart-optimizing system packages...'
fi
debug_print "Querying system packages via pm list packages -f -s..."
system_package_list=$(pm list packages -f -s --show-versioncode 2>&1)
sys_exit=$?
if [ "$sys_exit" -ne 0 ];then
report_error "    [!] WARNING: Failed to query system packages (Exit Code: $sys_exit)."
if [ -n "$system_package_list" ];then
report_error "        Output: $system_package_list"
fi
SYSTEM_PKGS_COUNT=0
STATE_COMMIT_SAFE=0
elif ! process_packages "$system_package_list" "system";then
STATE_COMMIT_SAFE=0
fi
fi
STEP2_DURATION=$((SECONDS-STEP2_START))
if [ "$USER_ONLY" -eq 1 ];then
print -r -- "[+] System package optimization skipped in ${STEP2_DURATION}s."
else
print -r -- "[+] System package optimization finished in ${STEP2_DURATION}s."
fi
STEP3_START=$SECONDS
if [ "$NO_USER" -eq 1 ];then
USER_PKGS_COUNT=0
if [ "$DRY_RUN" -eq 1 ];then
print -r -- '[+] Step 3: (DRY RUN) User app optimization disabled (--no-user).'
else
print -r -- '[+] Step 3: User app optimization disabled (--no-user).'
fi
debug_print "Skipping user package query and processing because --no-user is enabled."
else
if [ "$DRY_RUN" -eq 1 ];then
print -r -- '[+] Step 3: (DRY RUN) Smart-optimizing user apps...'
else
print -r -- '[+] Step 3: Smart-optimizing user apps...'
fi
debug_print "Querying user packages via pm list packages -f -3..."
user_package_list=$(pm list packages -f -3 --show-versioncode 2>&1)
user_exit=$?
if [ "$user_exit" -ne 0 ];then
report_error "    [!] WARNING: Failed to query user packages (Exit Code: $user_exit)."
if [ -n "$user_package_list" ];then
report_error "        Output: $user_package_list"
fi
USER_PKGS_COUNT=0
STATE_COMMIT_SAFE=0
elif ! process_packages "$user_package_list" "speed-profile";then
STATE_COMMIT_SAFE=0
fi
fi
STEP3_DURATION=$((SECONDS-STEP3_START))
if [ "$NO_USER" -eq 1 ];then
print -r -- "[+] User app optimization skipped in ${STEP3_DURATION}s."
else
print -r -- "[+] User app optimization finished in ${STEP3_DURATION}s."
fi
TOTAL_SCANNED=$((SYSTEM_PKGS_COUNT+USER_PKGS_COUNT))
error_notice=""
if [ "$TOTAL_FAILED" -gt 0 ]&&[ "$DRY_RUN" -eq 0 ];then
if [ -n "$ERROR_TMPFILE" ]&&[ -s "$ERROR_TMPFILE" ];then
error_notice="    - [!] Errors occurred. See $ERROR_LOG"
else
error_notice="    - [!] Compilation errors occurred; compile error log unavailable."
fi
fi
if [ "$DEBUG" -eq 1 ];then
if [ "$DRY_RUN" -eq 1 ];then
debug_total=$((TOTAL_WOULD_COMPILE+TOTAL_SKIPPED+TOTAL_INVALID))
debug_print "Final dry-run accounting:"
debug_print "    Scanned:       $TOTAL_SCANNED"
debug_print "    Would compile: $TOTAL_WOULD_COMPILE"
debug_print "    Skipped:       $TOTAL_SKIPPED"
debug_print "    Invalid:       $TOTAL_INVALID"
debug_print "    Accounted:     $debug_total"
if [ "$TOTAL_SCANNED" -eq "$debug_total" ];then
debug_print "[+] Final dry-run accounting verified."
else
debug_print "[!] WARNING: Final dry-run accounting mismatch."
fi
else
debug_total=$((TOTAL_COMPILED+TOTAL_ART_SKIPPED+TOTAL_SKIPPED+TOTAL_FAILED+TOTAL_INVALID))
debug_print "Final accounting:"
debug_print "    Scanned:        $TOTAL_SCANNED"
debug_print "    Performed:      $TOTAL_COMPILED"
debug_print "    ART skipped:    $TOTAL_ART_SKIPPED"
debug_print "    Cached skipped: $TOTAL_SKIPPED"
debug_print "    Failed:         $TOTAL_FAILED"
debug_print "    Invalid:        $TOTAL_INVALID"
debug_print "    Accounted:      $debug_total"
if [ "$TOTAL_SCANNED" -eq "$debug_total" ];then
debug_print "[+] Final accounting verified."
else
debug_print "[!] WARNING: Final accounting mismatch."
fi
fi
fi
if ! print_system_status "FINAL STATUS";then
report_error "    [!] ERROR: Final system health check failed. Persistent state will not be updated."
print -r -- '=========================================='
exit 1
fi
if [ "$DRY_RUN" -eq 1 ];then
print -r -- '[+] Dry-run mode: Persistent state file and error logs were not modified.'
elif [ "$STATE_COMMIT_SAFE" -ne 1 ];then
report_error "    [!] WARNING: Run was incomplete. Persistent state file was NOT updated."
else
if [ -e "$STATE_FILE" ];then
cmp -s "$CURRENT_RUN_STATE" "$STATE_FILE"
cmp_exit=$?
else
cmp_exit=1
fi
if [ "$cmp_exit" -eq 0 ];then
print -r -- '[+] State unchanged. Persistent state file left untouched.'
elif [ "$cmp_exit" -gt 1 ];then
report_error "    [!] WARNING: Failed to compare current and persistent state (Exit Code: $cmp_exit)."
STATE_COMMIT_SAFE=0
else
STATE_STAGE_TMP=$(mktemp "$STATE_FILE.$$.XXXXXX")
state_stage_exit=$?
if [ "$state_stage_exit" -ne 0 ]||[ -z "$STATE_STAGE_TMP" ]||[ ! -f "$STATE_STAGE_TMP" ];then
report_error "    [!] WARNING: Failed to create same-filesystem state staging file."
STATE_COMMIT_SAFE=0
else
cp_out=$(cp "$CURRENT_RUN_STATE" "$STATE_STAGE_TMP" 2>&1)
cp_exit=$?
if [ "$cp_exit" -ne 0 ];then
report_error "    [!] WARNING: Failed to stage persistent state (Exit Code: $cp_exit)."
if [ -n "$cp_out" ];then
report_error "        Output: $cp_out"
fi
STATE_COMMIT_SAFE=0
else
mv_out=$(mv "$STATE_STAGE_TMP" "$STATE_FILE" 2>&1)
mv_exit=$?
if [ "$mv_exit" -ne 0 ];then
report_error "    [!] WARNING: Failed to atomically update persistent state file (Exit Code: $mv_exit)."
if [ -n "$mv_out" ];then
report_error "        Output: $mv_out"
fi
STATE_COMMIT_SAFE=0
else
STATE_STAGE_TMP=""
if [ "$NO_USER" -eq 1 ];then
print -r -- '[+] System-only persistent state updated atomically.'
elif [ "$USER_ONLY" -eq 1 ];then
print -r -- '[+] User-only persistent state updated atomically.'
else
print -r -- '[+] Complete persistent state updated atomically.'
fi
fi
fi
fi
fi
fi
if [ "$DRY_RUN" -eq 0 ]&&[ "$NO_USER" -eq 0 ]&&[ "$USER_ONLY" -eq 0 ]&&[ "$STATE_COMMIT_SAFE" -eq 1 ];then
for scope_state_file in "$NO_USER_STATE_FILE" "$USER_ONLY_STATE_FILE";do
[ -f "$scope_state_file" ]||continue
debug_print "Removing superseded scope-specific state file: $scope_state_file"
if ! rm -f "$scope_state_file" 2>/dev/null;then
report_error "    [!] WARNING: Failed to remove superseded scope-specific state file $scope_state_file"
fi
done
fi
run_error_notice=""
if [ "$DRY_RUN" -eq 0 ]&&[ -n "${RUN_ERROR_TMPFILE:-}" ]&&[ -s "$RUN_ERROR_TMPFILE" ];then
run_error_notice="    - [!] Maintenance errors occurred. See $RUN_ERROR_LOG"
fi
TOTAL_DURATION=$((SECONDS-TOTAL_START_TIME))
print -r -- ''
print -r -- '=========================================='
if [ "$DRY_RUN" -eq 1 ];then
print -r -- '[+] Maintenance Summary (DRY RUN):'
else
print -r -- '[+] Maintenance Summary:'
fi
print -r -- "    - Step 1 (Cache Trim):       ${STEP1_DURATION}s"
print -r -- "    - Step 2 (System Stage):     ${STEP2_DURATION}s"
print -r -- "    - Step 3 (User Stage):       ${STEP3_DURATION}s"
print -r -- '    --------------------------------------'
print -r -- "    - Grand Total:               ${TOTAL_DURATION}s"
if [ "$DRY_RUN" -eq 1 ];then
print -r -- "    - Packages Would Compile:    $TOTAL_WOULD_COMPILE"
print -r -- "    - Packages Would Skip:       $TOTAL_SKIPPED"
else
case "$ART_RESULT_MODE" in
final-status)print -r -- "    - Packages Performed (ART):  $TOTAL_COMPILED"
print -r -- "    - Packages Skipped (ART):    $TOTAL_ART_SKIPPED"
;;
legacy-exit-code)print -r -- "    - Packages Compile Success:  $TOTAL_COMPILED"
;;
not-determined)print -r -- '    - Packages Reaching ART:     0'
;;
*)print -r -- "    - Packages Compile Success:  $TOTAL_COMPILED"
esac
print -r -- "    - Packages Skipped (Cached): $TOTAL_SKIPPED"
print -r -- "    - Packages Failed:           $TOTAL_FAILED"
fi
if [ "$HEALTH_ONLY" -eq 0 ];then
case "$ART_RESULT_MODE" in
final-status)if
[ "$DRY_RUN" -eq 1 ]
then
print -r -- '    - ART result verification:   Final Status (-v) [would use]'
else
print -r -- '    - ART result verification:   Final Status (-v)'
fi
;;
legacy-exit-code)if
[ "$DRY_RUN" -eq 1 ]
then
print -r -- '    - ART result verification:   Legacy exit-code fallback [would use]'
else
print -r -- '    - ART result verification:   Legacy exit-code fallback'
fi
;;
not-determined)print -r -- '    - ART result verification:   Not determined (ART not invoked)'
;;
*)print -r -- "    - ART result verification:   Unknown mode ($ART_RESULT_MODE)"
esac
fi
print -r -- "    - Packages Invalid:          $TOTAL_INVALID"
print -r -- "    - Total Scanned:             $TOTAL_SCANNED"
if [ "$FORCE" -eq 1 ];then
print -r -- '    - Force mode:                Enabled'
fi
if [ "$NO_TRIM" -eq 1 ];then
print -r -- '    - Cache trim:                Skipped (--no-trim)'
fi
[ -n "$error_notice" ]&&print -r -- "$error_notice"
[ -n "$run_error_notice" ]&&print -r -- "$run_error_notice"
if [ "$DRY_RUN" -eq 0 ]&&[ "$TOTAL_FAILED" -gt 0 ];then
print -r -- '    - [!] Final verdict: package failures remain; failed packages will retry next run.'
fi
if [ "$NO_USER" -eq 1 ];then
print -r -- '    - User app stage:            Skipped (--no-user)'
elif [ "$USER_ONLY" -eq 1 ];then
print -r -- '    - System package stage:      Skipped (--user-only)'
fi
if [ "$REQUIRE_CHARGING" -eq 1 ];then
print -r -- '    - Charging policy:           Required and satisfied'
fi
if [ -n "$MIN_BATTERY" ];then
print -r -- "    - Minimum battery:           $MIN_BATTERY% (satisfied)"
fi
if [ "$STATE_COMMIT_SAFE" -ne 1 ];then
print -r -- '    - [!] Run incomplete: trusted persistent state was not updated.'
elif [ "$DRY_RUN" -eq 0 ];then
if [ "$NO_USER" -eq 1 ];then
print -r -- '    - Persistent state:          System-only state current.'
elif [ "$USER_ONLY" -eq 1 ];then
print -r -- '    - Persistent state:          User-only state current.'
else
print -r -- '    - Persistent state:          Complete state current.'
fi
fi
print -r -- '=========================================='
if [ "$STATE_COMMIT_SAFE" -ne 1 ];then
emit_json_summary 0
exit 1
fi
if [ "$DRY_RUN" -eq 0 ]&&[ "$TOTAL_FAILED" -gt 0 ];then
emit_json_summary 0
exit 1
fi
SUCCESSFUL_RUN=1
emit_json_summary 1
}
if [ "${MAINTENANCE_SOURCE_ONLY-0}" -ne 1 ];then
main "$@"
fi
