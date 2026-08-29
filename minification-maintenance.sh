#!/system/bin/sh
set -u # Exit immediately if any variable is unset
umask 077
export LC_ALL=C
DEBUG="${DEBUG:-0}"
for arg in "$@"; do
    case "$arg" in
    -d | --debug | -v | --verbose) DEBUG=1 ;;
    esac
done
debug_print() {
    if [ "$DEBUG" -eq 1 ]; then
        echo "[DEBUG] $1" >&2
    fi
}
debug_print "Debug/Verbose mode initialized."
USER_ID=$(id -u 2>/dev/null || printf '9999')
debug_print "Checked user ID: $USER_ID"
if [ "$USER_ID" -ne 0 ] && [ "$USER_ID" -ne 2000 ]; then
    printf '[!] FATAL: Elevated privileges required (root or adb shell). Aborting.\n' >&2
    exit 1
fi
BOOT_WAIT_ELAPSED=0
while [ $BOOT_WAIT_ELAPSED -lt 300 ]; do
    [ "$(getprop sys.boot_completed)" = "1" ] && break
    sleep 2
    BOOT_WAIT_ELAPSED=$((BOOT_WAIT_ELAPSED + 2))
    debug_print "Waiting for boot completion... elapsed: ${BOOT_WAIT_ELAPSED}s"
done
check_deps() {
    missing=""
    for req in awk cmd cmp cp date df dirname dumpsys getprop mkdir mktemp mv pm printf rm rmdir sed service sleep stat xargs; do
        if ! command -v "$req" >/dev/null 2>&1; then
            missing="${missing}$req "
            debug_print "Missing required dependency: $req"
        fi
    done
    if [ -n "$missing" ]; then
        printf '[!] FATAL: Required commands missing: %s\n' "$missing" >&2
        exit 1
    fi
}
check_deps
if ! service check package >/dev/null 2>&1; then
    printf '[!] FATAL: Package manager service is not running or unresponsive. Aborting.\n' >&2
    exit 1
fi
TOTAL_START_TIME=$(date +%s)
android_version=$(getprop ro.build.version.release 2>/dev/null)
sdk_version=$(getprop ro.build.version.sdk 2>/dev/null)
android_version="${android_version:-Unknown}"
sdk_version="${sdk_version:-0}"
debug_print "Detected Android version: $android_version (SDK: $sdk_version)"
MIN_SDK=24
if [ "$sdk_version" -lt "$MIN_SDK" ]; then
    printf '[!] FATAL: Android 7.0 (API %d) or higher required. Current API: %s\n' "$MIN_SDK" "$sdk_version" >&2
    exit 1
fi
printf '[+] Starting ART Smart Maintenance on Android %s (SDK %s)...\n' "$android_version" "$sdk_version"
export TMPDIR=/data/local/tmp
debug_print "Set TMPDIR to $TMPDIR"
if ! [ -d "$TMPDIR" ] || ! [ -w "$TMPDIR" ]; then
    printf '[!] FATAL: Temporary directory '\''%s'\'' is missing or not writable. Aborting.\n' "$TMPDIR" >&2
    exit 1
fi
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly SCRIPT_DIR
debug_print "Resolved SCRIPT_DIR to $SCRIPT_DIR"
if ! [ -w "$SCRIPT_DIR" ]; then
    printf '[!] FATAL: Script directory '\''%s'\'' is not writable. Aborting.\n' "$SCRIPT_DIR" >&2
    exit 1
