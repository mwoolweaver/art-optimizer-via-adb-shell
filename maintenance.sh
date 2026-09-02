#!/system/bin/sh
# shellcheck shell=ksh

# ============================================================================
# ART Smart Maintenance Script
# ============================================================================
# Purpose: Optimize Android ART (Android Runtime) compiled packages through
#          intelligent cache management, profile-guided compilation (speed-profile),
#          and change-detection state caching to minimize redundant I/O wear.
# Target Environment: Android 7.0+ & API 24+, requiring root privileges or
#                     ADB shell execution context.
#
# Key Features:
#   1. Dry-run simulation mode (--dry-run) for safe workflow testing.
#   2. Built in debugging output (--debug) to help diagnose script failure.
#   3. Thermal and memory pressure safety checks to prevent thermal throttling.
#   4. Incremental fingerprint-based tracking (.last_optimized, saved in same dir as script)
#      to skip unchanged application packages and reduce CPU wake locks.
#   5. Atomic temporary file handling and robust signal cleanup traps.
# ============================================================================

set -u # Exit immediately if any variable is unset

# SECURITY: Restrict file creation umask to owner-only (rw-------)
# This prevents accidental world-readable sensitive files
umask 077

# PERFORMANCE: Force C locale (POSIX) instead of system locale
# Avoids locale-specific string sorting/regex issues and speeds up text processing
export LC_ALL=C

# ============================================================================
# DEBUG, DRY_RUN & NO_USER CONFIGURATION
# Purpose: Enable debug logging, dry-run ability, or explicit user-app skipping
#          via validated environment variables or command-line flags.
# ============================================================================

DEBUG="${DEBUG-0}"
DRY_RUN="${DRY_RUN-0}"
NO_USER="${NO_USER-0}"

show_help() {
    printf '%s\n' \
        'ART Smart Maintenance Script' \
        '' \
        'Usage:' \
        '    maintenance.sh [OPTIONS]' \
        '' \
        'Options:' \
        '    --no-user     Skip user/third-party app optimization and use the system-only state cache.' \
        '    --dry-run     Simulate maintenance without compiling packages or modifying persistent state.' \
        '    --debug       Enable verbose debug output.' \
        '    --help        Display this help text and exit.' \
        '' \
        'Environment variables:' \
        '    DEBUG=0|1' \
        '    DRY_RUN=0|1' \
        '    NO_USER=0|1'
}

# Validate environment-variable configuration before any numeric comparisons.
for setting in DEBUG DRY_RUN NO_USER; do
    eval "setting_value=\${$setting}"

    case "$setting_value" in
    0 | 1)
        ;;
    *)
        printf '[!] FATAL: %s must be 0 or 1 (received: %s).\n\n' \
            "$setting" "$setting_value" >&2
        show_help >&2
        exit 1
        ;;
    esac
done

# Parse command-line options.
for arg in "$@"; do
    case "$arg" in
    --debug)
        DEBUG=1
        ;;
    --dry-run)
        DRY_RUN=1
        ;;
    --no-user)
        NO_USER=1
        ;;
    --help)
        show_help
        exit 0
        ;;
    *)
        printf '[!] FATAL: Unknown option: %s\n\n' "$arg" >&2
        show_help >&2
        exit 1
        ;;
    esac
done

# Print an operational/runtime error to stderr and, when available, append it
# to the current real run's maintenance error log tempfile.
report_error() {
    printf '%s\n' "$1" >&2

    if [ "${DRY_RUN:-0}" -eq 0 ] &&
        [ -n "${RUN_ERROR_TMPFILE:-}" ] &&
        [ -f "$RUN_ERROR_TMPFILE" ]; then

        if ! printf '%s\n' "$1" >>"$RUN_ERROR_TMPFILE" 2>/dev/null; then
            printf '    [!] CRITICAL: Failed to write to maintenance error log tempfile.\n' >&2
        fi
    fi
}

debug_print "Debug/Verbose mode initialized."

if [ "$DRY_RUN" -eq 1 ]; then
    debug_print "Dry-run mode enabled."
fi

if [ "$NO_USER" -eq 1 ]; then
    debug_print "User app optimization disabled (--no-user)."
fi

# ============================================================================
# EARLY PRIVILEGE GUARD
# Purpose: Abort immediately if not running as root (UID 0) or Shell (UID 2000)
# ============================================================================
SCRIPT_UID=${USER_ID:-1}
debug_print "Checked user ID: $SCRIPT_UID"
if [ "$SCRIPT_UID" -ne 0 ] && [ "$SCRIPT_UID" -ne 2000 ]; then
    echo "[!] FATAL: Elevated privileges required (root or adb shell). Aborting.\n"
    exit 1
fi

# ============================================================================
# Wait for Android Boot to Complete
# ============================================================================
# The system needs to finish booting before running optimizations
# Sometimes optimizations are triggered by boot scripts before init completes
BOOT_WAIT_ELAPSED=0
while [ $BOOT_WAIT_ELAPSED -lt 300 ]; do
    [ "$(getprop sys.boot_completed)" = "1" ] && break
    sleep 2
    BOOT_WAIT_ELAPSED=$((BOOT_WAIT_ELAPSED + 2))
    debug_print "Waiting for boot completion... elapsed: ${BOOT_WAIT_ELAPSED}s"
done

# Explicitly abort if we timed out without booting
if [ "$(getprop sys.boot_completed)" != "1" ]; then
    echo "[!] FATAL: Device failed to report boot completion after 300 seconds. Aborting.\n"
    exit 1
fi

# ============================================================================
# FUNCTION: check_deps()
# Purpose: Verify all required shell commands are available on the system
# Note: Assumes an Android device shell environment containing host tools
#       like pm, cmd, dumpsys, getprop, and standard POSIX utilities. Collects
#       all missing dependencies before failing so you can fix them at once.
# ============================================================================
check_deps() {
    missing=""
    for req in awk cmd cmp cp df dumpsys getprop head mkdir mktemp mv pm printf rm rmdir service sleep stat tr wc xargs; do
        if ! command -v "$req" >/dev/null 2>&1; then
            missing="${missing}$req "
            debug_print "Missing required dependency: $req"
        fi
    done
    if [ -n "$missing" ]; then
        echo "[!] FATAL: Required commands missing: $missing"
        exit 1
    fi
}
# Verify all required commands are installed as soon as possible
check_deps

# ============================================================================
# PACKAGE SERVICE GUARD
# Purpose: Verify package manager IPC service is registered on the binder bus
# ============================================================================
case "$(service check package 2>/dev/null)" in
*"not found"* | "")
    echo "[!] FATAL: Package manager service is not running or unresponsive. Aborting.\n"
    exit 1
    ;;
esac

# ============================================================================
# INITIALIZATION: Timing and System Detection
# ============================================================================
# Record the shell's elapsed-seconds counter for total duration calculation.
TOTAL_START_TIME=$SECONDS

# Query device properties (fail gracefully if unavailable)
android_version=$(getprop ro.build.version.release 2>/dev/null)
sdk_version=$(getprop ro.build.version.sdk 2>/dev/null)

# Safe fallback assignments
android_version="${android_version:-Unknown}"
sdk_version="${sdk_version:-0}"
debug_print "Detected Android version: $android_version (SDK: $sdk_version)"

# ============================================================================
# API LEVEL GUARD
# Purpose: Require Android 7.0+ (API 24)+ for 'cmd package compile' support
# ============================================================================
MIN_SDK=24

if [ "$sdk_version" -lt "$MIN_SDK" ]; then
    echo "[!] FATAL: Android 7.0 (API $MIN_SDK) or higher required. Current API: $sdk_version\n"
    exit 1
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo "[+] Starting ART Smart Maintenance (DRY RUN) on Android $android_version (SDK $sdk_version)..."
else
    echo "[+] Starting ART Smart Maintenance on Android $android_version (SDK $sdk_version)..."
fi

