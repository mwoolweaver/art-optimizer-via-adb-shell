[![Gatekeeper](https://github.com/mwoolweaver/art-optimizer-via-adb-shell/actions/workflows/gatekeeper.yml/badge.svg?branch=main)](https://github.com/mwoolweaver/art-optimizer-via-adb-shell/actions/workflows/gatekeeper.yml)
[![Update README](https://github.com/mwoolweaver/art-optimizer-via-adb-shell/actions/workflows/update-readme.yml/badge.svg?branch=main)](https://github.com/mwoolweaver/art-optimizer-via-adb-shell/actions/workflows/update-readme.yml)
[![Android API](https://img.shields.io/badge/Android-7.0%2B%20%28API%2024%2B%20%29-green.svg)](https://developer.android.com)
[![License: Unlicense](https://img.shields.io/badge/License-Unlicense-blue.svg)](https://unlicense.org/)
![Shell](https://img.shields.io/badge/Shell-mksh_R59-3DDC84?logo=android&logoColor=white)
![Coreutils](https://img.shields.io/badge/Coreutils-Toybox-blue)

# art-optimizer-via-adb-shell

A shell script to somewhat automate Android ART cache trimming and package optimization, written directly to the device via a heredoc from ADB shell.

## Overview & Features

Keeping your Android runtime (ART) cache optimized ensures faster app launches, smoother performance, and better battery life. This README provides a [heredoc](https://en.wikipedia.org/wiki/Here_document) that can be used over ADB to write the script directly to your device. This bypasses the need to download files or use `adb push`, allowing you to save and execute the script entirely from your computer's terminal.

* **No File Transfers:** Use the heredoc provided below to create the script directly on the device via ADB Shell.
* **Ultra-Lean Execution:** Built with lightweight mksh execution and zero-fork caching logic, bypassing heavy external binaries to run instantly natively.
* **Smart Compilation:** Reads existing ART cache states and skips unchanged packages, saving massive amounts of CPU cycles and preventing thermal throttling.
* **System Safeguards:** Actively monitors battery levels, available memory, and device temperatures before and during execution to ensure device safety.

## Prerequisites

Before running the script, ensure your environment meets the following requirements:

1. **Android Device Requirements:**
   * **Android Version:** Android 7.0 (API Level 24) or higher (required for `cmd package compile` support).
   * **Developer Options:** Enable **USB Debugging** (or **Wireless Debugging** for Android 11+).
   * **Available Storage:** At least **500 MB** of free space on `/data` (for compiled DEX/OAT runtime caches and temporary state execution in `/data/local/tmp`).
2. **Host Machine Setup:**
   * **Terminal Access:** Command-line terminal on macOS, Linux, or Windows (PowerShell/WSL).
   * **ADB (Android Debug Bridge):** Android Platform Tools installed and accessible via your system `$PATH`.
3. **Execution Environment:**
   * **Shell Privileges:** Access to standard `adb shell` (UID 2000) or `root` (UID 0).
   * **Target Directories:** Write access to `/sdcard/monthly/` (script persistence across OTAs) and `/data/local/tmp/` (temporary cache handling via `TMPDIR`).

## Usage

### 1. Connect to your device

Connect your host machine to your Android device depending on your Android version:

* **Android 7.0 – 10 (USB Required)**
  Connect via USB cable with **USB Debugging** enabled.

  *Optional: Switch to wireless mode after initial USB connection:*
  ```bash
  adb tcpip 5555
  # Disconnect USB cable, then connect over Wi-Fi:
  adb connect <IP_ADDRESS>:5555
  ```

* **Android 11+ (Native Wireless Debugging)**
  Enable **Wireless Debugging** in Developer Options and connect directly over Wi-Fi:
  ```bash
  # First-time pairing (requires pairing code & port from Developer Options):
  adb pair <IP>:<PAIRING_PORT>

  # Connection (uses IP & connection port from Developer Options):
  adb connect <IP>:<CONNECTION_PORT>
  ```

> **Verification:** Run `adb devices`. If the status reads `unauthorized`, accept the RSA key prompt on your device screen.

### 2. Open Shell & Make Directory

Open an interactive ADB shell and create the script directory inside `/sdcard/`:

```bash
adb shell
mkdir -p /sdcard/monthly/
```

> **Why `/sdcard/`?**
> Storing the script in internal storage (`/sdcard/monthly/`) ensures it persists across system OS updates (OTAs), whereas files in `/data/local/tmp/` are often wiped during system updates or reboots.

### 3. Write the script using a heredoc

Expand the section below, paste the block into your terminal, and press **Enter** to save `maintenance.sh` directly to your device.

<!-- NOTE: Do not remove SCRIPT_START and SCRIPT_END comments below.
     They are used by update-readme.yml to auto-inject maintenance.sh -->

<details>
<summary><b>Click to Expand Heredoc</b></summary>

<!-- SCRIPT_START -->
```bash
cat << 'EOF' > /sdcard/monthly/maintenance.sh
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
# DEBUG & DRY_RUN CONFIGURATION
# Purpose: Enable debug logging or dry-run ability
#          via environment variable (DEBUG=1) or flags (--debug)
# ============================================================================
DEBUG="${DEBUG:-0}"
DRY_RUN="${DRY_RUN:-0}"
for arg in "$@"; do
    case "$arg" in
    --debug) DEBUG=1 ;;
    --dry-run) DRY_RUN=1 ;;
    esac
done

debug_print() {
    if [ "$DEBUG" -eq 1 ]; then
        echo "[DEBUG] $1" >&2
    fi
}

debug_print "Debug/Verbose mode initialized."

if [ "$DRY_RUN" -eq 1 ]; then
    debug_print "Dry-run mode enabled."
fi

# ============================================================================
# EARLY PRIVILEGE GUARD
# Purpose: Abort immediately if not running as root (UID 0) or Shell (UID 2000)
# ============================================================================
SCRIPT_UID=${USER_ID:-1}
debug_print "Checked user ID: $SCRIPT_UID"
if [ "$SCRIPT_UID" -ne 0 ] && [ "$SCRIPT_UID" -ne 2000 ]; then
    printf '[!] FATAL: Elevated privileges required (root or adb shell). Aborting.\n' >&2
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
    printf '[!] FATAL: Device failed to report boot completion after 300 seconds. Aborting.\n' >&2
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
    for req in awk cmd cmp cp date df dirname dumpsys getprop mkdir mktemp mv pm printf rm rmdir service sleep stat xargs; do
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
# Verify all required commands are installed as soon as possible
check_deps

# ============================================================================
# PACKAGE SERVICE GUARD
# Purpose: Verify package manager IPC service is registered on the binder bus
# ============================================================================
case "$(service check package 2>/dev/null)" in
*"not found"* | "")
    printf '[!] FATAL: Package manager service is not running or unresponsive. Aborting.\n' >&2
    exit 1
    ;;
esac

# ============================================================================
# INITIALIZATION: Timing and System Detection
# ============================================================================
# Record script start time for total duration calculation (in Unix epoch seconds)
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
    printf '[!] FATAL: Android 7.0 (API %d) or higher required. Current API: %s\n' "$MIN_SDK" "$sdk_version" >&2
    exit 1
fi

if [ "$DRY_RUN" -eq 1 ]; then
    printf '[+] Starting ART Smart Maintenance (DRY RUN) on Android %s (SDK %s)...\n' "$android_version" "$sdk_version"
else
    printf '[+] Starting ART Smart Maintenance on Android %s (SDK %s)...\n' "$android_version" "$sdk_version"
fi

# ============================================================================
# TEMP FILE & STATE MANAGEMENT VARIABLES
# ============================================================================
# Most Android systems have /data/local/tmp available; ensures temp files go to writable location
export TMPDIR=/data/local/tmp
debug_print "Set TMPDIR to $TMPDIR"

# Validate that TMPDIR exists and is actually writable
if ! [ -d "$TMPDIR" ] || ! [ -w "$TMPDIR" ]; then
    printf '[!] FATAL: Temporary directory '\''%s'\'' is missing or not writable. Aborting.\n' "$TMPDIR" >&2
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
    printf '[!] FATAL: Script directory '\''%s'\'' is not writable. Aborting.\n' "$SCRIPT_DIR" >&2
    exit 1
fi

# Persistent file tracking package fingerprints from previous run
# Used to skip recompiling unchanged packages
STATE_FILE="${SCRIPT_DIR}/.last_optimized"
readonly STATE_FILE

# Log file for compile errors (will be created/truncated as needed)
ERROR_LOG="${SCRIPT_DIR}/compile_errors.log"
readonly ERROR_LOG

# ============================================================================
# SIGNAL HANDLERS & CLEANUP
# ============================================================================
cleanup() {
    debug_print "Executing cleanup handler (SUCCESSFUL_RUN=$SUCCESSFUL_RUN)..."

    if [ "$SUCCESSFUL_RUN" -eq 0 ]; then
        # --- ABORTED OR FAILED RUN ---
        # Save an early exit snapshot for debugging so we can see where it died
        if [ -n "${CURRENT_RUN_STATE:-}" ] && [ -f "$CURRENT_RUN_STATE" ] && [ -s "$CURRENT_RUN_STATE" ]; then
            debug_print "Saving early exit snapshot to: ${SCRIPT_DIR}/.early_exit"
            if ! cp "$CURRENT_RUN_STATE" "${SCRIPT_DIR}/.early_exit" 2>/dev/null; then
                printf '    [!] Warning: Failed to save early exit snapshot to %s\n' "${SCRIPT_DIR}/.early_exit" >&2
            fi
        fi

        # Move error tempfile to final log if errors exist
        if [ -n "${ERROR_TMPFILE:-}" ] && [ -f "$ERROR_TMPFILE" ] && [ -s "$ERROR_TMPFILE" ]; then
            debug_print "Saving error log to: $ERROR_LOG"
            if ! mv "$ERROR_TMPFILE" "$ERROR_LOG" 2>/dev/null; then
                printf '    [!] Warning: Failed to save error log to %s\n' "$ERROR_LOG" >&2
            fi
        fi
    else
        # --- SUCCESSFUL RUN ---
        # Nuke the debugging autopsy file since this run completed perfectly
        if [ -f "${SCRIPT_DIR}/.early_exit" ]; then
            debug_print "Cleaning up old autopsy file: ${SCRIPT_DIR}/.early_exit"
            if ! rm -f "${SCRIPT_DIR}/.early_exit" 2>/dev/null; then
                printf '    [!] Warning: Failed to clean up %s\n' "${SCRIPT_DIR}/.early_exit" >&2
            fi
        fi
    fi

    # Remove all volatile temporary files that STILL EXIST on disk
    for tmpfile in "${CURRENT_RUN_STATE:-}" "${STAGE_STATS:-}" "${STAGE_MERGED:-}" "${ERROR_TMPFILE:-}"; do
        # Skip empty variable strings or files that have already been moved/removed
        if [ -n "$tmpfile" ] && [ -e "$tmpfile" ]; then
            debug_print "Cleaning up temporary file: $tmpfile"
            if ! rm -f "$tmpfile" 2>/dev/null; then
                printf '    [!] Warning: Failed to clean up %s\n' "$tmpfile" >&2
            fi
        fi
    done

    # Release the concurrency lock if it exists
    if [ -n "${LOCK_DIR:-}" ] && [ -d "$LOCK_DIR" ]; then
        debug_print "Releasing concurrency lock at $LOCK_DIR"
        if ! rmdir "$LOCK_DIR" 2>/dev/null; then
            printf '    [!] CRITICAL: Failed to release lock at %s. Manual deletion required.\n' "$LOCK_DIR" >&2
        fi
    fi
}

# Handle SIGINT (Ctrl+C) and SIGTERM (kill) gracefully with distinct exit codes
# 130 for Ctrl+C and 143 for kill are standard Unix conventions respected by virtually all shell orchestrators.
# Exiting via these traps automatically triggers the EXIT trap (cleanup) beforehand.
trap 'printf "\n    [!] Interrupted by user (SIGINT). Cleaning up...\n"; exit 130' INT
trap 'printf "\n    [!] Terminated by system (SIGTERM). Cleaning up...\n"; exit 143' TERM

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

# Initialize a flag to track successful completion
SUCCESSFUL_RUN=0

# Package counting variables
SYSTEM_PKGS_COUNT=0
USER_PKGS_COUNT=0
TOTAL_COMPILED=0

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
        local therm_status
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

        # Attempt 3: dumpsys battery (Accessible to ADB/shell user)
        # Battery temperature is in tenths of a degree (e.g. 350 = 35.0 C)
        set -f
        # shellcheck disable=SC2046
        set -- $(dumpsys battery 2>/dev/null)
        set +f
        for i in "$@"; do
            if [ "${prev1:-}" = "temperature:" ]; then
                bat_temp=$((i / 10))
                if [ "$bat_temp" -gt 0 ]; then
                    printf '%d\n' "$bat_temp"
                    return 0
                fi
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

        if [ $val_exit -ne 0 ]; then
            debug_print "Failed to read thermal zone $f (Exit: $val_exit): $val_out"
            continue
        fi

        [ -z "$val_out" ] && continue
        case "$val_out" in *[!0-9]*) continue ;; esac

        debug_print "Read thermal zone from sysfs: $f = $val_out"
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
# Purpose: Calculate memory pressure as percentage of used memory directly via awk
# Returns: Percentage (0-100), or "N/A" if unavailable
# ============================================================================
get_memory_pressure() {
    if [ -r /proc/meminfo ]; then
        local t="" a=""
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
#   $1 = Package list (format: "/path/to/apk.apk=package.name\n...")
#   $2 = Default compile mode (system, speed-profile)
# ============================================================================
process_packages() {
    pkg_list="$1"
    default_mode="$2"

    # Exit early if package list is empty
    [ -z "$pkg_list" ] && {
        debug_print "Package list for mode '$default_mode' is empty."
        return 0
    }

    # Count total packages for progress reporting
    total_pkgs=0
    set -f # Disable glob expansion (wildcards won't expand)
    OLD_IFS="$IFS"
    IFS='
'
    for item in $pkg_list; do
        [ -n "$item" ] && total_pkgs=$((total_pkgs + 1))
    done
    IFS="$OLD_IFS"
    set +f # Re-enable glob expansion
    debug_print "Total packages parsed for '$default_mode': $total_pkgs"

    # ========================================================================
    # STAGE 1: Extract file paths and get stat metadata
    # ========================================================================
    # Parse native Android package list, extract file paths/dirs,
    # deduplicate inline, and run stat.
    debug_print "Running STAGE 1: Extracting file paths and stat metadata..."
    printf '%s\n' "$pkg_list" | awk '{
        line = $0
        idx = 0

        # Find the last "=" to separate the APK path from the package name.
        # This is necessary because Android paths can themselves contain "=".
        for (i = length(line); i > 0; i--) {
            if (substr(line, i, 1) == "=") {
                idx = i
                break
            }
        }

        if (idx > 0) {
            # Extract APK path from native pm format:
            # /path/to/base.apk=com.example.app
            path = substr(line, 1, idx - 1)

            # Security sanity check: skip malformed paths,
            # null bytes, or excessive lengths.
            if (path ~ /\0/ || length(path) > 1024)
                next

            # Inline deduplication
            if (!seen[path]++)
                printf "%s\0", path

            # Extract parent directory cleanly
            if (match(path, /.*\//)) {
                dir = substr(path, 1, RLENGTH - 1)

                if (dir ~ /\0/ || length(dir) > 1024)
                    next

                if (!seen[dir]++)
                    printf "%s\0", dir
            }
        }
    }' | xargs -0 -r stat -c "%n=%Y:%s:%i" 2>/dev/null >"$STAGE_STATS"

    # Batches the unique paths into a single efficient 'stat' call.
    # Stat Format Mapping:
    #   %n = File path
    #   %Y = Time of last data modification (epoch seconds)
    #   %s = Total size in bytes
    #   %i = Inode number

    # ========================================================================
    # STAGE 2: Match packages to stat metadata (change detection setup)
    # ========================================================================

    # Read the stat data into memory and merge with package information
    debug_print "Running STAGE 2: Matching packages to stat metadata..."
    printf '%s\n' "$pkg_list" | awk -v sf="$STAGE_STATS" '
        BEGIN {
            # Load stat cache into memory for fast lookups
            while ((getline line < sf) > 0) {
                idx = index(line, "=")

                if (idx > 0) {
                    p = substr(line, 1, idx - 1)
                    m = substr(line, idx + 1)
                    stats[p] = m
                }
            }

            close(sf)
        }

        {
            line = $0

            if (line == "")
                next

            # Native pm format:
            # /path/to/base.apk=com.example.app
            #
            # Find the LAST "=" because the APK path can contain "=".
            idx = 0

            for (i = length(line); i > 0; i--) {
                if (substr(line, i, 1) == "=") {
                    idx = i
                    break
                }
            }

            if (idx > 0) {
                path = substr(line, 1, idx - 1)
                pkg = substr(line, idx + 1)

                # Look up stat data for the APK itself
                meta = stats[path]

                if (meta == "") {
                    # APK metadata unavailable.
                    # Fall back to parent directory metadata to detect
                    # partial/split APK updates.
                    dir = path

                    sub("/[^/]+/?$", "", dir)
                    d_meta = stats[dir]

                    if (d_meta != "") {
                        split(d_meta, arr, ":")
                        meta = arr[1] ":0:" arr[3]
                    } else {
                        # Neither APK nor parent directory could be verified.
                        meta = "UNAVAILABLE"
                    }
                }

                # Output internal format:
                # package|path|metadata
                print pkg "|" path "|" meta
            }
        }
    ' >"$STAGE_MERGED"

    # ========================================================================
    # STAGE 3: Process each package (with change detection)
    # ========================================================================
    debug_print "Running STAGE 3: Processing package compilation sequence..."
    current=0

    exec 3>>"$CURRENT_RUN_STATE"

    # Read the merged data line by line
    while IFS='|' read -r pkg_name apk_path file_meta; do
        current=$((current + 1))
        [ -z "$pkg_name" ] && continue

        # Sanity check: ensure package name contains no whitespace
        case "$pkg_name" in
        *[[:space:]]*)
            echo "    [!] Skipping package with whitespace in name: $pkg_name" >&2
            continue
            ;;
        esac

        # Determine compile mode based on package location
        compile_mode="$default_mode"

        if [ "$default_mode" = "system" ]; then
            # System packages installed in /data/ are third-party updates
            if [ "$apk_path" != "${apk_path#/data/}" ]; then
                compile_mode="speed-profile"
            else
                compile_mode="speed"
            fi
        fi

        fingerprint="${pkg_name}:${apk_path}:${file_meta}"

        case "$fingerprint" in
        *UNAVAILABLE*)
            echo "    [!] ($current/$total_pkgs) Unable to verify metadata: $pkg_name"
            echo "    [+] ($current/$total_pkgs) Treating as changed: $pkg_name"

            # No trustworthy fingerprint exists.
            # Do not consult or update persistent state.
            # Fall through to compilation.
            ;;
        *)
            debug_print "Fingerprint evaluation for [$pkg_name]: $fingerprint"

            case "$PREV_STATE" in
            *"
$fingerprint
"*)
                # Package is unchanged. Carry its fingerprint forward
                # into the new state without recompiling.
                echo "$fingerprint" >&3

                echo "    [~] ($current/$total_pkgs) Skipping unchanged: $pkg_name"
                continue
                ;;
            esac
            ;;
        esac

        # ====================================================================
        # COMPILATION: Execute appropriate compilation mode
        # ====================================================================
        if [ "$compile_mode" = "speed" ]; then
            # Full ahead-of-time (AOT) compilation for maximum performance
            if [ "$DRY_RUN" -eq 0 ]; then
                printf '    [+] (%d/%d) Core system compile (-m speed): %s\n' \
                    "$current" "$total_pkgs" "$pkg_name"
            fi

            actual_mode="speed"

        elif [ "$default_mode" = "system" ]; then
            # Profile-guided optimization for Play Store System App updates
            if [ "$DRY_RUN" -eq 0 ]; then
                printf '    [-] (%d/%d) Play Store update compile (-m speed-profile): %s\n' \
                    "$current" "$total_pkgs" "$pkg_name"
            fi

            actual_mode="speed-profile"

        else
            # Profile-guided optimization for user-installed third-party apps
            if [ "$DRY_RUN" -eq 0 ]; then
                printf '    [+] (%d/%d) User app compile (-m speed-profile): %s\n' \
                    "$current" "$total_pkgs" "$pkg_name"
            fi

            actual_mode="speed-profile"
        fi

        # Attempt compilation (or simulate if dry run)
        if [ "$DRY_RUN" -eq 1 ]; then
            printf '    [DRY-RUN] (%d/%d) Would compile (-m %s): %s\n' \
                "$current" "$total_pkgs" "$actual_mode" "$pkg_name"

            TOTAL_COMPILED=$((TOTAL_COMPILED + 1))

        else
            debug_print "Executing command: cmd package compile -m $actual_mode -f $pkg_name"

            err_output=$(cmd package compile -m "$actual_mode" -f "$pkg_name" 2>&1 3>&-)
            compile_exit=$?

            if [ $compile_exit -eq 0 ]; then
                printf '    [+] (%d/%d) Compiled: %s\n' \
                    "$current" "$total_pkgs" "$pkg_name"

                # Compilation succeeded. Only now commit this fingerprint
                # to the current-run state.
                echo "$fingerprint" >&3

                TOTAL_COMPILED=$((TOTAL_COMPILED + 1))

            else
                printf '    [!] (%d/%d) Failed: %s (Exit: %d)\n' \
                    "$current" "$total_pkgs" "$pkg_name" "$compile_exit"

                # IMPORTANT:
                # Do NOT write the fingerprint to CURRENT_RUN_STATE.
                # This forces the package to be retried on the next run.

                # Log the error, but explicitly catch if the logging itself
                # fails (e.g., out of space).
                if ! printf 'FAIL (%d): %s\n%s\n' \
                    "$compile_exit" "$pkg_name" "$err_output" \
                    >>"$ERROR_TMPFILE" 2>/dev/null; then

                    printf '    [!] CRITICAL: Failed to write to error log! Storage may be full.\n' >&2
                fi
            fi
        fi

    done <"$STAGE_MERGED"

    # Close File Descriptor 3 cleanly after the loop finishes
    exec 3>&-

    # ========================================================================
    # Expose stage count globally so the summary can calculate grand totals
    # ========================================================================
    if [ "$default_mode" = "system" ]; then
        SYSTEM_PKGS_COUNT="$total_pkgs"
    else
        USER_PKGS_COUNT="$total_pkgs"
    fi
}

# MAIN EXECUTION !!!!!!!!!! MAIN EXECUTION !!!!!!!!! MAIN EXECUTION !!!!!!!!!!
# ============================================================================
# MAIN EXECUTION !!!!!!!!!! MAIN EXECUTION !!!!!!!!! MAIN EXECUTION !!!!!!!!!!
# ============================================================================
# MAIN EXECUTION !!!!!!!!!! MAIN EXECUTION !!!!!!!!! MAIN EXECUTION !!!!!!!!!!

# ============================================================================
# PRE-FLIGHT CHECKS
# ============================================================================

# Display and verify system health before proceeding
# Exit immediately if thermal or memory conditions are critical
print_system_status "PRE-FLIGHT CHECK" || exit 1

# Validate available storage on /data (minimum 500MB required for compilation buffers)
# Run df once, disable globbing, and assign output to positional parameters natively
set -f
# shellcheck disable=SC2046
set -- $(df -k /data 2>/dev/null)
set +f

FREE_KB=""
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
    printf '    [!] WARNING: Could not determine free storage on /data. Proceeding with caution.\n' >&2
elif [ "$FREE_KB" -lt 512000 ]; then
    printf '[!] FATAL: Insufficient storage on /data (%d MB available, 500 MB required). Aborting.\n' "$((FREE_KB / 1024))" >&2
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
    printf '[!] FATAL: Failed to create temporary state files in %s. Aborting.\n' "$TMPDIR" >&2
    exit 1
fi

# ============================================================================
# RUNTIME TRACKING VARIABLES
# ============================================================================
# Previous run's package fingerprints (loaded from STATE_FILE if it exists)
PREV_STATE=""

# Load the persistent state from disk natively (zero-fork).
# Using $(< file) reads directly into RAM without spawning an external 'cat'
# process, which maximizes performance and eliminates $PATH execution risks.
# Note: The data is intentionally wrapped in leading and trailing newlines.
# This guarantees that our 'case' statement later matches exact whole lines,
# preventing partial string collisions (e.g., matching "app" inside "app.pro").
if [ -r "$STATE_FILE" ]; then
    debug_print "Loading persistent state file from $STATE_FILE"
    PREV_STATE="
$(<"$STATE_FILE")
"
else
    debug_print "No existing state file found at $STATE_FILE. Full optimization run expected."
fi

# ============================================================================
# STEP 1: Cache Trimming
# ============================================================================
STEP1_START=$SECONDS

if [ "$DRY_RUN" -eq 1 ]; then
    printf '[+] Step 1: (DRY RUN) Would trim system and app caches...\n'
else
    printf '[+] Step 1: Trimming system and app caches...\n'

    # Tell package manager to clean app caches
    # Argument 100G indicates target cache size (aggressively frees everything)
    trim_out=$(pm trim-caches 100G 2>&1)
    trim_exit=$?

    if [ $trim_exit -ne 0 ]; then
        printf '    [!] WARNING: Cache trim failed (Exit Code: %d).\n' "$trim_exit" >&2
        # Only print the output if it actually contains text to avoid blank lines
        if [ -n "$trim_out" ]; then
            printf '        Output: %s\n' "$trim_out" >&2
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

if [ $sys_exit -ne 0 ]; then
    printf '    [!] WARNING: Failed to query system packages (Exit Code: %d).\n' "$sys_exit" >&2
    if [ -n "$system_package_list" ]; then
        printf '        Output: %s\n' "$system_package_list" >&2
    fi
    SYSTEM_PKGS_COUNT=0
else
    # Strip "package:" prefix and carriage returns purely in RAM (Zero-Fork)
    system_package_list="${system_package_list//package:/}"
    system_package_list="${system_package_list//$CR/}"

    # Validate that we actually got a package list before processing
    if [ -z "$system_package_list" ]; then
        printf '    [!] WARNING: System package list is empty. Skipping system stage.\n' >&2
        SYSTEM_PKGS_COUNT=0
    else
        # Compile system packages with appropriate mode
        process_packages "$system_package_list" "system"
    fi
fi
STEP2_DURATION=$((SECONDS - STEP2_START))
printf '[+] System package optimization finished in %ss.\n' "$STEP2_DURATION"

# ============================================================================
# STEP 3: User App Optimization
# ============================================================================
STEP3_START=$SECONDS

if [ "$DRY_RUN" -eq 1 ]; then
    printf '[+] Step 3: (DRY RUN) Smart-optimizing user apps...\n'
else
    printf '[+] Step 3: Smart-optimizing user apps...\n'
fi

debug_print "Querying user packages via pm list packages -f -3..."
user_package_list=$(pm list packages -f -3 2>&1)
user_exit=$?

if [ $user_exit -ne 0 ]; then
    printf '    [!] WARNING: Failed to query user packages (Exit Code: %d).\n' "$user_exit" >&2
    if [ -n "$user_package_list" ]; then
        printf '        Output: %s\n' "$user_package_list" >&2
    fi
    USER_PKGS_COUNT=0
else
    # Strip "package:" prefix and carriage returns purely in RAM (Zero-Fork)
    user_package_list="${user_package_list//package:/}"
    user_package_list="${user_package_list//$CR/}"

    if [ -z "$user_package_list" ]; then
        printf '    [!] WARNING: User package list is empty. Skipping user stage.\n' >&2
        USER_PKGS_COUNT=0
    else
        process_packages "$user_package_list" "speed-profile"
    fi
fi
STEP3_DURATION=$((SECONDS - STEP3_START))
printf '[+] User app optimization finished in %ss.\n' "$STEP3_DURATION"

# ============================================================================
# POST-OPTIMIZATION: State Management
# ============================================================================
# Update persistent state file only if fingerprints changed (skipped in dry run)
# Avoids unnecessary disk writes when nothing changed
if [ "$DRY_RUN" -eq 1 ]; then
    printf '[+] Dry-run mode: Persistent state file and error logs were not modified.\n'
else
    # Move temporary state file to persistent location
    if [ -r "$STATE_FILE" ] && cmp -s "$CURRENT_RUN_STATE" "$STATE_FILE"; then
        printf '[+] State unchanged. Persistent state file left untouched.\n'
    else
        # Move temporary state file to persistent location and catch any errors
        mv_out=$(mv "$CURRENT_RUN_STATE" "$STATE_FILE" 2>&1)
        mv_exit=$?

        if [ $mv_exit -ne 0 ]; then
            printf '    [!] WARNING: Failed to update persistent state file (Exit Code: %d).\n' "$mv_exit" >&2

            # Print the exact OS error if one was generated
            if [ -n "$mv_out" ]; then
                printf '        Output: %s\n' "$mv_out" >&2
            fi
        else
            printf '[+] Persistent state file updated.\n'
        fi
    fi

    # Move error tempfile to final log only if errors exist
    if [ -s "$ERROR_TMPFILE" ]; then
        if ! mv "$ERROR_TMPFILE" "$ERROR_LOG" 2>/dev/null; then
            printf '    [!] WARNING: Failed to save error log to %s\n' "$ERROR_LOG" >&2
        fi
    fi
fi

# ============================================================================
# FINAL REPORT
# ============================================================================
# Mark the run as fully successful
SUCCESSFUL_RUN=1

#Calculate package counts
TOTAL_SCANNED=$((SYSTEM_PKGS_COUNT + USER_PKGS_COUNT))
TOTAL_SKIPPED=$((TOTAL_SCANNED - TOTAL_COMPILED))

# Calculate total execution time
TOTAL_DURATION=$((SECONDS - TOTAL_START_TIME))

# Prepare error notice if errors were logged
error_notice=""
if [ -s "$ERROR_LOG" ] && [ "$DRY_RUN" -eq 0 ]; then
    error_notice="    - [!] Errors occurred. See $ERROR_LOG"
fi

printf '\n==========================================\n'
if [ "$DRY_RUN" -eq 1 ]; then
    printf '[+] Maintenance Summary (DRY RUN):\n'
else
    printf '[+] Maintenance Summary:\n'
fi
printf '    - Step 1 (Cache Trim):     %ss\n' "$STEP1_DURATION"
printf '    - Step 2 (System Stage):   %ss\n' "$STEP2_DURATION"
printf '    - Step 3 (User Stage):     %ss\n' "$STEP3_DURATION"
printf '    --------------------------------------\n'
printf '    - Grand Total:             %ss\n' "$TOTAL_DURATION"
if [ "$DRY_RUN" -eq 1 ]; then
    printf '    - Packages Would Compile:  %d\n' "$TOTAL_COMPILED"
    printf '    - Packages Would Skip:     %d\n' "$TOTAL_SKIPPED"
else
    printf '    - Packages Compiled:       %d\n' "$TOTAL_COMPILED"
    printf '    - Packages Skipped (Cached): %d\n' "$TOTAL_SKIPPED"
fi
[ -n "$error_notice" ] && printf '%s\n' "$error_notice"
printf '==========================================\n'

print_system_status "FINAL STATUS"
printf '==========================================\n'
EOF
```
<!-- SCRIPT_END -->

</details>

### 4. Run the script

Execute the script by passing it explicitly to `sh`:

```bash
sh /sdcard/monthly/maintenance.sh
```

> **Note:** Executing via `sh /sdcard/monthly/maintenance.sh` allows the shell interpreter to read and run the script directly, cleanly bypassing the `noexec` mount restriction enforced on `/sdcard/`.

#### Example Output:

```text
    [~] (116/117) Skipping unchanged: com.wireguard.android
    [~] (117/117) Skipping unchanged: org.videolan.vlc
[+] State unchanged. Persistent state file left untouched.
[+] User app optimization finished in 1s.
==========================================
[+] Maintenance Summary:
    - Step 1 (Cache Trim):     2s
    - Step 2 (System Stage):   2s
    - Step 3 (User Stage):     1s
    --------------------------------------
    - Grand Total:             7s
    - Packages Compiled:       0
    - Packages Skipped (Cached): 482
==========================================

    ─────────────────────────────────
    FINAL STATUS
    ─────────────────────────────────
[*] Thermal:  28°C (OK)
[!] Memory:   95.6% (MODERATE)
[*] Battery:  80%
    ─────────────────────────────────

==========================================
```

## 💡 Pro-Tip: Automation

Because this script includes thermal safeguards and state-caching, it is safe to automate in the background. You can easily schedule it to run in **Tasker** or **MacroDroid** (e.g., weekly at 3:00 AM while charging).

### Command by Setup Type

* **Rooted Devices:**
  Use a standard **Run Shell** action with **Use Root** checked:
  ```bash
  sh /sdcard/monthly/maintenance.sh
  ```

* **Non-Rooted Devices:**
  Use Tasker's **ADB Wifi** action or MacroDroid's **ADB Shell Command** action:
  ```bash
  sh /sdcard/monthly/maintenance.sh
  ```

> **Note for Non-Rooted Automation:**
> Non-rooted devices executing shell commands require ADB Wi-Fi privileges. On Android 11+, Tasker can natively manage ADB Wi-Fi pairing across reboots. On Android 7–10, ADB Wi-Fi mode must be re-enabled after a reboot (`adb tcpip 5555`).

## License

This project is free and unencumbered software released into the public domain under [The Unlicense](LICENSE). For more information, please refer to <http://unlicense.org/>