fi
STATE_FILE="${SCRIPT_DIR}/.last_optimized"
readonly STATE_FILE
ERROR_LOG="${SCRIPT_DIR}/compile_errors.log"
readonly ERROR_LOG
cleanup() {
    debug_print "Executing cleanup handler (SUCCESSFUL_RUN=$SUCCESSFUL_RUN)..."
    if [ "$SUCCESSFUL_RUN" -eq 0 ] && [ -n "${CURRENT_RUN_STATE:-}" ] && [ -f "$CURRENT_RUN_STATE" ] && [ -s "$CURRENT_RUN_STATE" ]; then
        cp "$CURRENT_RUN_STATE" "${SCRIPT_DIR}/.early_exit" 2>/dev/null || true
    fi
    if [ "$SUCCESSFUL_RUN" -eq 0 ] && [ -n "${ERROR_TMPFILE:-}" ] && [ -f "$ERROR_TMPFILE" ] && [ -s "$ERROR_TMPFILE" ]; then
        mv "$ERROR_TMPFILE" "$ERROR_LOG" 2>/dev/null || true
    fi
    for tmpfile in "${CURRENT_RUN_STATE:-}" "${STAGE_STATS:-}" "${STAGE_MERGED:-}" "${ERROR_TMPFILE:-}"; do
        if [ -n "$tmpfile" ] && [ -e "$tmpfile" ]; then
            debug_print "Cleaning up temporary file: $tmpfile"
            if ! rm -f "$tmpfile" 2>/dev/null; then
                printf '    [!] Warning: Failed to clean up %s\n' "$tmpfile" >&2
            fi
        fi
    done
}
trap 'printf "\n    [!] Interrupted by user (SIGINT). Cleaning up...\n"; exit 130' INT
trap 'printf "\n    [!] Terminated by system (SIGTERM). Cleaning up...\n"; exit 143' TERM
LOCK_DIR="${TMPDIR}/art_maintenance.lock"
debug_print "Acquiring lock directory at $LOCK_DIR"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '[!] FATAL: Another instance is already running (Lock exists). Aborting.\n' >&2
    exit 1
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null; cleanup' EXIT
SUCCESSFUL_RUN=0
SYSTEM_PKGS_COUNT=0
USER_PKGS_COUNT=0
TOTAL_COMPILED=0
CR=$(printf '\r')
readonly CR
get_thermal_status() {
    if command -v dumpsys >/dev/null 2>&1; then
        out=$(dumpsys hardware_properties 2>/dev/null || true)
        if [ -n "$out" ]; then
            debug_print "Parsed thermal status from hardware_properties dumpsys."
            temp=$(printf "%s\n" "$out" | awk '
                /CPU temperatures:/ {
                    if (match($0, /\[[^]]*\]/)) {
                        line = substr($0, RSTART + 1, RLENGTH - 2)
                        n = split(line, temps, ",[ ]*")
                        max_t = 0
                        for (i = 1; i <= n; i++) {
                            if (temps[i] ~ /^[0-9]+$/) {
                                t = temps[i] + 0
                                if (t > max_t && t < 120) max_t = t
                            }
                        }
                        if (max_t > 0) { printf "%d", max_t; exit }
                    }
                }
                /Skin temperatures:/ {
                    if (match($0, /\[[^]]*\]/)) {
                        line = substr($0, RSTART + 1, RLENGTH - 2)
                        if (line ~ /^[0-9]+$/) {
                            t = line + 0
                            if (t > 0 && t < 120) { printf "%d", t; exit }
                        }
                    }
                }
            ')
            [ -n "$temp" ] && {
                printf '%s\n' "$temp"
                return 0
            }
        fi
        bat_temp=$(dumpsys battery 2>/dev/null | awk '/temperature:/ {print int($2 / 10); exit}')
        if [ -n "$bat_temp" ] && [ "$bat_temp" -gt 0 ]; then
            debug_print "Parsed battery thermal reading: ${bat_temp}°C"
            printf '%s\n' "$bat_temp"
            return 0
        fi
    fi
    for f in /sys/class/thermal/thermal_zone*/temp; do
        [ -r "$f" ] || continue
        val=$(<"$f") 2>/dev/null || continue
        [ -z "$val" ] && continue
        case "$val" in *[!0-9]*) continue ;; esac
        debug_print "Read thermal zone from sysfs: $f = $val"
        if [ "$val" -gt 1000 ]; then
            printf '%d\n' $((val / 1000))
        else
            printf '%s\n' "$val"
        fi
        return 0
    done
    debug_print "Thermal sensors unavailable, returning N/A."
    printf 'N/A\n'
}
get_memory_pressure() {
    if [ -r /proc/meminfo ]; then
        debug_print "Reading memory pressure statistics from /proc/meminfo."
        awk '
            /^MemAvailable:/ { a = $2 }
            /^MemTotal:/     { t = $2 }
            END {
                if (t > 0 && a > 0) {
                    printf "%.1f", (t - a) / t * 100
                } else {
                    print "N/A"
                }
            }
        ' /proc/meminfo 2>/dev/null
    else
        debug_print "/proc/meminfo not readable."
        printf 'N/A\n'
    fi
}
get_battery_level() {
    if [ -f /sys/class/power_supply/battery/capacity ]; then
        cap=$(</sys/class/power_supply/battery/capacity) 2>/dev/null
        [ -n "$cap" ] && echo "$cap" || echo "N/A"
    else
        echo "N/A"
    fi
}
print_system_status() {
    label="$1"
    printf '\n    ─────────────────────────────────\n    %s\n    ─────────────────────────────────\n' "$label"
    thermal=$(get_thermal_status)
    if [ "$thermal" = "N/A" ]; then
        printf '[*] Thermal:  %s\n' "$thermal"
    else
        [ "$thermal" -gt 55 ] && {
            printf '[!] Thermal:  %d°C (CRITICAL)\n' "$thermal"
            return 1
        }
        [ "$thermal" -gt 45 ] && printf '[!] Thermal:  %d°C (WARM)\n' "$thermal" || printf '[*] Thermal:  %d°C (OK)\n' "$thermal"
    fi
    memory=$(get_memory_pressure)
    if [ "$memory" = "N/A" ]; then
        printf '[*] Memory:   %s\n' "$memory"
    else
        int_mem="${memory%.*}"
        int_mem="${int_mem:-0}"
        [ "$int_mem" -gt 99 ] && {
            printf '[!] Memory:   %s%% (HIGH)\n' "$memory"
            return 1
        }
        [ "$int_mem" -gt 85 ] && printf '[!] Memory:   %s%% (MODERATE)\n' "$memory" || printf '[*] Memory:   %s%% (OK)\n' "$memory"
    fi
    printf '[*] Battery:  %s%%\n    ─────────────────────────────────\n\n' "$(get_battery_level)"
    return 0
}
process_packages() {
    pkg_list="$1"
    default_mode="$2"
    [ -z "$pkg_list" ] && {
        debug_print "Package list for mode '$default_mode' is empty."
        return 0
    }
    total_pkgs=0
    set -f # Disable glob expansion (wildcards won't expand)
    OLD_IFS="$IFS"
    IFS='
' # Split on newlines only
    for item in $pkg_list; do
        item="${item%"$CR"}"
        [ -n "$item" ] && total_pkgs=$((total_pkgs + 1))
    done
    IFS="$OLD_IFS"
    set +f # Re-enable glob expansion
    debug_print "Total packages parsed for '$default_mode': $total_pkgs"
    debug_print "Running STAGE 1: Extracting file paths and stat metadata..."
    printf '%s\n' "$pkg_list" | awk '{
        line = $0
        idx = 0
        for (i = length(line); i > 0; i--) {
            if (substr(line, i, 1) == "=") {
                idx = i
                break
            }
        }
        if (idx > 0) {
            path = substr(line, 1, idx - 1)
            if (path ~ /[\r\n\0]/ || length(path) > 1024) next
            if (!seen[path]++) print path
            if (match(path, /.*\//)) {
                dir = substr(path, 1, RLENGTH - 1)
                if (dir ~ /[\r\n\0]/ || length(dir) > 1024) next
                if (!seen[dir]++) print dir
            }
        }
    }' | xargs -r stat -c "%n=%Y:%s" 2>/dev/null >"$STAGE_STATS"
    debug_print "Running STAGE 2: Matching packages to stat metadata..."
    printf '%s\n' "$pkg_list" | awk -v sf="$STAGE_STATS" '
        BEGIN {
            while ((getline line < sf) > 0) {
                idx = index(line, "=")
                if (idx > 0) {
                    p = substr(line, 1, idx - 1)       # Path
                    m = substr(line, idx + 1)         # Metadata (inode:size:blocks)
                    stats[p] = m
                }
            }
            close(sf)
        }
        {
            line = $0
            if (line == "") next  # Skip empty lines
            idx = 0
            for (i = length(line); i > 0; i--) {
                if (substr(line, i, 1) == "=") {
                    idx = i
                    break
                }
            }
            if (idx > 0) {
                path = substr(line, 1, idx - 1)       # File path
                pkg = substr(line, idx + 1)           # Package name
                meta = stats[path]
                if (meta == "") {
                    dir = path
                    sub("/[^/]+/?$", "", dir)
                    d_meta = stats[dir]
                    if (d_meta != "") {
                        split(d_meta, arr, ":")
                        meta = arr[1] ":0"  # Use dir timestamp, zero size
                    } else {
                        meta = "0:0"  # Default if nothing found
                    }
                }
                print pkg "|" path "|" meta
            }
        }
    ' >"$STAGE_MERGED"
    debug_print "Running STAGE 3: Processing package compilation sequence..."
    current=0 # Progress counter
    while IFS='|' read -r pkg_name apk_path file_meta; do
        current=$((current + 1))
        [ -z "$pkg_name" ] && continue # Skip empty entries
        case "$pkg_name" in
        *[\ \	]*)
            echo "    [!] Skipping package with whitespace in name: $pkg_name" >&2
            continue
            ;;
        esac
        compile_mode="$default_mode"
        if [ "$default_mode" = "system" ]; then
            if [ "$apk_path" != "${apk_path#/data/}" ]; then
                compile_mode="speed-profile" # Use speed-profile for Play Store updates
            else
                compile_mode="speed" # Use full speed compilation for core system
            fi
        fi
        fingerprint="${pkg_name}:${apk_path}:${file_meta}"
        echo "$fingerprint" >>"$CURRENT_RUN_STATE"
        debug_print "Fingerprint evaluation for [$pkg_name]: $fingerprint"
        case "$PREV_STATE" in
        *"