# ============================================================================
# TEMP FILE & STATE MANAGEMENT VARIABLES
# ============================================================================
# Most Android systems have /data/local/tmp available; ensures temp files go to writable location
export TMPDIR="${TMPDIR:-/data/local/tmp}"
debug_print "Set TMPDIR to $TMPDIR"

# Validate that TMPDIR exists and is actually writable
if ! [ -d "$TMPDIR" ] || ! [ -w "$TMPDIR" ]; then
    echo "[!] FATAL: Temporary directory $TMPDIR is missing or not writable. Aborting."
    exit 1
fi

# Absolute path to this script's directory (locked with readonly to prevent tampering)
case "$0" in
*/*) SCRIPT_DIR="$(cd "${0%/*}" && pwd)" ;;
*) SCRIPT_DIR="$(pwd)" ;;
esac
readonly SCRIPT_DIR
debug_print "Resolved SCRIPT_DIR to $SCRIPT_DIR"

# Validate that SCRIPT_DIR is writable for persistent state files
if ! [ -w "$SCRIPT_DIR" ]; then
    echo "[!] FATAL: Script directory $SCRIPT_DIR is not writable. Aborting.\n"
    exit 1
fi

# Persistent state files used to skip recompiling unchanged packages.
#
# .last_optimized is the authoritative complete state from a normal full run.
# .last_optimized_system is used only by --no-user runs.
FULL_STATE_FILE="${SCRIPT_DIR}/.last_optimized"
NO_USER_STATE_FILE="${SCRIPT_DIR}/.last_optimized_system"
readonly FULL_STATE_FILE NO_USER_STATE_FILE

# Select the state file this run is allowed to update.
if [ "$NO_USER" -eq 1 ]; then
    STATE_FILE="$NO_USER_STATE_FILE"
else
    STATE_FILE="$FULL_STATE_FILE"
fi
readonly STATE_FILE

# Log file for package compilation errors from the most recent real run.
ERROR_LOG="${SCRIPT_DIR}/compile_errors.log"
readonly ERROR_LOG

# Log file for operational/runtime errors from the most recent real run.
RUN_ERROR_LOG="${SCRIPT_DIR}/maintenance_errors.log"
readonly RUN_ERROR_LOG

SUCCESSFUL_RUN=0

# ============================================================================
# SIGNAL HANDLERS & CLEANUP
# ============================================================================
cleanup() {
    debug_print "Executing cleanup handler (SUCCESSFUL_RUN=$SUCCESSFUL_RUN)..."

    # Persistent diagnostic files are only modified by real runs.
    if [ "${DRY_RUN:-0}" -eq 0 ]; then

        if [ "$SUCCESSFUL_RUN" -eq 0 ]; then
            # --- ABORTED OR FAILED REAL RUN ---

            # .early_exit represents the most recent failed/aborted run.
            if [ -n "${CURRENT_RUN_STATE:-}" ] &&
                [ -f "$CURRENT_RUN_STATE" ] &&
                [ -s "$CURRENT_RUN_STATE" ]; then

                debug_print "Saving latest failed-run snapshot to: ${SCRIPT_DIR}/.early_exit"

                if ! cp "$CURRENT_RUN_STATE" "${SCRIPT_DIR}/.early_exit" 2>/dev/null; then
                    report_error "    [!] Warning: Failed to save early exit snapshot to ${SCRIPT_DIR}/.early_exit"
                fi

            elif [ -f "${SCRIPT_DIR}/.early_exit" ]; then
                # Latest failed run produced no usable state snapshot, so an
                # older .early_exit must not masquerade as the latest failure.
                debug_print "Removing stale early-exit snapshot: ${SCRIPT_DIR}/.early_exit"

                if ! rm -f "${SCRIPT_DIR}/.early_exit" 2>/dev/null; then
                    report_error "    [!] Warning: Failed to remove stale early exit snapshot ${SCRIPT_DIR}/.early_exit"
                fi
            fi

        else
            # --- SUCCESSFUL COMPLETED REAL RUN ---

            # A successful run supersedes any previous failed-run snapshot.
            if [ -f "${SCRIPT_DIR}/.early_exit" ]; then
                debug_print "Removing stale early-exit snapshot: ${SCRIPT_DIR}/.early_exit"

                if ! rm -f "${SCRIPT_DIR}/.early_exit" 2>/dev/null; then
                    report_error "    [!] Warning: Failed to remove stale early exit snapshot ${SCRIPT_DIR}/.early_exit"
                fi
            fi
        fi

        # compile_errors.log represents the most recent real run attempt.
        if [ -n "${ERROR_TMPFILE:-}" ] &&
            [ -f "$ERROR_TMPFILE" ] &&
            [ -s "$ERROR_TMPFILE" ]; then

            debug_print "Saving latest run compile error log to: $ERROR_LOG"

            if ! mv "$ERROR_TMPFILE" "$ERROR_LOG" 2>/dev/null; then
                report_error "    [!] Warning: Failed to save compile error log to $ERROR_LOG"
            fi

        elif [ -f "$ERROR_LOG" ]; then
            debug_print "Removing stale compile error log from previous run: $ERROR_LOG"

            if ! rm -f "$ERROR_LOG" 2>/dev/null; then
                report_error "    [!] Warning: Failed to remove stale compile error log $ERROR_LOG"
            fi
        fi
    fi

    # Remove volatile temporary files other than RUN_ERROR_TMPFILE.
    # RUN_ERROR_TMPFILE is finalized last so cleanup failures can be logged too.
    for tmpfile in \
        "${CURRENT_RUN_STATE:-}" \
        "${STATE_STAGE_TMP:-}" \
        "${STAGE_PATHS:-}" \
        "${STAGE_STATS:-}" \
        "${STAGE_MERGED:-}" \
        "${ERROR_TMPFILE:-}"; do
        if [ -n "$tmpfile" ] && [ -e "$tmpfile" ]; then
            debug_print "Cleaning up temporary file: $tmpfile"

            if ! rm -f "$tmpfile" 2>/dev/null; then
                report_error "    [!] Warning: Failed to clean up $tmpfile"
            fi
        fi
    done

    # maintenance_errors.log represents the most recent real run attempt.
    # Finalize it while the concurrency lock is still held so another
    # invocation cannot modify persistent logs during this cleanup.
    if [ "${DRY_RUN:-0}" -eq 0 ]; then
        if [ -n "${RUN_ERROR_TMPFILE:-}" ] &&
            [ -f "$RUN_ERROR_TMPFILE" ] &&
            [ -s "$RUN_ERROR_TMPFILE" ]; then

            debug_print "Saving latest maintenance error log to: $RUN_ERROR_LOG"

            if ! mv "$RUN_ERROR_TMPFILE" "$RUN_ERROR_LOG" 2>/dev/null; then
                printf '    [!] Warning: Failed to save maintenance error log to %s\n' \
                    "$RUN_ERROR_LOG" >&2
            fi

        elif [ -f "$RUN_ERROR_LOG" ]; then
            debug_print "Removing stale maintenance error log from previous run: $RUN_ERROR_LOG"

            if ! rm -f "$RUN_ERROR_LOG" 2>/dev/null; then
                printf '    [!] Warning: Failed to remove stale maintenance error log %s\n' \
                    "$RUN_ERROR_LOG" >&2
            fi
        fi
    fi

    # Remove the maintenance-log tempfile if it was not moved successfully.
    if [ -n "${RUN_ERROR_TMPFILE:-}" ] && [ -e "$RUN_ERROR_TMPFILE" ]; then
        debug_print "Cleaning up maintenance error tempfile: $RUN_ERROR_TMPFILE"

        if ! rm -f "$RUN_ERROR_TMPFILE" 2>/dev/null; then
            printf '    [!] Warning: Failed to clean up %s\n' \
                "$RUN_ERROR_TMPFILE" >&2
        fi
    fi

    # Release the concurrency lock LAST, after all persistent state/log
    # finalization and volatile cleanup are complete.
    if [ -n "${LOCK_DIR:-}" ] && [ -d "$LOCK_DIR" ]; then
        debug_print "Releasing concurrency lock at $LOCK_DIR"

        if ! rmdir "$LOCK_DIR" 2>/dev/null; then
            lock_error="    [!] CRITICAL: Failed to release lock at $LOCK_DIR. Manual deletion required."
            printf '%s\n' "$lock_error" >&2

            # RUN_ERROR_TMPFILE may already have been moved or removed above.
            # Because the lock still exists when rmdir fails, it is safe to
            # append this final cleanup failure directly to the persistent
            # maintenance error log.
            if [ "${DRY_RUN:-0}" -eq 0 ]; then
                printf '%s\n' "$lock_error" >>"$RUN_ERROR_LOG" 2>/dev/null || true
            fi
        fi
    fi
}

# Handle SIGINT (Ctrl+C) and SIGTERM (kill) gracefully with distinct exit codes
# 130 for Ctrl+C and 143 for kill are standard Unix conventions respected by virtually all shell orchestrators.
# Exiting via these traps automatically triggers the EXIT trap (cleanup) beforehand.
trap 'report_error "    [!] Interrupted by user (SIGINT). Cleaning up..."; exit 130' INT
trap 'report_error "    [!] Terminated by system (SIGTERM). Cleaning up..."; exit 143' TERM

# ============================================================================
# CONCURRENCY GUARD
# ============================================================================
LOCK_DIR="${TMPDIR}/art_maintenance.lock"
debug_print "Acquiring lock directory at $LOCK_DIR"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '[!] FATAL: Another instance is already running (Lock exists). Aborting.\n' >&2
    exit 1
fi

# Set the EXIT trap to run the unified cleanup function
trap 'cleanup' EXIT

# Create the operational/runtime error tempfile early so pre-flight and all
# subsequent real-run failures can be captured persistently.
RUN_ERROR_TMPFILE=$(mktemp "${TMPDIR}/run_errors.$$.XXXXXX")

if [ -z "$RUN_ERROR_TMPFILE" ] || [ ! -f "$RUN_ERROR_TMPFILE" ]; then
    printf '[!] FATAL: Failed to create maintenance error tempfile in %s. Aborting.\n' \
        "$TMPDIR" >&2
    exit 1
fi

debug_print "Created maintenance error tempfile: $RUN_ERROR_TMPFILE"

# Package counting variables
SYSTEM_PKGS_COUNT=0
USER_PKGS_COUNT=0
TOTAL_COMPILED=0
TOTAL_SKIPPED=0
TOTAL_FAILED=0
TOTAL_INVALID=0
TOTAL_WOULD_COMPILE=0

STATE_COMMIT_SAFE=1

# Define a literal carriage return safely for POSIX compliance globally
CR=$(printf '\r')
readonly CR

# ============================================================================
# FUNCTION: get_thermal_status()
# Purpose: Retrieve current device temperature from dumpsys or sysfs
# Returns: Temperature in Celsius, or "N/A" if unavailable
# ============================================================================
get_thermal_status() {
    # Attempt 1: dumpsys thermalservice (Modern OS Status Code)
    if command -v dumpsys >/dev/null 2>&1; then
        therm_status=""
        therm_status=$(dumpsys thermalservice 2>/dev/null | awk '/^Thermal Status:/ {print $3; exit}')

        # Verify output is a valid integer
        if [ -n "$therm_status" ] && [ "$therm_status" -eq "$therm_status" ] 2>/dev/null; then
            debug_print "Parsed global thermal status code: $therm_status"
            printf '%s\n' "$therm_status"
            return 0
        fi
    fi

    # Attempt 2: dumpsys hardware_properties (Best for root, often denied for ADB)
    if command -v dumpsys >/dev/null 2>&1; then
        out=$(dumpsys hardware_properties 2>/dev/null || true)
        if [ -n "$out" ]; then
            debug_print "Parsed thermal status from hardware_properties dumpsys."

            # Complex regex to extract temperatures from various dumpsys formats:
            # - Looks for [...] bracket notation containing comma-separated values
            # - Extracts all numeric values between brackets
            # - Filters out unrealistic temps (>120°C) and invalid data
            # - Returns maximum temperature found to detect hottest sensor
            temp=$(printf "%s\n" "$out" | awk '
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

            if [ -n "$temp" ]; then
                printf '%s\n' "$temp"
                return 0
            fi
        fi

        # Attempt 3: dumpsys battery (Accessible to ADB/shell user)
        # Battery temperature is in tenths of a degree (e.g. 350 = 35.0 C)
        case "$-" in
        *f*) battery_noglob_was_set=1 ;;
        *) battery_noglob_was_set=0 ;;
        esac

        set -f
        # shellcheck disable=SC2046
        set -- $(dumpsys battery 2>/dev/null)

        if [ "$battery_noglob_was_set" -eq 0 ]; then
            set +f
        fi

        # dumpsys battery output is key-value pairs: "temperature: 350"
        # When we find the "temperature:" key, the NEXT value is our temperature.
        # Reset parser state so values from earlier calls cannot affect this pass.
        prev1=""

        for i in "$@"; do
            if [ "$prev1" = "temperature:" ]; then
                case "$i" in
                '' | *[!0-9]*)
                    debug_print "Invalid battery temperature value from dumpsys battery: $i"
                    ;;
                *)
                    bat_temp=$((i / 10))

                    if [ "$bat_temp" -gt 0 ]; then
                        printf '%d\n' "$bat_temp"
                        return 0
                    fi
                    ;;
                esac
            fi

            prev1="$i"
        done
    fi

    # Fallback: sysfs (Good for root, fails for ADB due to Android SELinux rules)
    for f in /sys/class/thermal/thermal_zone*/temp; do
        [ -r "$f" ] || continue

        # Group the redirection to safely catch SELinux or read errors
        val_out=$(<"$f" 2>&1)
        val_exit=$?

        if [ "$val_exit" -ne 0 ]; then
            debug_print "Failed to read thermal zone $f (Exit: $val_exit): $val_out"
            continue
        fi

        [ -z "$val_out" ] && continue
        case "$val_out" in *[!0-9]*) continue ;; esac

        debug_print "Read thermal zone from sysfs: $f = $val_out"

        # Some thermal zones report temperature in millidegrees,
        # others in raw degrees. Normalize to Celsius.
        if [ "$val_out" -gt 1000 ]; then
            printf '%d\n' $((val_out / 1000))
        else
            printf '%s\n' "$val_out"
        fi

        return 0
    done

    debug_print "Thermal sensors unavailable, returning N/A."
    printf 'N/A\n'
}

