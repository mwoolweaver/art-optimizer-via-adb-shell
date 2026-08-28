[![Auto-Inject Script into README](https://github.com)](https://github.com)

# art-optimizer-via-adb-shell

A shell script to somewhat automate Android ART cache trimming and package optimization, written directly to the device via a heredoc from ADB shell.

## Overview & Features

Keeping your Android runtime (ART) cache optimized ensures faster app launches, smoother performance, and better battery life. This README provides a heredoc block that can be used over ADB to write the script directly to your device. This bypasses the need to download files or use `adb push`, allowing you to save and execute the script entirely from your computer's terminal.

*   **No File Transfers:** Use the heredoc provided below to create the script directly on the device via ADB Shell.
*   **Ultra-Lean Execution:** Built with strict POSIX compliance and zero-fork caching logic, bypassing heavy external binaries to run instantly natively.
*   **Smart Compilation:** Reads existing ART cache states and skips unchanged packages, saving massive amounts of CPU cycles and preventing thermal throttling.
*   **System Safeguards:** Actively monitors battery levels, available memory, and device temperatures before and during execution to ensure device safety.

## Prerequisites

Before running the script, ensure you have the following setup:

1.  **Terminal Access:** The script creation and execution are initiated from your computer.
2.  **ADB (Android Debug Bridge):** Requires `adb`, available via Homebrew on macOS or most default Linux package managers.
3.  **Debugging Enabled:** Turn on Developer Options on your Android device and enable USB or Wireless Debugging.

## Usage 

### 1. Connect to your device

Connect via USB or Wireless Debugging. For newer hardware, Wireless Debugging is paired securely via IP and Port:

```bash
# First time pairing:
adb pair <IP>:<PAIRING_PORT>

# Subsequent connections:
adb connect <IP>:<CONNECTION_PORT>
```

*Verify your connection by running `adb devices`. If the device shows as `unauthorized`, check your phone screen to grant the RSA key prompt.*

### 2. Open Shell & Make Directory

Open an interactive ADB shell and create the target directory:

```bash
adb shell
mkdir -p /sdcard/monthly/
```

### 3. Write the script using a heredoc

Expand the section below, paste the entire block into your terminal, and hit **Enter** to save the script directly to your device.

<details>
<summary><b>Click to Expand Heredoc</b></summary>

<!-- SCRIPT_START -->
```bash
cat << 'EOF' > /sdcard/monthly/maintenance.sh
#!/system/bin/sh
# shellcheck shell=ksh

# ============================================================================
# ART Smart Maintenance Script
# Purpose: Optimize Android ART (Android Runtime) compiled packages through
#          intelligent cache management and profile-guided compilation
# Environment: Designed specifically for Android system/device environments
#              utilizing Android-native utilities (dumpsys, pm, getprop).
# ============================================================================

set -u # Exit immediately if any variable is unset

# SECURITY: Restrict file creation umask to owner-only (rw-------)
# This prevents accidental world-readable sensitive files
umask 077

# PERFORMANCE: Force C locale (POSIX) instead of system locale
# Avoids locale-specific string sorting/regex issues and speeds up text processing
export LC_ALL=C

# ============================================================================
# EARLY PRIVILEGE GUARD
# Purpose: Abort immediately if not running as root (UID 0) or Shell (UID 2000)
# ============================================================================
USER_ID=$(id -u 2>/dev/null || printf '9999')
if [ "$USER_ID" -ne 0 ] && [ "$USER_ID" -ne 2000 ]; then
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
done

# ============================================================================
# FUNCTION: check_deps()
# Purpose: Verify all required shell commands are available on the system
# Note: Assumes an Android device shell environment containing host tools
#       like pm, cmd, dumpsys, getprop, and standard POSIX utilities. Collects
#       all missing dependencies before failing so you can fix them at once.
# ============================================================================
check_deps() {
    missing=""
    for req in awk cmd cmp cp date df dirname dumpsys getprop mkdir mktemp mv pm printf rm rmdir sed service sleep stat xargs; do
        if ! command -v "$req" >/dev/null 2>&1; then
            missing="${missing}$req "
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
if ! service check package >/dev/null 2>&1; then
    printf '[!] FATAL: Package manager service is not running or unresponsive. Aborting.\n' >&2
    exit 1
fi

# ============================================================================
# INITIALIZATION: Timing and System Detection
# ============================================================================
# Record script start time for total duration calculation (in Unix epoch seconds)
TOTAL_START_TIME=$(date +%s)

# Query device properties (fail gracefully if unavailable)
android_version=$(getprop ro.build.version.release 2>/dev/null)
sdk_version=$(getprop ro.build.version.sdk 2>/dev/null)

# Safe fallback assignments
android_version="${android_version:-Unknown}"
sdk_version="${sdk_version:-0}"

# ============================================================================
# API LEVEL GUARD
# Purpose: Require Android 7.0 (API 24)+ for 'cmd package compile' support
# ============================================================================
MIN_SDK=24

if [ "$sdk_version" -lt "$MIN_SDK" ]; then
    printf '[!] FATAL: Android 7.0 (API %d) or higher required. Current API: %s\n' "$MIN_SDK" "$sdk_version" >&2
    exit 1
fi

printf '[+] Starting ART Smart Maintenance on Android %s (SDK %s)...\n' "$android_version" "$sdk_version"

# ============================================================================
# TEMP FILE & STATE MANAGEMENT VARIABLES
# ============================================================================

# Android systems have /data/local/tmp available; ensures temp files go to writable location
export TMPDIR=/data/local/tmp

# Validate that TMPDIR exists and is actually writable
if ! [ -d "$TMPDIR" ] || ! [ -w "$TMPDIR" ]; then
    printf '[!] FATAL: Temporary directory '\''%s'\'' is missing or not writable. Aborting.\n' "$TMPDIR" >&2
    exit 1
fi

# Absolute path to this script's directory (locked with readonly to prevent tampering)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly SCRIPT_DIR

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
    # If the script exits before reaching the end, save an early exit snapshot
    if [ "$SUCCESSFUL_RUN" -eq 0 ] && [ -n "${CURRENT_RUN_STATE:-}" ] && [ -f "$CURRENT_RUN_STATE" ] && [ -s "$CURRENT_RUN_STATE" ]; then
        cp "$CURRENT_RUN_STATE" "${SCRIPT_DIR}/.early_exit" 2>/dev/null || true
    fi

    # Move error tempfile to final log if errors exist and run wasn't successful
    if [ "$SUCCESSFUL_RUN" -eq 0 ] && [ -n "${ERROR_TMPFILE:-}" ] && [ -f "$ERROR_TMPFILE" ] && [ -s "$ERROR_TMPFILE" ]; then
        mv "$ERROR_TMPFILE" "$ERROR_LOG" 2>/dev/null || true
    fi

    # Remove all temporary files that STILL EXIST on disk
    for tmpfile in "${CURRENT_RUN_STATE:-}" "${STAGE_STATS:-}" "${STAGE_MERGED:-}" "${ERROR_TMPFILE:-}"; do
        # Skip empty variable strings or files that have already been moved/removed
        if [ -n "$tmpfile" ] && [ -e "$tmpfile" ]; then
            if ! rm -f "$tmpfile" 2>/dev/null; then
                printf '    [!] Warning: Failed to clean up %s\n' "$tmpfile" >&2
            fi
        fi
    done
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

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '[!] FATAL: Another instance is already running (Lock exists). Aborting.\n' >&2
    exit 1
fi

# Set the EXIT trap to remove the lock and run the cleanup function
trap 'rmdir "$LOCK_DIR" 2>/dev/null; cleanup' EXIT

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
    # Attempt 1: dumpsys hardware_properties (Best for root, often denied for ADB)
    if command -v dumpsys >/dev/null 2>&1; then
        out=$(dumpsys hardware_properties 2>/dev/null || true)
        if [ -n "$out" ]; then
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

        # Attempt 2: dumpsys battery (Accessible to ADB/shell user!)
        # Battery temperature is in tenths of a degree (e.g. 350 = 35.0 C)
        bat_temp=$(dumpsys battery 2>/dev/null | awk '/temperature:/ {print int($2 / 10); exit}')
        if [ -n "$bat_temp" ] && [ "$bat_temp" -gt 0 ]; then
            printf '%s\n' "$bat_temp"
            return 0
        fi
    fi

    # Fallback: sysfs (Good for root, fails for ADB due to Android SELinux rules)
    for f in /sys/class/thermal/thermal_zone*/temp; do
        [ -r "$f" ] || continue
        val=$(<"$f") 2>/dev/null || continue

        [ -z "$val" ] && continue
        case "$val" in *[!0-9]*) continue ;; esac

        if [ "$val" -gt 1000 ]; then
            printf '%d\n' $((val / 1000))
        else
            printf '%s\n' "$val"
        fi
        return 0
    done

    printf 'N/A\n'
}

# ============================================================================
# FUNCTION: get_memory_pressure()
# Purpose: Calculate memory pressure as percentage of used memory directly via awk
# Returns: Percentage (0-100), or "N/A" if unavailable
# ============================================================================
get_memory_pressure() {
    # Memory info is available in /proc/meminfo on all Linux systems
    if [ -r /proc/meminfo ]; then
        # Extract MemAvailable and MemTotal, calculate percentage, and print directly
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
        printf 'N/A\n'
    fi
}

# ============================================================================
# FUNCTION: get_battery_level()
# Purpose: Read current battery percentage from sysfs
# Returns: Battery percentage, or "N/A" if unavailable
# ============================================================================
get_battery_level() {
    # Most Android devices expose battery capacity at this sysfs path
    if [ -f /sys/class/power_supply/battery/capacity ]; then
        cap=$(</sys/class/power_supply/battery/capacity) 2>/dev/null
        [ -n "$cap" ] && echo "$cap" || echo "N/A"
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
    else
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
        # Extract integer part (before decimal point)
        int_mem="${memory%.*}"
        int_mem="${int_mem:-0}"
        # Critical: > 99% (virtually no free memory)
        [ "$int_mem" -gt 99 ] && {
            printf '[!] Memory:   %s%% (HIGH)\n' "$memory"
            return 1
        }
        # Moderate: > 85% (significant pressure, may cause slowdowns)
        [ "$int_mem" -gt 85 ] && printf '[!] Memory:   %s%% (MODERATE)\n' "$memory" || printf '[*] Memory:   %s%% (OK)\n' "$memory"
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
    [ -z "$pkg_list" ] && return 0

    # Count total packages for progress reporting
    total_pkgs=0
    set -f # Disable glob expansion (wildcards won't expand)
    OLD_IFS="$IFS"
    IFS='
' # Split on newlines only
    for item in $pkg_list; do
        # Strip trailing CR if present
        item="${item%"$CR"}"
        [ -n "$item" ] && total_pkgs=$((total_pkgs + 1))
    done
    IFS="$OLD_IFS"
    set +f # Re-enable glob expansion

    # ========================================================================
    # STAGE 1: Extract file paths and get stat metadata
    # ========================================================================
    # Parse package list, extract file paths/dirs, deduplicate inline, and run stat
    printf '%s\n' "$pkg_list" | awk '{
        line = $0
        idx = 0
        
        # Find the last occurrence of "=" to separate the file path from the package name
        # (Formats look like: /path/to/base.apk=com.example.app)
        for (i = length(line); i > 0; i--) {
            if (substr(line, i, 1) == "=") {
                idx = i
                break
            }
        }
        
        if (idx > 0) {
            # Extract the file path
            path = substr(line, 1, idx - 1)
            
            # Security sanity check: skip malformed paths, null bytes, newlines, or excessive lengths
            if (path ~ /[\r\n\0]/ || length(path) > 1024) next
            
            # Inline deduplication
            if (!seen[path]++) print path
            
            # Extract parent directory cleanly using regex match and RLENGTH
            if (match(path, /.*\//)) {
                dir = substr(path, 1, RLENGTH - 1)
                
                if (dir ~ /[\r\n\0]/ || length(dir) > 1024) next
                
                if (!seen[dir]++) print dir
            }
        }
    }' | xargs -r stat -c "%n=%Y:%s" 2>/dev/null >"$STAGE_STATS"
    # Batches the unique paths into a single efficient 'stat' call.
    # Stat Format Mapping (%n=%Y:%s):
    #   %n = File path
    #   %Y = Time of last data modification (epoch seconds)
    #   %s = Total size in bytes

    # ========================================================================
    # STAGE 2: Match packages to stat metadata (change detection setup)
    # ========================================================================

    # Read the stat data into memory and merge with package information
    printf '%s\n' "$pkg_list" | awk -v sf="$STAGE_STATS" '
        BEGIN {
            # Load stat cache into memory for fast lookups
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
            
            # Extract path and package name by splitting on last "="
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
                
                # Look up stat data for this path
                meta = stats[path]
                if (meta == "") {
                    # Fallback: try looking up parent directory metadata
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
                
                # Output merged data: package|path|metadata
                print pkg "|" path "|" meta
            }
        }
    ' >"$STAGE_MERGED"

    # ========================================================================
    # STAGE 3: Process each package (with change detection)
    # ========================================================================
    current=0 # Progress counter

    # Read the merged data line by line
    while IFS='|' read -r pkg_name apk_path file_meta; do
        current=$((current + 1))
        [ -z "$pkg_name" ] && continue # Skip empty entries

        # Sanity check: ensure package name contains no whitespace
        case "$pkg_name" in
        *[\ \	]*)
            echo "    [!] Skipping package with whitespace in name: $pkg_name" >&2
            continue
            ;;
        esac

        # Determine compile mode based on package location
        compile_mode="$default_mode"
        if [ "$default_mode" = "system" ]; then
            # System packages installed in /data/ are third-party updates
            if [ "$apk_path" != "${apk_path#/data/}" ]; then
                # Parameter expansion: if path starts with /data/, strip it
                # If it did start with /data/, the result would be shorter
                compile_mode="speed-profile" # Use speed-profile for Play Store updates
            else
                compile_mode="speed" # Use full speed compilation for core system
            fi
        fi

        # Create a fingerprint to detect if this package has changed since last run
        fingerprint="${pkg_name}:${apk_path}:${file_meta}"
        echo "$fingerprint" >>"$CURRENT_RUN_STATE"

        # Check if this exact package was already processed in a previous run
        # PREV_STATE contains all fingerprints from the last successful run
        case "$PREV_STATE" in
        *"
$fingerprint
"*)
            # Package hasn't changed, skip recompilation
            echo "    [~] ($current/$total_pkgs) Skipping unchanged: $pkg_name"
            continue
            ;;
        esac

        # ====================================================================
        # COMPILATION: Execute appropriate compilation mode
        # ====================================================================
        if [ "$compile_mode" = "speed" ]; then
            # Full ahead-of-time (AOT) compilation for maximum performance
            printf '    [+] (%d/%d) Core system compile (-m speed): %s\n' "$current" "$total_pkgs" "$pkg_name"
            actual_mode="speed"
        elif [ "$default_mode" = "system" ]; then
            # Profile-guided optimization for Play Store System App updates
            printf '    [-] (%d/%d) Play Store update compile (-m speed-profile): %s\n' "$current" "$total_pkgs" "$pkg_name"
            actual_mode="speed-profile"
        else
            # Profile-guided optimization for user-installed third-party apps
            printf '    [+] (%d/%d) User app compile (-m speed-profile): %s\n' "$current" "$total_pkgs" "$pkg_name"
            actual_mode="speed-profile"
        fi

        # Attempt compilation and capture output/exit status safely in one clean step
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
FREE_KB=$(df -k /data 2>/dev/null | awk '/\/data/ {print $(NF-2)}')
if [ -n "$FREE_KB" ] && [ "$FREE_KB" -lt 512000 ]; then
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
    PREV_STATE="
$(<"$STATE_FILE")
"
fi

# ============================================================================
# STEP 1: Cache Trimming
# ============================================================================
printf '[+] Step 1: Trimming system and app caches...\n'
STEP1_START=$(date +%s)

# Tell package manager to clean app caches
# Argument 100G indicates target cache size (aggressively frees everything)
pm trim-caches 100G >/dev/null 2>&1

# Calculate elapsed time for this step
STEP1_DURATION=$(($(date +%s) - STEP1_START))
printf '[+] Cache trim finished in %ss.\n' "$STEP1_DURATION"

# ============================================================================
# STEP 2: System Package Optimization
# ============================================================================
printf '[+] Step 2: Smart-optimizing system packages...\n'
STEP2_START=$(date +%s)

# List all system packages (-s flag) with full paths (-f flag)
# Added 2>/dev/null to catch command errors silently
system_package_list=$(pm list packages -f -s 2>/dev/null | sed -e 's/^package://' -e 's/\r$//')

# Validate that we actually got a package list before processing
if [ -z "$system_package_list" ]; then
    printf '    [!] WARNING: System package list is empty or '\''pm'\'' failed. Skipping system stage.\n'
    STEP2_DURATION=0
    SYSTEM_PKGS_COUNT=0
else
    # Compile system packages with appropriate mode (speed for core, speed-profile for updates)
    process_packages "$system_package_list" "system"
    STEP2_DURATION=$(($(date +%s) - STEP2_START))
    printf '[+] System package optimization finished in %ss.\n' "$STEP2_DURATION"
fi

# ============================================================================
# STEP 3: User App Optimization
# ============================================================================
printf '[+] Step 3: Smart-optimizing user apps...\n'
STEP3_START=$(date +%s)

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

# ============================================================================
# POST-OPTIMIZATION: State Management
# ============================================================================
# Update persistent state file only if fingerprints changed
# Avoids unnecessary disk writes when nothing changed
if [ -r "$STATE_FILE" ] && cmp -s "$CURRENT_RUN_STATE" "$STATE_FILE"; then
    printf '[+] State unchanged. Persistent state file left untouched.\n'
else
    # Move temporary state file to persistent location
    if mv "$CURRENT_RUN_STATE" "$STATE_FILE"; then
        printf '[+] Persistent state file updated.\n'
    else
        printf '[!] WARNING: Failed to update persistent state file\n' >&2
    fi
fi

# Move error tempfile to final log only if errors exist
if [ -s "$ERROR_TMPFILE" ]; then
    mv "$ERROR_TMPFILE" "$ERROR_LOG"
else
    rm -f "$ERROR_TMPFILE"
fi

# ============================================================================
# FINAL REPORT
# ============================================================================
# Mark the run as fully successful
SUCCESSFUL_RUN=1

TOTAL_SCANNED=$((SYSTEM_PKGS_COUNT + USER_PKGS_COUNT))
TOTAL_SKIPPED=$((TOTAL_SCANNED - TOTAL_COMPILED))

# Calculate total execution time
TOTAL_DURATION=$(($(date +%s) - TOTAL_START_TIME))

# Prepare error notice if errors were logged
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
EOF
```
<!-- SCRIPT_END -->

</details>

### 4. Run the script

Execute the newly saved script using `sh`:
```bash
sh /sdcard/monthly/maintenance.sh
```

*If you receive a `permission denied` error, ensure you are running the command within the `adb shell` environment, not your local computer terminal.*

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

Because this script utilizes a zero-fork architecture and includes thermal safeguards, it is incredibly lightweight and safe to run in the background. You can easily hook this script into automation apps like **Tasker** or **MacroDroid** using a "Run Shell" action (with root or ADB Wi-Fi privileges) to keep your device optimized on a set schedule while it charges overnight.

*Note: For non-rooted devices, automation apps generally require the `WRITE_SECURE_SETTINGS` permission to be granted via ADB before they can execute background shell commands.*

## License

This project is free and unencumbered software released into the public domain under [The Unlicense](LICENSE). For more information, please refer to <http://unlicense.org/>