$fingerprint
"*)
            echo "    [~] ($current/$total_pkgs) Skipping unchanged: $pkg_name"
            continue
            ;;
        esac
        if [ "$compile_mode" = "speed" ]; then
            printf '    [+] (%d/%d) Core system compile (-m speed): %s\n' "$current" "$total_pkgs" "$pkg_name"
            actual_mode="speed"
        elif [ "$default_mode" = "system" ]; then
            printf '    [-] (%d/%d) Play Store update compile (-m speed-profile): %s\n' "$current" "$total_pkgs" "$pkg_name"
            actual_mode="speed-profile"
        else
            printf '    [+] (%d/%d) User app compile (-m speed-profile): %s\n' "$current" "$total_pkgs" "$pkg_name"
            actual_mode="speed-profile"
        fi
        debug_print "Executing command: cmd package compile -m $actual_mode -f $pkg_name"
        err_output=$(cmd package compile -m "$actual_mode" -f "$pkg_name" 2>&1)
        compile_exit=$?
        if [ $compile_exit -eq 0 ]; then
            printf '    [+] (%d/%d) Compiled: %s\n' "$current" "$total_pkgs" "$pkg_name"
            TOTAL_COMPILED=$((TOTAL_COMPILED + 1))
        else
            printf '    [!] (%d/%d) Failed: %s (Exit: %d)\n' "$current" "$total_pkgs" "$pkg_name" "$compile_exit"
            printf 'FAIL (%d): %s\n%s\n' "$compile_exit" "$pkg_name" "$err_output" >>"$ERROR_TMPFILE"
        fi
    done <"$STAGE_MERGED"
    if [ "$default_mode" = "system" ]; then
        SYSTEM_PKGS_COUNT="$total_pkgs"
    else
        USER_PKGS_COUNT="$total_pkgs"
    fi
}
print_system_status "PRE-FLIGHT CHECK" || exit 1
FREE_KB=$(df -k /data 2>/dev/null | awk '/\/data/ {print $(NF-2)}')
debug_print "Available storage on /data: ${FREE_KB:-0} KB"
if [ -n "$FREE_KB" ] && [ "$FREE_KB" -lt 512000 ]; then
    printf '[!] FATAL: Insufficient storage on /data (%d MB available, 500 MB required). Aborting.\n' "$((FREE_KB / 1024))" >&2
    exit 1