# ============================================================================
# FUNCTION: get_memory_pressure()
# Purpose: Calculate memory pressure from MemTotal and MemAvailable using shell arithmetic
# Returns: Percentage (0-100), or "N/A" if unavailable
# ============================================================================
get_memory_pressure() {
    if [ -r /proc/meminfo ]; then
        t=""
        a=""
        # Read file natively line-by-line without cat or awk
        while read -r key val _rest; do
            case "$key" in
            MemTotal:) t="$val" ;;
            MemAvailable:) a="$val" ;;
            esac
            # Break early once both values are found to save cycles
            [ -n "$t" ] && [ -n "$a" ] && break
        done </proc/meminfo

        # Perform pure integer math in the shell: ((Total - Available) * 100 / Total)
        if [ -n "$t" ] && [ -n "$a" ] && [ "$t" -gt 0 ]; then
            printf '%d\n' "$(((t - a) * 100 / t))"
        else
            printf 'N/A\n'
        fi
    else
        printf 'N/A\n'
    fi
}

# ============================================================================
# FUNCTION: get_battery_level()
# Purpose: Read current battery percentage from sysfs
# Returns: Battery percentage, or "N/A" if unavailable
# ============================================================================
get_battery_level() {
    # Most Android devices expose battery capacity at physical sysfs path
    batt_path="/sys/class/power_supply/battery/capacity"
    if [ -f "$batt_path" ]; then
        # Group the read operation to capture stderr via subshell redirection
        cap_out=$(<"$batt_path" 2>&1)
        cap_exit=$?

        if [ $cap_exit -eq 0 ] && [ -n "$cap_out" ]; then
            printf '%s\n' "$cap_out"
        else
            debug_print "Failed to read battery capacity (Exit: $cap_exit): $cap_out"
            echo "N/A"
        fi
    else
        echo "N/A"
    fi
}