fi
CURRENT_RUN_STATE=$(mktemp "${TMPDIR}/opt_state.$$.XXXXXX")
STAGE_STATS=$(mktemp "${TMPDIR}/opt_stats.$$.XXXXXX")
STAGE_MERGED=$(mktemp "${TMPDIR}/opt_merged.$$.XXXXXX")
ERROR_TMPFILE=$(mktemp "${TMPDIR}/errors.$$.XXXXXX")
debug_print "Created temp files: state=$CURRENT_RUN_STATE, stats=$STAGE_STATS, merged=$STAGE_MERGED"
if [ -z "$CURRENT_RUN_STATE" ] || [ -z "$STAGE_STATS" ] || [ -z "$STAGE_MERGED" ] || [ -z "$ERROR_TMPFILE" ]; then
    printf '[!] FATAL: Failed to create temporary state files in %s. Aborting.\n' "$TMPDIR" >&2
    exit 1
fi
PREV_STATE=""
if [ -r "$STATE_FILE" ]; then
    debug_print "Loading persistent state file from $STATE_FILE"
    PREV_STATE="
$(<"$STATE_FILE")
"
else
    debug_print "No existing state file found at $STATE_FILE. Full optimization run expected."
fi
printf '[+] Step 1: Trimming system and app caches...\n'
STEP1_START=$(date +%s)
pm trim-caches 100G >/dev/null 2>&1
STEP1_DURATION=$(($(date +%s) - STEP1_START))
printf '[+] Cache trim finished in %ss.\n' "$STEP1_DURATION"
printf '[+] Step 2: Smart-optimizing system packages...\n'
STEP2_START=$(date +%s)
debug_print "Querying system packages via pm list packages -f -s..."
system_package_list=$(pm list packages -f -s 2>/dev/null | sed -e 's/^package://' -e 's/\r$//')
if [ -z "$system_package_list" ]; then
    printf '    [!] WARNING: System package list is empty or '\''pm'\'' failed. Skipping system stage.\n'
    STEP2_DURATION=0
    SYSTEM_PKGS_COUNT=0