# ============================================================================
# FUNCTION: print_system_status()
# Purpose: Display formatted system health metrics
# Params: $1 = Label to display at top
# Returns: 0 if system is healthy, 1 if critical conditions detected
# ============================================================================
print_system_status() {
    label="$1"
    printf '\n    ─────────────────────────────────\n    %s\n    ─────────────────────────────────\n' "$label"

    # Get and display thermal status
    thermal=$(get_thermal_status)
    if [ "$thermal" = "N/A" ]; then
        printf '[*] Thermal:  %s\n' "$thermal"
    elif [ "$thermal" -le 6 ]; then
        # Android OS Thermal Status Code (0-6)
        # Critical: >= 3 (SEVERE, CRITICAL, EMERGENCY, SHUTDOWN)
        [ "$thermal" -ge 3 ] && {
            printf '[!] Thermal:  Status %d (CRITICAL)\n' "$thermal"
            return 1
        }
        # Warm: >= 1 (LIGHT, MODERATE)
        [ "$thermal" -ge 1 ] && printf '[!] Thermal:  Status %d (WARM)\n' "$thermal" || printf '[*] Thermal:  Status %d (OK)\n' "$thermal"
    else
        # Fallback Celsius Temperature (> 6)
        # Critical: > 55°C (likely throttling/damage risk)
        [ "$thermal" -gt 55 ] && {
            printf '[!] Thermal:  %d°C (CRITICAL)\n' "$thermal"
            return 1
        }
        # Warm: > 45°C (approaching throttle point)
        [ "$thermal" -gt 45 ] && printf '[!] Thermal:  %d°C (WARM)\n' "$thermal" || printf '[*] Thermal:  %d°C (OK)\n' "$thermal"
    fi

    # Get and display memory pressure
    memory=$(get_memory_pressure)
    if [ "$memory" = "N/A" ]; then
        printf '[*] Memory:   %s\n' "$memory"
    else
        # Critical: > 99% (virtually no free memory)
        [ "$memory" -gt 99 ] && {
            printf '[!] Memory:   %s%% (HIGH)\n' "$memory"
            return 1
        }
        # Moderate: > 85% (significant pressure, may cause slowdowns)
        [ "$memory" -gt 85 ] && printf '[!] Memory:   %s%% (MODERATE)\n' "$memory" || printf '[*] Memory:   %s%% (OK)\n' "$memory"
    fi

    # Display battery level (informational only)
    printf '[*] Battery:  %s%%\n    ─────────────────────────────────\n\n' "$(get_battery_level)"
    return 0
}
# ============================================================================
# FUNCTION: process_packages()
# Purpose: Compile a list of packages with intelligent change detection
# Params:
#   $1 = Package list (format: "package:/path/to/apk.apk=package.name\n...")
#   $2 = Default compile mode (system, speed-profile)
# ============================================================================
process_packages() {
    pkg_list="$1"
    default_mode="$2"

    # A successful package-manager query should not produce an empty list.
    # Treat an unexpected empty enumeration as unsafe so persistent state
    # cannot be replaced by an incomplete run.
    if [ -z "$pkg_list" ]; then
        report_error "    [!] ERROR: Package list for mode '$default_mode' is unexpectedly empty."
        return 1
    fi

    # ========================================================================
    # NORMALIZE PM OUTPUT
    # ========================================================================
    # process_packages() receives the output of pm list packages -f (-s||-3)
    #
    # Input:
    #   package:/path/to/base.apk=com.example.app
    #
    # Convert once to our internal format:
    #   com.example.app|/path/to/base.apk
    #
    # IMPORTANT:
    # We must split on the LAST "=" because Android /data/app paths can
    # themselves contain "=" characters, e.g.:
    #
    #   /data/app/~~NFUaidAwYhRskD6PhHgvHA==/...
    #
    # From this point forward, "|" is the package|path delimiter.
    # ========================================================================

    debug_print "Normalizing package list to package|path format..."

    # Strip "package:" prefix and carriage returns purely in RAM (Zero-Fork)
    pkg_list="${pkg_list//package:/}"
    pkg_list="${pkg_list//$CR/}"

    normalized_pkg_list=$(
        printf '%s\n' "$pkg_list" |
            awk '
            {
                line = $0
                idx = 0

                # Since Android paths can contain "=" themselves,
                # use the LAST "=" rather than the first one.
                for (i = 1; i <= length(line); i++) {
                    if (substr(line, i, 1) == "=")
                        idx = i
                }

                if (idx > 0) {
                    path = substr(line, 1, idx - 1)
                    pkg  = substr(line, idx + 1)

                    if (path != "" && pkg != "")
                        print pkg "|" path
                }
            }
        '
    )

    normalize_exit=$?

    if [ "$normalize_exit" -ne 0 ]; then
        report_error "    [!] ERROR: Package normalization failed (Exit Code: $normalize_exit)."
        return 1
    fi

    pkg_list="$normalized_pkg_list"

    # A non-empty package-manager result becoming empty means normalization failed.
    if [ -z "$pkg_list" ]; then
        report_error "    [!] ERROR: Package list became empty during normalization."
        return 1
    fi

    # ========================================================================
    # DEBUG NORMALIZED INPUT
    # ========================================================================
    if [ "$DEBUG" -eq 1 ]; then
        debug_print '\n===== DEBUG NORMALIZED PACKAGE LIST =====\n'
        debug_print 'Packages: '
        echo "$pkg_list" | wc -l
        debug_print '--- first 10 records ---\n'
        echo "$pkg_list" | head -n 10
        debug_print '--- end DEBUG NORMALIZED PACKAGE LIST ---'
    fi

    # ========================================================================
    # COUNT TOTAL PACKAGES
    # ========================================================================
    total_pkgs=0

    OLD_IFS="$IFS"
    IFS='
'

    case "$-" in
    *f*) package_noglob_was_set=1 ;;
    *) package_noglob_was_set=0 ;;
    esac

    set -f
    for item in $pkg_list; do
        [ -n "$item" ] && total_pkgs=$((total_pkgs + 1))
    done

    if [ "$package_noglob_was_set" -eq 0 ]; then
        set +f
    fi

    IFS="$OLD_IFS"

    debug_print "Total packages parsed for '$default_mode': $total_pkgs"

    # Expose the successfully parsed package count before later processing.
    # This preserves the input count even if a later stage fails.
    if [ "$default_mode" = "system" ]; then
        SYSTEM_PKGS_COUNT="$total_pkgs"
    else
        USER_PKGS_COUNT="$total_pkgs"
    fi

    # ========================================================================
    # STAGE 1: Extract file paths
    # ========================================================================
    debug_print "Running STAGE 1: Extracting file paths..."

    STAGE_PATHS="${STAGE_STATS}.paths"

    # Input:
    #
    #   package|/path/to/base.apk
    #
    # Output:
    #
    #   /path/to/base.apk
    #   /path/to/parent/directory
    #
    # Only filesystem paths are allowed through to stat.
    # ========================================================================

    printf '%s\n' "$pkg_list" |
        awk -F '|' '
        {
            if (NF < 2)
                next

            pkg  = $1
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

    if [ "$stage1_exit" -ne 0 ]; then
        report_error "    [!] ERROR: Stage 1 path extraction failed (Exit Code: $stage1_exit)."
        return 1
    fi

    # A successfully normalized non-empty package list should always
    # produce at least one valid filesystem path.
    if [ ! -s "$STAGE_PATHS" ]; then
        report_error "    [!] ERROR: Stage 1 produced no valid package paths."
        return 1
    fi

    # ========================================================================
    # DEBUG STAGE 1: PATHS
    # ========================================================================
    if [ "$DEBUG" -eq 1 ]; then
        debug_print '\n===== DEBUG STAGE 1 PATHS =====\n'
        debug_print 'Paths: '
        wc -l <"$STAGE_PATHS"
        debug_print '--- first 20 paths ---'
        head -n 20 "$STAGE_PATHS"
        debug_print '--- end DEBUG STAGE 1 PATHS ---'
    fi

    # ========================================================================
    # STAGE 1b: STATS
    # ========================================================================
    #
    # STAGE_PATHS contains ONLY paths.
    #
    # We deliberately leave stderr visible while debugging so stat failures
    # are not hidden.
    # ========================================================================

    debug_print "Running stat on unique paths..."

    tr '\n' '\0' <"$STAGE_PATHS" |
        xargs -0 -r stat -c '%n=%Y:%s:%i' \
            >"$STAGE_STATS"

    stage1b_exit=$?

    if [ "$stage1b_exit" -ne 0 ]; then
        report_error "    [!] ERROR: Stage 1b stat collection failed (Exit Code: $stage1b_exit)."
        return 1
    fi

    # Validate stat produced output
    if [ ! -s "$STAGE_STATS" ]; then
        report_error "    [!] ERROR: stat produced no output. Persistent state will not be updated."
        return 1
    fi

    if [ "$DEBUG" -eq 1 ]; then
        STAGE_PATH_COUNT=$(wc -l <"$STAGE_PATHS")
        STAGE_STAT_COUNT=$(wc -l <"$STAGE_STATS")
        debug_print "\n===== DEBUG STAGE 1b: STAT ACCOUNTING =====\n"
        debug_print "Unique paths submitted to stat: $STAGE_PATH_COUNT"
        debug_print "Stat records produced:          $STAGE_STAT_COUNT"

        if [ "$STAGE_STAT_COUNT" -ne "$STAGE_PATH_COUNT" ]; then
            debug_print "[!] WARNING: stat record count differs from path count.\n"
            debug_print "    Missing/failed stat records: $((STAGE_PATH_COUNT - STAGE_STAT_COUNT))"
        else
            debug_print "[+] Stat accounting: path count matches stat count.\n"
        fi

        debug_print "--- end DEBUG STAGE 1b ACCOUNTING ---"
    fi

    # ========================================================================
    # STAGE 2: Match packages to stat metadata (STAGE_MERGED)
    # ========================================================================
    debug_print "Running STAGE 2: Matching packages to stat metadata..."

    # Input:
    #
    #   package|path
    #
    # Stat cache:
    #
    #   path=mtime:size:inode
    #
    # Output:
    #
    #   package|path|mtime:size:inode
    # ========================================================================

    printf '%s\n' "$pkg_list" |
        awk -F '|' -v OFS='|' -v sf="$STAGE_STATS" -v debug="$DEBUG" '
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

            if (NF < 2) {
                invalid_package_records++
                next
            }

            pkg  = $1
            path = $2

            if (pkg == "" || path == "") {
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
                # Fall back to parent directory metadata so that changes to
                # split/partial APK installations can still be detected.

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

            print pkg, path, meta
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

    if [ "$stage2_exit" -ne 0 ]; then
        report_error "    [!] ERROR: Stage 2 metadata merge failed (Exit Code: $stage2_exit)."
        return 1
    fi

    # A successful merge of a non-empty normalized package list should not
    # result in an empty Stage 2 output.
    if [ ! -s "$STAGE_MERGED" ]; then
        report_error "    [!] ERROR: Stage 2 produced no merged package records."
        return 1
    fi

    # ========================================================================
    # DEBUG STAGE 2: STAGE_MERGED
    # ========================================================================
    if [ "$DEBUG" -eq 1 ]; then
        debug_print "\n===== DEBUG STAGE 2: STAGE_MERGED =====\n"
        debug_print "STAGE_MERGED: $STAGE_MERGED\n"
        debug_print "Merged: "
        wc -l <"$STAGE_MERGED"
        debug_print "--- first 10 records ---"
        head -n 10 "$STAGE_MERGED"
        debug_print "--- end DEBUG STAGE_MERGED ---"
    fi

    # ========================================================================
    # STAGE 3: Process each package
    # ========================================================================
    debug_print "Running STAGE 3: Processing package compilation sequence..."

    current=0
    stage3_skipped=0
    stage3_compiled=0
    stage3_failed=0
    stage3_unverified=0
    stage3_invalid=0
    stage3_would_compile=0

    if ! exec 3>>"$CURRENT_RUN_STATE"; then
        report_error "    [!] ERROR: Unable to open current-run state file for writing."
        return 1
    fi

    # STAGE_MERGED format:
    #
    #   package|path|metadata
    #
    while IFS='|' read -r pkg_name apk_path file_meta; do

        current=$((current + 1))

        if [ -z "$pkg_name" ]; then
            stage3_invalid=$((stage3_invalid + 1))
            continue
        fi

        # Sanity check: package names should contain no whitespace.
        case "$pkg_name" in
        *[[:space:]]*)
            echo "    [!] Skipping package with whitespace in name: $pkg_name" >&2
            stage3_invalid=$((stage3_invalid + 1))
            continue
            ;;
        esac

        # ====================================================================
        # Determine compilation mode
        # ====================================================================

        compile_mode="$default_mode"

        if [ "$default_mode" = "system" ]; then
            # Distinguish between core system packages (/system/*) and third-party updates (/data/app/*)
            # Core system packages use full AOT compilation (-m speed) for maximum performance.
            # Third-party updates use speed-profile compilation to balance speed and storage.

            # System packages installed under /data/ are third-party updates.
            if [ "$apk_path" != "${apk_path#/data/}" ]; then
                compile_mode="speed-profile"
            else
                compile_mode="speed"
            fi
        fi

        # ====================================================================
        # Build fingerprint
        # ====================================================================

        # Fingerprint format: package|path|metadata
        # Uses '|' as delimiter (consistent with normalized package|path format above).
        # This unique combination identifies if a package has changed since last optimization.
        # Unchanged fingerprints skip recompilation; changed ones trigger fresh compilation.

        state_writable=1
        preserved_fingerprint=""
        fingerprint="${pkg_name}|${apk_path}|${file_meta}"

        case "${file_meta}" in

        *UNAVAILABLE*)

            echo "    [!] ($current/$total_pkgs) Unable to verify metadata: $pkg_name"
            echo "    [+] ($current/$total_pkgs) Treating as changed: $pkg_name"

            stage3_unverified=$((stage3_unverified + 1))
            state_writable=0

            # No trustworthy current fingerprint exists.
            # Never write an UNAVAILABLE fingerprint to persistent state.
            #
            # If a previous trustworthy fingerprint exists for this exact
            # package/path, carry it forward so a temporary metadata failure
            # does not erase known-good state.

            state_key="${pkg_name}|${apk_path}|"

            state_old_ifs="$IFS"
            IFS='
'

            case "$-" in
            *f*) state_noglob_was_set=1 ;;
            *) state_noglob_was_set=0 ;;
            esac

            set -f
            for prev_fingerprint in $PREV_STATE; do
                case "$prev_fingerprint" in
                "$state_key"*)
                    case "$prev_fingerprint" in
                    *UNAVAILABLE*)
                        ;;
                    *)
                        preserved_fingerprint="$prev_fingerprint"
                        debug_print "Found previous trustworthy fingerprint for [$pkg_name]; preserving only after successful compilation."
                        ;;
                    esac
                    break
                    ;;
                esac
            done

            if [ "$state_noglob_was_set" -eq 0 ]; then
                set +f
            fi

            IFS="$state_old_ifs"

            # Fall through to compilation.

            ;;

        *)

            debug_print "Fingerprint evaluation for [$pkg_name]: $fingerprint"

            case "$PREV_STATE" in
            *"
$fingerprint
"*)

                echo "$fingerprint" >&3

                echo "    [~] ($current/$total_pkgs) Skipping unchanged: $pkg_name"
                stage3_skipped=$((stage3_skipped + 1))

                continue
                ;;
            esac

            ;;
        esac

        # ====================================================================
        # COMPILATION MODE DETECTION
        # ====================================================================

        if [ "$compile_mode" = "speed" ]; then

            if [ "$DRY_RUN" -eq 0 ]; then
                printf '    [+] (%d/%d) Core system compile (-m speed): %s\n' \
                    "$current" "$total_pkgs" "$pkg_name"
            fi

            actual_mode="speed"

        elif [ "$default_mode" = "system" ]; then

            if [ "$DRY_RUN" -eq 0 ]; then
                printf '    [-] (%d/%d) Play Store update compile (-m speed-profile): %s\n' \
                    "$current" "$total_pkgs" "$pkg_name"
            fi

            actual_mode="speed-profile"

        else

            if [ "$DRY_RUN" -eq 0 ]; then
                printf '    [+] (%d/%d) User app compile (-m speed-profile): %s\n' \
                    "$current" "$total_pkgs" "$pkg_name"
            fi

            actual_mode="speed-profile"
        fi

        # ====================================================================
        # Execute compilation
        # ====================================================================

        if [ "$DRY_RUN" -eq 1 ]; then

            printf '    [DRY-RUN] (%d/%d) Would compile (-m %s): %s\n' \
                "$current" "$total_pkgs" "$actual_mode" "$pkg_name"

            stage3_would_compile=$((stage3_would_compile + 1))

        else

            debug_print "Executing command: cmd package compile -m $actual_mode -f $pkg_name"

            err_output=$(cmd package compile -m "$actual_mode" -f "$pkg_name" 2>&1 3>&-)
            compile_exit=$?

            if [ "$compile_exit" -eq 0 ]; then

                printf '    [+] (%d/%d) Compiled: %s\n' \
                    "$current" "$total_pkgs" "$pkg_name"

                # Write state only after successful compilation.
                #
                # With trustworthy current metadata, store the current
                # fingerprint. If metadata was unavailable, carry forward a
                # previous trustworthy fingerprint only now that compilation
                # has succeeded. Failed compilations write no state and will
                # therefore be retried on the next run.
                if [ "$state_writable" -eq 1 ]; then
                    echo "$fingerprint" >&3
                elif [ -n "$preserved_fingerprint" ]; then
                    echo "$preserved_fingerprint" >&3
                    debug_print "Preserved previous trustworthy fingerprint for [$pkg_name] after successful compilation."
                fi

                stage3_compiled=$((stage3_compiled + 1))

            else

                printf '    [!] (%d/%d) Failed: %s (Exit: %d)\n' \
                    "$current" "$total_pkgs" "$pkg_name" "$compile_exit"

                # IMPORTANT:
                # Failed compilations are NOT written to state.
                # They will therefore be retried on the next run.

                stage3_failed=$((stage3_failed + 1))

                if ! printf 'FAIL (%d): %s\n%s\n' \
                    "$compile_exit" "$pkg_name" "$err_output" \
                    >>"$ERROR_TMPFILE" 2>/dev/null; then

                    report_error "    [!] CRITICAL: Failed to write to compile error log! Storage may be full."
                fi
            fi
        fi

    done <"$STAGE_MERGED"

    # ========================================================================
    # DEBUG STAGE 3 ACCOUNTING
    # ========================================================================

    if [ "$DEBUG" -eq 1 ]; then
        debug_print "\n===== DEBUG STAGE 3: COMPILATION =====\n"
        debug_print "Stage 3 input records: $current"
        debug_print "Skipped unchanged:     $stage3_skipped"

        if [ "$DRY_RUN" -eq 1 ]; then
            debug_print "Would compile:          $stage3_would_compile"
        else
            debug_print "Compiled successfully: $stage3_compiled"
            debug_print "Compilation failures:  $stage3_failed"
        fi

        debug_print "Metadata unavailable:  $stage3_unverified"
        debug_print "Invalid records:        $stage3_invalid"

        if [ "$DRY_RUN" -eq 1 ]; then
            stage3_accounted=$((stage3_skipped + stage3_would_compile + stage3_invalid))

            debug_print "Accounting check:      $stage3_skipped + $stage3_would_compile + $stage3_invalid = $stage3_accounted"

            if [ "$current" -eq "$stage3_accounted" ]; then
                debug_print "[+] Stage 3 accounting verified."
            else
                debug_print "[!] WARNING: Stage 3 accounting mismatch."
            fi
        else
            stage3_accounted=$((stage3_skipped + stage3_compiled + stage3_failed + stage3_invalid))

            debug_print "Accounting check:      $stage3_skipped + $stage3_compiled + $stage3_failed + $stage3_invalid = $stage3_accounted"

            if [ "$current" -eq "$stage3_accounted" ]; then
                debug_print "[+] Stage 3 accounting verified."
            else
                debug_print "[!] WARNING: Stage 3 accounting mismatch."
            fi
        fi

        debug_print "--- end DEBUG STAGE 3 ---"
    fi

    # ========================================================================
    # Close current-run state file
    # ========================================================================

    exec 3>&-

    # ========================================================================
    # Accumulate Stage 3 counts globally
    # ========================================================================

    TOTAL_COMPILED=$((TOTAL_COMPILED + stage3_compiled))
    TOTAL_WOULD_COMPILE=$((TOTAL_WOULD_COMPILE + stage3_would_compile))
    TOTAL_SKIPPED=$((TOTAL_SKIPPED + stage3_skipped))
    TOTAL_FAILED=$((TOTAL_FAILED + stage3_failed))
    TOTAL_INVALID=$((TOTAL_INVALID + stage3_invalid))

    return 0
}