else
    process_packages "$system_package_list" "system"
    STEP2_DURATION=$(($(date +%s) - STEP2_START))
    printf '[+] System package optimization finished in %ss.\n' "$STEP2_DURATION"
fi
printf '[+] Step 3: Smart-optimizing user apps...\n'
STEP3_START=$(date +%s)
debug_print "Querying user packages via pm list packages -f -3..."
user_package_list=$(pm list packages -f -3 2>/dev/null | sed -e 's/^package://' -e 's/\r$//')
if [ -z "$user_package_list" ]; then
    printf '    [!] WARNING: User package list is empty or '\''pm'\'' failed. Skipping user stage.\n'
    STEP3_DURATION=0
    USER_PKGS_COUNT=0
else
    process_packages "$user_package_list" "speed-profile"
    STEP3_DURATION=$(($(date +%s) - STEP3_START))
    printf '[+] User app optimization finished in %ss.\n' "$STEP3_DURATION"
fi
if [ -r "$STATE_FILE" ] && cmp -s "$CURRENT_RUN_STATE" "$STATE_FILE"; then
    printf '[+] State unchanged. Persistent state file left untouched.\n'
else
    if mv "$CURRENT_RUN_STATE" "$STATE_FILE"; then
        printf '[+] Persistent state file updated.\n'
    else
        printf '[!] WARNING: Failed to update persistent state file\n' >&2
    fi
fi
if [ -s "$ERROR_TMPFILE" ]; then
    mv "$ERROR_TMPFILE" "$ERROR_LOG"
else
    rm -f "$ERROR_TMPFILE"
fi
SUCCESSFUL_RUN=1
TOTAL_SCANNED=$((SYSTEM_PKGS_COUNT + USER_PKGS_COUNT))
TOTAL_SKIPPED=$((TOTAL_SCANNED - TOTAL_COMPILED))
TOTAL_DURATION=$(($(date +%s) - TOTAL_START_TIME))
error_notice=""
if [ -s "$ERROR_LOG" ]; then
    error_notice="    - [!] Errors occurred. See $ERROR_LOG"
fi
printf '\n==========================================\n'
printf '[+] Maintenance Summary:\n'
printf '    - Step 1 (Cache Trim):     %ss\n' "$STEP1_DURATION"
printf '    - Step 2 (System Stage):   %ss\n' "$STEP2_DURATION"
printf '    - Step 3 (User Stage):     %ss\n' "$STEP3_DURATION"
printf '    --------------------------------------\n'
printf '    - Grand Total:             %ss\n' "$TOTAL_DURATION"
printf '    - Packages Compiled:       %d\n' "$TOTAL_COMPILED"
printf '    - Packages Skipped (Cached): %d\n' "$TOTAL_SKIPPED"
[ -n "$error_notice" ] && printf '%s\n' "$error_notice"
printf '==========================================\n'
print_system_status "FINAL STATUS"
printf '==========================================\n'