# MAIN EXECUTION !!!!!!!!!! MAIN EXECUTION !!!!!!!!! MAIN EXECUTION !!!!!!!!!!
# ============================================================================
# MAIN EXECUTION !!!!!!!!!! MAIN EXECUTION !!!!!!!!! MAIN EXECUTION !!!!!!!!!!
# ============================================================================
# MAIN EXECUTION !!!!!!!!!! MAIN EXECUTION !!!!!!!!! MAIN EXECUTION !!!!!!!!!!

# ============================================================================
# PRE-FLIGHT CHECKS
# ============================================================================

# Display and verify system health before proceeding.
# Exit immediately if thermal or memory conditions are critical.
if ! print_system_status "PRE-FLIGHT CHECK"; then
    report_error "[!] FATAL: Pre-flight system health check failed. Aborting."
    exit 1
fi

# Validate available storage on /data (minimum 500MB required for compilation buffers)
# Reset parser state so values left by earlier functions cannot affect df parsing.
FREE_KB=""
prev1=""
prev2=""

# Run df once, disable globbing, and assign output to positional parameters natively.
set -f
# shellcheck disable=SC2046
set -- $(df -k /data 2>/dev/null)
set +f

# Parse df output: df outputs columns [filesystem, 1k-blocks, used, available, use%, mount]
# We need the "available" column (index 3), so we track previous values as we iterate.
# When we find /data*, prev2 contains the available space from two positions back.
for i in "$@"; do
    case "$i" in
    /data*)
        FREE_KB="$prev2"
        break
        ;;
    esac
    prev2="${prev1:-}"
    prev1="$i"
done

debug_print "Available storage on /data: ${FREE_KB:-0} KB"

if [ -z "$FREE_KB" ]; then
    report_error "    [!] WARNING: Could not determine free storage on /data. Proceeding with caution."
elif [ "$FREE_KB" -lt 512000 ]; then
    report_error "[!] FATAL: Insufficient storage on /data ($((FREE_KB / 1024)) MB available, 500 MB required). Aborting."
    exit 1
fi

# Temporary files for current run state (using explicit $TMPDIR path for Android/Toybox reliability)
# opt_state: fingerprints of packages processed in this run
# opt_stats: cached stat output (inode, size, blocks) for files
# opt_merged: merged package list with metadata for processing
# errors: batch log for compilation errors
CURRENT_RUN_STATE=$(mktemp "${TMPDIR}/opt_state.$$.XXXXXX")
STAGE_STATS=$(mktemp "${TMPDIR}/opt_stats.$$.XXXXXX")
STAGE_MERGED=$(mktemp "${TMPDIR}/opt_merged.$$.XXXXXX")
ERROR_TMPFILE=$(mktemp "${TMPDIR}/errors.$$.XXXXXX")
debug_print "Created temp files: state=$CURRENT_RUN_STATE, stats=$STAGE_STATS, merged=$STAGE_MERGED"

# Verify all temporary files were successfully created (safety check)
if [ -z "$CURRENT_RUN_STATE" ] || [ -z "$STAGE_STATS" ] || [ -z "$STAGE_MERGED" ] || [ -z "$ERROR_TMPFILE" ]; then
    report_error "[!] FATAL: Failed to create temporary state files in $TMPDIR. Aborting."
    exit 1
fi

# ============================================================================
# RUNTIME TRACKING VARIABLES
# ============================================================================
# Previous run's package fingerprints.
PREV_STATE=""

# Select the best baseline state for this run.
#
# Normal runs always use the authoritative complete .last_optimized state.
#
# --no-user runs prefer their own system-only state. On the first --no-user
# run after a successful full run, no system-only state exists, so fall back
# to .last_optimized as the baseline. Exact full-fingerprint matching means
# user-app records in the full state do not interfere with system processing.
STATE_READ_FILE="$STATE_FILE"

if [ "$NO_USER" -eq 1 ] && [ ! -r "$NO_USER_STATE_FILE" ]; then
    STATE_READ_FILE="$FULL_STATE_FILE"
fi

# Load the selected persistent state natively (zero-fork).
# The data is intentionally wrapped in leading and trailing newlines so later
# case matching operates on exact whole fingerprint lines.
if [ -r "$STATE_READ_FILE" ]; then
    debug_print "Loading persistent state baseline from $STATE_READ_FILE"
    PREV_STATE="
$(<"$STATE_READ_FILE")
"
else
    if [ "$NO_USER" -eq 1 ]; then
        debug_print "No system-only or complete state file found. Full system optimization expected."
    else
        debug_print "No existing complete state file found. Full optimization run expected."
    fi
fi

# ============================================================================
# STEP 1: Cache Trimming
# ============================================================================
STEP1_START=$SECONDS

if [ "$DRY_RUN" -eq 1 ]; then
    printf '[+] Step 1: (DRY RUN) Would trim system and app caches...\n'
else
    printf '[+] Step 1: Trimming system and app caches...\n'

    # Ask Package Manager to trim app caches until the requested amount of
    # free storage is available. Using 99999999999 bytes sets a deliberately
    # unreachable free-space target on typical devices, encouraging aggressive
    # cache trimming.
    trim_out=$(pm trim-caches 99999999999 2>&1)
    trim_exit=$?

    if [ $trim_exit -ne 0 ]; then
        report_error "    [!] WARNING: Cache trim failed (Exit Code: $trim_exit)."
        # Only print the output if it actually contains text to avoid blank lines
        if [ -n "$trim_out" ]; then
            report_error "        Output: $trim_out"
        fi
    fi
fi

# Calculate elapsed time for this step
STEP1_DURATION=$((SECONDS - STEP1_START))
printf '[+] Cache trim finished in %ss.\n' "$STEP1_DURATION"

# ============================================================================
# STEP 2: System Package Optimization
# ============================================================================
STEP2_START=$SECONDS

if [ "$DRY_RUN" -eq 1 ]; then
    printf '[+] Step 2: (DRY RUN) Smart-optimizing system packages...\n'
else
    printf '[+] Step 2: Smart-optimizing system packages...\n'
fi

# List all system packages (-s flag) with full paths (-f flag)
debug_print "Querying system packages via pm list packages -f -s..."
system_package_list=$(pm list packages -f -s 2>&1)
sys_exit=$?

if [ "$sys_exit" -ne 0 ]; then
    report_error "    [!] WARNING: Failed to query system packages (Exit Code: $sys_exit)."

    if [ -n "$system_package_list" ]; then
        report_error "        Output: $system_package_list"
    fi

    SYSTEM_PKGS_COUNT=0
    STATE_COMMIT_SAFE=0
else
    if ! process_packages "$system_package_list" "system"; then
        STATE_COMMIT_SAFE=0
    fi
fi

STEP2_DURATION=$((SECONDS - STEP2_START))
printf '[+] System package optimization finished in %ss.\n' "$STEP2_DURATION"

# ============================================================================
# STEP 3: User App Optimization
# ============================================================================
STEP3_START=$SECONDS

if [ "$NO_USER" -eq 1 ]; then
    USER_PKGS_COUNT=0

    if [ "$DRY_RUN" -eq 1 ]; then
        printf '[+] Step 3: (DRY RUN) User app optimization disabled (--no-user).\n'
    else
        printf '[+] Step 3: User app optimization disabled (--no-user).\n'
    fi

    debug_print "Skipping user package query and processing because --no-user is enabled."

else
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '[+] Step 3: (DRY RUN) Smart-optimizing user apps...\n'
    else
        printf '[+] Step 3: Smart-optimizing user apps...\n'
    fi

    debug_print "Querying user packages via pm list packages -f -3..."
    user_package_list=$(pm list packages -f -3 2>&1)
    user_exit=$?

    if [ "$user_exit" -ne 0 ]; then
        report_error "    [!] WARNING: Failed to query user packages (Exit Code: $user_exit)."

        if [ -n "$user_package_list" ]; then
            report_error "        Output: $user_package_list"
        fi

        USER_PKGS_COUNT=0
        STATE_COMMIT_SAFE=0
    else
        if ! process_packages "$user_package_list" "speed-profile"; then
            STATE_COMMIT_SAFE=0
        fi
    fi
fi

STEP3_DURATION=$((SECONDS - STEP3_START))

if [ "$NO_USER" -eq 1 ]; then
    printf '[+] User app optimization skipped in %ss.\n' "$STEP3_DURATION"
else
    printf '[+] User app optimization finished in %ss.\n' "$STEP3_DURATION"
fi

# ============================================================================
# FINAL ACCOUNTING PREPARATION
# ============================================================================

# Calculate total package count.
TOTAL_SCANNED=$((SYSTEM_PKGS_COUNT + USER_PKGS_COUNT))

# Calculate total execution time.
TOTAL_DURATION=$((SECONDS - TOTAL_START_TIME))

# Prepare error notice based only on failures from THIS run.
#
# cleanup() will later move ERROR_TMPFILE to ERROR_LOG, so checking ERROR_LOG
# here could incorrectly report errors from an older run.
error_notice=""
if [ "$TOTAL_FAILED" -gt 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    error_notice="    - [!] Errors occurred. See $ERROR_LOG"
fi

# ============================================================================
# DEBUG FINAL ACCOUNTING
# ============================================================================

if [ "$DEBUG" -eq 1 ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
        debug_total=$((TOTAL_WOULD_COMPILE + TOTAL_SKIPPED + TOTAL_INVALID))

        debug_print "Final dry-run accounting:"
        debug_print "    Scanned:       $TOTAL_SCANNED"
        debug_print "    Would compile: $TOTAL_WOULD_COMPILE"
        debug_print "    Skipped:       $TOTAL_SKIPPED"
        debug_print "    Invalid:       $TOTAL_INVALID"
        debug_print "    Accounted:     $debug_total"

        if [ "$TOTAL_SCANNED" -eq "$debug_total" ]; then
            debug_print "[+] Final dry-run accounting verified."
        else
            debug_print "[!] WARNING: Final dry-run accounting mismatch."
        fi
    else
        debug_total=$((TOTAL_COMPILED + TOTAL_SKIPPED + TOTAL_FAILED + TOTAL_INVALID))

        debug_print "Final accounting:"
        debug_print "    Scanned:   $TOTAL_SCANNED"
        debug_print "    Compiled:  $TOTAL_COMPILED"
        debug_print "    Skipped:   $TOTAL_SKIPPED"
        debug_print "    Failed:    $TOTAL_FAILED"
        debug_print "    Invalid:   $TOTAL_INVALID"
        debug_print "    Accounted: $debug_total"

        if [ "$TOTAL_SCANNED" -eq "$debug_total" ]; then
            debug_print "[+] Final accounting verified."
        else
            debug_print "[!] WARNING: Final accounting mismatch."
        fi
    fi
fi

# ============================================================================
# FINAL SYSTEM HEALTH CHECK
# ============================================================================
# The final health check must succeed BEFORE persistent state can be committed.
# This ensures either state file represents only a fully completed healthy run.
if ! print_system_status "FINAL STATUS"; then
    report_error "    [!] ERROR: Final system health check failed. Persistent state will not be updated."
    printf '==========================================\n'
    exit 1
fi

# ============================================================================
# POST-OPTIMIZATION: State Management
# ============================================================================
# Normal runs commit the complete state to .last_optimized.
# --no-user runs commit system-only state to .last_optimized_system and never
# modify the authoritative complete .last_optimized file.
#
# Dry runs never modify persistent state.
# Incomplete or unsafe runs preserve the previous trusted state.
if [ "$DRY_RUN" -eq 1 ]; then
    printf '[+] Dry-run mode: Persistent state file and error logs were not modified.\n'

elif [ "$STATE_COMMIT_SAFE" -ne 1 ]; then
    report_error "    [!] WARNING: Run was incomplete. Persistent state file was NOT updated."

else
    if [ -r "$STATE_FILE" ] && cmp -s "$CURRENT_RUN_STATE" "$STATE_FILE"; then
        printf '[+] State unchanged. Persistent state file left untouched.\n'
    else
        # Stage the completed state in SCRIPT_DIR first. The final mv then
        # renames a file within the same directory/filesystem as STATE_FILE,
        # making replacement of the selected persistent state file atomic.
        if [ "$NO_USER" -eq 1 ]; then
            STATE_STAGE_TMP=$(mktemp "${SCRIPT_DIR}/.last_optimized_system.$$.XXXXXX")
        else
            STATE_STAGE_TMP=$(mktemp "${SCRIPT_DIR}/.last_optimized.$$.XXXXXX")
        fi
        state_stage_exit=$?

        if [ "$state_stage_exit" -ne 0 ] ||
            [ -z "$STATE_STAGE_TMP" ] ||
            [ ! -f "$STATE_STAGE_TMP" ]; then

            report_error "    [!] WARNING: Failed to create same-filesystem state staging file."
            STATE_COMMIT_SAFE=0

        else
            cp_out=$(cp "$CURRENT_RUN_STATE" "$STATE_STAGE_TMP" 2>&1)
            cp_exit=$?

            if [ "$cp_exit" -ne 0 ]; then
                report_error "    [!] WARNING: Failed to stage persistent state (Exit Code: $cp_exit)."

                if [ -n "$cp_out" ]; then
                    report_error "        Output: $cp_out"
                fi

                STATE_COMMIT_SAFE=0

            else
                mv_out=$(mv "$STATE_STAGE_TMP" "$STATE_FILE" 2>&1)
                mv_exit=$?

                if [ "$mv_exit" -ne 0 ]; then
                    report_error "    [!] WARNING: Failed to atomically update persistent state file (Exit Code: $mv_exit)."

                    if [ -n "$mv_out" ]; then
                        report_error "        Output: $mv_out"
                    fi

                    # Processing completed, but the trusted persistent state
                    # could not be committed atomically.
                    STATE_COMMIT_SAFE=0
                else
                    # The staging path no longer exists after a successful rename.
                    STATE_STAGE_TMP=""
                    if [ "$NO_USER" -eq 1 ]; then
                        printf '[+] System-only persistent state updated atomically.\n'
                    else
                        printf '[+] Complete persistent state updated atomically.\n'
                    fi
                fi
            fi
        fi
    fi
fi

# A successful normal/full run supersedes any older --no-user state cache.
# Remove it only after the complete run has remained state-safe. This avoids
# maintaining two state files on every normal run while guaranteeing the next
# --no-user run starts from the authoritative complete state.
if [ "$DRY_RUN" -eq 0 ] &&
    [ "$NO_USER" -eq 0 ] &&
    [ "$STATE_COMMIT_SAFE" -eq 1 ] &&
    [ -f "$NO_USER_STATE_FILE" ]; then

    debug_print "Removing superseded system-only state file: $NO_USER_STATE_FILE"

    if ! rm -f "$NO_USER_STATE_FILE" 2>/dev/null; then
        report_error "    [!] WARNING: Failed to remove superseded system-only state file $NO_USER_STATE_FILE"
    fi
fi

# ============================================================================
# FINAL REPORT
# ============================================================================

# Prepare operational/runtime error notice based only on THIS run.
run_error_notice=""
if [ "$DRY_RUN" -eq 0 ] &&
    [ -n "${RUN_ERROR_TMPFILE:-}" ] &&
    [ -s "$RUN_ERROR_TMPFILE" ]; then

    run_error_notice="    - [!] Maintenance errors occurred. See $RUN_ERROR_LOG"
fi

printf '\n==========================================\n'

if [ "$DRY_RUN" -eq 1 ]; then
    printf '[+] Maintenance Summary (DRY RUN):\n'
else
    printf '[+] Maintenance Summary:\n'
fi

printf '    - Step 1 (Cache Trim):       %ss\n' "$STEP1_DURATION"
printf '    - Step 2 (System Stage):     %ss\n' "$STEP2_DURATION"
printf '    - Step 3 (User Stage):       %ss\n' "$STEP3_DURATION"
printf '    --------------------------------------\n'
printf '    - Grand Total:               %ss\n' "$TOTAL_DURATION"

if [ "$DRY_RUN" -eq 1 ]; then
    printf '    - Packages Would Compile:    %d\n' "$TOTAL_WOULD_COMPILE"
    printf '    - Packages Would Skip:       %d\n' "$TOTAL_SKIPPED"
    printf '    - Packages Invalid:          %d\n' "$TOTAL_INVALID"
    printf '    - Total Scanned:             %d\n' "$TOTAL_SCANNED"
else
    printf '    - Packages Compiled:         %d\n' "$TOTAL_COMPILED"
    printf '    - Packages Skipped (Cached): %d\n' "$TOTAL_SKIPPED"
    printf '    - Packages Failed:           %d\n' "$TOTAL_FAILED"
    printf '    - Packages Invalid:          %d\n' "$TOTAL_INVALID"
    printf '    - Total Scanned:             %d\n' "$TOTAL_SCANNED"
fi

[ -n "$error_notice" ] && printf '%s\n' "$error_notice"
[ -n "$run_error_notice" ] && printf '%s\n' "$run_error_notice"

if [ "$NO_USER" -eq 1 ]; then
    printf '    - User app stage:            Skipped (--no-user)\n'
fi

if [ "$STATE_COMMIT_SAFE" -ne 1 ]; then
    printf '    - [!] Run incomplete: trusted persistent state was not updated.\n'
elif [ "$DRY_RUN" -eq 0 ]; then
    if [ "$NO_USER" -eq 1 ]; then
        printf '    - Persistent state:          System-only state current.\n'
    else
        printf '    - Persistent state:          Complete state current.\n'
    fi
fi

printf '==========================================\n'

# ============================================================================
# FINAL SUCCESS DETERMINATION
# ============================================================================

# An incomplete processing run or failed state commit is not a successful run.
if [ "$STATE_COMMIT_SAFE" -ne 1 ]; then
    exit 1
fi

# Only now has the entire run completed successfully.
SUCCESSFUL_RUN=1
