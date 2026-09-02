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
cat << 'EOF' > /sdcard/monthly/minification-maintenance.sh
#!/system/bin/sh
set -u # Exit immediately if any variable is unset
umask 077
export LC_ALL=C
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
for setting in DEBUG DRY_RUN NO_USER; do
    case "$setting" in
    DEBUG) setting_value="$DEBUG" ;;
    DRY_RUN) setting_value="$DRY_RUN" ;;
    NO_USER) setting_value="$NO_USER" ;;
    esac
    case "$setting_value" in
    0 | 1)
        ;;
    *)
        printf '[!] FATAL: %s must be 0 or 1 (received: %s).\n\n' \
            "$setting" "$setting_value"
        show_help
        exit 1
        ;;
    esac
done
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
        printf '[!] FATAL: Unknown option: %s\n\n' "$arg"
        show_help
        exit 1
        ;;
    esac
done
debug_print() {
    if [ "$DEBUG" -eq 1 ]; then
        echo "[DEBUG] $1"
    fi
}
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
SCRIPT_UID=${USER_ID:-1}
debug_print "Checked user ID: $SCRIPT_UID"
if [ "$SCRIPT_UID" -ne 0 ] && [ "$SCRIPT_UID" -ne 2000 ]; then
    echo "[!] FATAL: Elevated privileges required (root or adb shell). Aborting."
    exit 1
fi
BOOT_WAIT_ELAPSED=0
while [ $BOOT_WAIT_ELAPSED -lt 300 ]; do
    [ "$(getprop sys.boot_completed)" = "1" ] && break
    sleep 2
    BOOT_WAIT_ELAPSED=$((BOOT_WAIT_ELAPSED + 2))
    debug_print "Waiting for boot completion... elapsed: ${BOOT_WAIT_ELAPSED}s"
done
if [ "$(getprop sys.boot_completed)" != "1" ]; then
    echo "[!] FATAL: Device failed to report boot completion after 300 seconds. Aborting."
    exit 1
fi
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
check_deps
case "$(service check package 2>/dev/null)" in
*"not found"* | "")
    echo "[!] FATAL: Package manager service is not running or unresponsive. Aborting."
    exit 1
    ;;
esac
TOTAL_START_TIME=$SECONDS
android_version=$(getprop ro.build.version.release 2>/dev/null)
sdk_version=$(getprop ro.build.version.sdk 2>/dev/null)
android_version="${android_version:-Unknown}"
sdk_version="${sdk_version:-0}"
debug_print "Detected Android version: $android_version (SDK: $sdk_version)"
MIN_SDK=24
if [ "$sdk_version" -lt "$MIN_SDK" ]; then
    echo "[!] FATAL: Android 7.0 (API $MIN_SDK) or higher required. Current API: $sdk_version"
    exit 1
fi
if [ "$DRY_RUN" -eq 1 ]; then
    echo "[+] Starting ART Smart Maintenance (DRY RUN) on Android $android_version (SDK $sdk_version)..."
else
    echo "[+] Starting ART Smart Maintenance on Android $android_version (SDK $sdk_version)..."
fi
export TMPDIR="${TMPDIR:-/data/local/tmp}"
debug_print "Set TMPDIR to $TMPDIR"
if ! [ -d "$TMPDIR" ] || ! [ -w "$TMPDIR" ]; then
    echo "[!] FATAL: Temporary directory $TMPDIR is missing or not writable. Aborting."
    exit 1
fi
case "$0" in
*/*) SCRIPT_DIR="$(cd "${0%/*}" && pwd)" ;;
*) SCRIPT_DIR="$(pwd)" ;;
esac
readonly SCRIPT_DIR
debug_print "Resolved SCRIPT_DIR to $SCRIPT_DIR"
if ! [ -w "$SCRIPT_DIR" ]; then
    echo "[!] FATAL: Script directory $SCRIPT_DIR is not writable. Aborting."
    exit 1
fi
FULL_STATE_FILE="${SCRIPT_DIR}/.last_optimized"
NO_USER_STATE_FILE="${SCRIPT_DIR}/.last_optimized_system"
readonly FULL_STATE_FILE NO_USER_STATE_FILE
if [ "$NO_USER" -eq 1 ]; then
    STATE_FILE="$NO_USER_STATE_FILE"
else
    STATE_FILE="$FULL_STATE_FILE"
fi
readonly STATE_FILE
ERROR_LOG="${SCRIPT_DIR}/compile_errors.log"
readonly ERROR_LOG
RUN_ERROR_LOG="${SCRIPT_DIR}/maintenance_errors.log"
readonly RUN_ERROR_LOG
SUCCESSFUL_RUN=0
cleanup() {
    debug_print "Executing cleanup handler (SUCCESSFUL_RUN=$SUCCESSFUL_RUN)..."
    if [ "${DRY_RUN:-0}" -eq 0 ]; then
        if [ "$SUCCESSFUL_RUN" -eq 0 ]; then
            if [ -n "${CURRENT_RUN_STATE:-}" ] &&
                [ -f "$CURRENT_RUN_STATE" ] &&
                [ -s "$CURRENT_RUN_STATE" ]; then
                debug_print "Saving latest failed-run snapshot to: ${SCRIPT_DIR}/.early_exit"
                if ! cp "$CURRENT_RUN_STATE" "${SCRIPT_DIR}/.early_exit" 2>/dev/null; then
                    report_error "    [!] Warning: Failed to save early exit snapshot to ${SCRIPT_DIR}/.early_exit"
                fi
            elif [ -f "${SCRIPT_DIR}/.early_exit" ]; then
                debug_print "Removing stale early-exit snapshot: ${SCRIPT_DIR}/.early_exit"
                if ! rm -f "${SCRIPT_DIR}/.early_exit" 2>/dev/null; then
                    report_error "    [!] Warning: Failed to remove stale early exit snapshot ${SCRIPT_DIR}/.early_exit"
                fi
            fi
        else
            if [ -f "${SCRIPT_DIR}/.early_exit" ]; then
                debug_print "Removing stale early-exit snapshot: ${SCRIPT_DIR}/.early_exit"
                if ! rm -f "${SCRIPT_DIR}/.early_exit" 2>/dev/null; then
                    report_error "    [!] Warning: Failed to remove stale early exit snapshot ${SCRIPT_DIR}/.early_exit"
                fi
            fi
        fi
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
    if [ -n "${RUN_ERROR_TMPFILE:-}" ] && [ -e "$RUN_ERROR_TMPFILE" ]; then
        debug_print "Cleaning up maintenance error tempfile: $RUN_ERROR_TMPFILE"
        if ! rm -f "$RUN_ERROR_TMPFILE" 2>/dev/null; then
            printf '    [!] Warning: Failed to clean up %s\n' \
                "$RUN_ERROR_TMPFILE" >&2
        fi
    fi
    if [ -n "${LOCK_DIR:-}" ] && [ -d "$LOCK_DIR" ]; then
        debug_print "Releasing concurrency lock at $LOCK_DIR"
        if ! rmdir "$LOCK_DIR" 2>/dev/null; then
            lock_error="    [!] CRITICAL: Failed to release lock at $LOCK_DIR. Manual deletion required."
            printf '%s\n' "$lock_error" >&2
            if [ "${DRY_RUN:-0}" -eq 0 ]; then
                printf '%s\n' "$lock_error" >>"$RUN_ERROR_LOG" 2>/dev/null || true
            fi
        fi
    fi
}
trap 'report_error "    [!] Interrupted by user (SIGINT). Cleaning up..."; exit 130' INT
trap 'report_error "    [!] Terminated by system (SIGTERM). Cleaning up..."; exit 143' TERM
LOCK_DIR="${TMPDIR}/art_maintenance.lock"
debug_print "Acquiring lock directory at $LOCK_DIR"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '[!] FATAL: Another instance is already running (Lock exists). Aborting.\n'
    exit 1
fi
trap 'cleanup' EXIT
RUN_ERROR_TMPFILE=$(mktemp "${TMPDIR}/run_errors.$$.XXXXXX")
if [ -z "$RUN_ERROR_TMPFILE" ] || [ ! -f "$RUN_ERROR_TMPFILE" ]; then
    printf '[!] FATAL: Failed to create maintenance error tempfile in %s. Aborting.\n' \
        "$TMPDIR" >&2
    exit 1
fi
debug_print "Created maintenance error tempfile: $RUN_ERROR_TMPFILE"
SYSTEM_PKGS_COUNT=0
USER_PKGS_COUNT=0
TOTAL_COMPILED=0
TOTAL_SKIPPED=0
TOTAL_FAILED=0
TOTAL_INVALID=0
TOTAL_WOULD_COMPILE=0
STATE_COMMIT_SAFE=1
CR=$(printf '\r')
readonly CR
get_thermal_status() {
    if command -v dumpsys >/dev/null 2>&1; then
        therm_status=""
        therm_status=$(dumpsys thermalservice 2>/dev/null | awk '/^Thermal Status:/ {print $3; exit}')
        if [ -n "$therm_status" ] && [ "$therm_status" -eq "$therm_status" ] 2>/dev/null; then
            debug_print "Parsed global thermal status code: $therm_status"
            printf '%s\n' "$therm_status"
            return 0
        fi
    fi
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
        case "$-" in
        *f*) battery_noglob_was_set=1 ;;
        *) battery_noglob_was_set=0 ;;
        esac
        set -f
        set -- $(dumpsys battery 2>/dev/null)
        if [ "$battery_noglob_was_set" -eq 0 ]; then
            set +f
        fi
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
    for f in /sys/class/thermal/thermal_zone*/temp; do
        [ -r "$f" ] || continue
        val_out=$(<"$f" 2>&1)
        val_exit=$?
        if [ "$val_exit" -ne 0 ]; then
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
get_memory_pressure() {
    if [ -r /proc/meminfo ]; then
        t=""
        a=""
        while read -r key val _rest; do
            case "$key" in
            MemTotal:) t="$val" ;;
            MemAvailable:) a="$val" ;;
            esac
            [ -n "$t" ] && [ -n "$a" ] && break
        done </proc/meminfo
        if [ -n "$t" ] && [ -n "$a" ] && [ "$t" -gt 0 ]; then
            printf '%d\n' "$(((t - a) * 100 / t))"
        else
            printf 'N/A\n'
        fi
    else
        printf 'N/A\n'
    fi
}
get_battery_level() {
    batt_path="/sys/class/power_supply/battery/capacity"
    if [ -f "$batt_path" ]; then
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
print_system_status() {
    label="$1"
    printf '\n    ─────────────────────────────────\n    %s\n    ─────────────────────────────────\n' "$label"
    thermal=$(get_thermal_status)
    if [ "$thermal" = "N/A" ]; then
        printf '[*] Thermal:  %s\n' "$thermal"
    elif [ "$thermal" -le 6 ]; then
        [ "$thermal" -ge 3 ] && {
            printf '[!] Thermal:  Status %d (CRITICAL)\n' "$thermal"
            return 1
        }
        [ "$thermal" -ge 1 ] && printf '[!] Thermal:  Status %d (WARM)\n' "$thermal" || printf '[*] Thermal:  Status %d (OK)\n' "$thermal"
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
        [ "$memory" -gt 99 ] && {
            printf '[!] Memory:   %s%% (HIGH)\n' "$memory"
            return 1
        }
        [ "$memory" -gt 85 ] && printf '[!] Memory:   %s%% (MODERATE)\n' "$memory" || printf '[*] Memory:   %s%% (OK)\n' "$memory"
    fi
    printf '[*] Battery:  %s%%\n    ─────────────────────────────────\n\n' "$(get_battery_level)"
    return 0
}
process_packages() {
    pkg_list="$1"
    default_mode="$2"
    if [ -z "$pkg_list" ]; then
        report_error "    [!] ERROR: Package list for mode '$default_mode' is unexpectedly empty."
        return 1
    fi
    debug_print "Normalizing package list to package|path format..."
    pkg_list="${pkg_list//package:/}"
    pkg_list="${pkg_list//$CR/}"
    normalized_pkg_list=$(
        printf '%s\n' "$pkg_list" |
            awk '
            {
                line = $0
                idx = 0
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
    if [ -z "$pkg_list" ]; then
        report_error "    [!] ERROR: Package list became empty during normalization."
        return 1
    fi
    if [ "$DEBUG" -eq 1 ]; then
        debug_print "===== DEBUG NORMALIZED PACKAGE LIST ====="
        debug_print "Packages: "
        echo "$pkg_list" | wc -l
        debug_print "--- first 10 records ---"
        echo "$pkg_list" | head -n 10
        debug_print "--- end DEBUG NORMALIZED PACKAGE LIST ---"
    fi
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
    if [ "$default_mode" = "system" ]; then
        SYSTEM_PKGS_COUNT="$total_pkgs"
    else
        USER_PKGS_COUNT="$total_pkgs"
    fi
    debug_print "Running STAGE 1: Extracting file paths..."
    STAGE_PATHS="${STAGE_STATS}.paths"
    printf '%s\n' "$pkg_list" |
        awk -F '|' '
        {
            if (NF < 2)
                next
            pkg  = $1
            path = $2
            if (path == "" || length(path) > 1024)
                next
            if (!seen[path]++) {
                print path
            }
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
    if [ ! -s "$STAGE_PATHS" ]; then
        report_error "    [!] ERROR: Stage 1 produced no valid package paths."
        return 1
    fi
    if [ "$DEBUG" -eq 1 ]; then
        debug_print "===== DEBUG STAGE 1 PATHS ====="
        debug_print "Paths: "
        wc -l <"$STAGE_PATHS"
        debug_print "--- first 20 paths ---"
        head -n 20 "$STAGE_PATHS"
        debug_print "--- end DEBUG STAGE 1 PATHS ---"
    fi
    debug_print "Running stat on unique paths..."
    tr '\n' '\0' <"$STAGE_PATHS" |
        xargs -0 -r stat -c '%n=%Y:%s:%i' \
            >"$STAGE_STATS"
    stage1b_exit=$?
    if [ "$stage1b_exit" -ne 0 ]; then
        report_error "    [!] ERROR: Stage 1b stat collection failed (Exit Code: $stage1b_exit)."
        return 1
    fi
    if [ ! -s "$STAGE_STATS" ]; then
        report_error "    [!] ERROR: stat produced no output. Persistent state will not be updated."
        return 1
    fi
    if [ "$DEBUG" -eq 1 ]; then
        STAGE_PATH_COUNT=$(wc -l <"$STAGE_PATHS")
        STAGE_STAT_COUNT=$(wc -l <"$STAGE_STATS")
        debug_print "===== DEBUG STAGE 1b: STAT ACCOUNTING ====="
        debug_print "Unique paths submitted to stat: $STAGE_PATH_COUNT"
        debug_print "Stat records produced:          $STAGE_STAT_COUNT"
        if [ "$STAGE_STAT_COUNT" -ne "$STAGE_PATH_COUNT" ]; then
            debug_print "[!] WARNING: stat record count differs from path count."
            debug_print "    Missing/failed stat records: $((STAGE_PATH_COUNT - STAGE_STAT_COUNT))"
        else
            debug_print "[+] Stat accounting: path count matches stat count."
        fi
        debug_print "--- end DEBUG STAGE 1b ACCOUNTING ---"
    fi
    debug_print "Running STAGE 2: Matching packages to stat metadata..."
    printf '%s\n' "$pkg_list" |
        awk -F '|' -v OFS='|' -v sf="$STAGE_STATS" -v debug="$DEBUG" '
        BEGIN {
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
            meta = stats[path]
            if (meta != "") {
                direct_matches++
            } else {
                dir = path
                sub("/[^/]+/?$", "", dir)
                d_meta = stats[dir]
                if (d_meta != "") {
                    n = split(d_meta, dir_meta, ":")
                    if (n == 3 &&
                        dir_meta[1] ~ /^-?[0-9]+$/ &&
                        dir_meta[2] ~ /^[0-9]+$/ &&
                        dir_meta[3] ~ /^[0-9]+$/) {
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
                if (stat_records == valid_stat_records + invalid_stat_records) {
                    print "[+] Stat accounting verified." > "/dev/stderr"
                } else {
                    printf "[!] WARNING: Stat accounting mismatch: %d != %d + %d\n",
                        stat_records,
                        valid_stat_records,
                        invalid_stat_records > "/dev/stderr"
                }
                if (input_records == accepted_packages + invalid_package_records) {
                    print "[+] Package-input accounting verified." > "/dev/stderr"
                } else {
                    printf "[!] WARNING: Package-input accounting mismatch: %d != %d + %d\n",
                        input_records,
                        accepted_packages,
                        invalid_package_records > "/dev/stderr"
                }
                resolved_packages = direct_matches + directory_fallbacks + unavailable
                if (accepted_packages == resolved_packages) {
                    print "[+] Metadata-resolution accounting verified." > "/dev/stderr"
                } else {
                    printf "[!] WARNING: Metadata-resolution mismatch: %d accepted != %d resolved.\n",
                        accepted_packages,
                        resolved_packages > "/dev/stderr"
                }
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
    if [ ! -s "$STAGE_MERGED" ]; then
        report_error "    [!] ERROR: Stage 2 produced no merged package records."
        return 1
    fi
    if [ "$DEBUG" -eq 1 ]; then
        debug_print "===== DEBUG STAGE 2: STAGE_MERGED ====="
        debug_print "STAGE_MERGED: $STAGE_MERGED"
        debug_print "Merged: "
        wc -l <"$STAGE_MERGED"
        debug_print "--- first 10 records ---"
        head -n 10 "$STAGE_MERGED"
        debug_print "--- end DEBUG STAGE_MERGED ---"
    fi
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
    while IFS='|' read -r pkg_name apk_path file_meta; do
        current=$((current + 1))
        if [ -z "$pkg_name" ]; then
            stage3_invalid=$((stage3_invalid + 1))
            continue
        fi
        case "$pkg_name" in
        *[[:space:]]*)
            echo "    [!] Skipping package with whitespace in name: $pkg_name"
            stage3_invalid=$((stage3_invalid + 1))
            continue
            ;;
        esac
        compile_mode="$default_mode"
        if [ "$default_mode" = "system" ]; then
            if [ "$apk_path" != "${apk_path#/data/}" ]; then
                compile_mode="speed-profile"
            else
                compile_mode="speed"
            fi
        fi
        state_writable=1
        preserved_fingerprint=""
        fingerprint="${pkg_name}|${apk_path}|${file_meta}"
        case "${file_meta}" in
        UNAVAILABLE)
            echo "    [!] ($current/$total_pkgs) Unable to verify metadata: $pkg_name"
            echo "    [+] ($current/$total_pkgs) Treating as changed: $pkg_name"
            stage3_unverified=$((stage3_unverified + 1))
            state_writable=0
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
                    *"|UNAVAILABLE")
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
                stage3_failed=$((stage3_failed + 1))
                if ! printf 'FAIL (%d): %s\n%s\n' \
                    "$compile_exit" "$pkg_name" "$err_output" \
                    >>"$ERROR_TMPFILE" 2>/dev/null; then
                    report_error "    [!] CRITICAL: Failed to write to compile error log! Storage may be full."
                fi
            fi
        fi
    done <"$STAGE_MERGED"
    if [ "$DEBUG" -eq 1 ]; then
        debug_print "===== DEBUG STAGE 3: COMPILATION ====="
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
    exec 3>&-
    TOTAL_COMPILED=$((TOTAL_COMPILED + stage3_compiled))
    TOTAL_WOULD_COMPILE=$((TOTAL_WOULD_COMPILE + stage3_would_compile))
    TOTAL_SKIPPED=$((TOTAL_SKIPPED + stage3_skipped))
    TOTAL_FAILED=$((TOTAL_FAILED + stage3_failed))
    TOTAL_INVALID=$((TOTAL_INVALID + stage3_invalid))
    return 0
}
if ! print_system_status "PRE-FLIGHT CHECK"; then
    report_error "[!] FATAL: Pre-flight system health check failed. Aborting."
    exit 1
fi
FREE_KB=""
prev1=""
prev2=""
case "$-" in
*f*) df_noglob_was_set=1 ;;
*) df_noglob_was_set=0 ;;
esac
set -f
set -- $(df -k /data 2>/dev/null)
if [ "$df_noglob_was_set" -eq 0 ]; then
    set +f
fi
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
CURRENT_RUN_STATE=$(mktemp "${TMPDIR}/opt_state.$$.XXXXXX")
STAGE_STATS=$(mktemp "${TMPDIR}/opt_stats.$$.XXXXXX")
STAGE_MERGED=$(mktemp "${TMPDIR}/opt_merged.$$.XXXXXX")
ERROR_TMPFILE=$(mktemp "${TMPDIR}/errors.$$.XXXXXX")
debug_print "Created temp files: state=$CURRENT_RUN_STATE, stats=$STAGE_STATS, merged=$STAGE_MERGED"
if [ -z "$CURRENT_RUN_STATE" ] || [ -z "$STAGE_STATS" ] || [ -z "$STAGE_MERGED" ] || [ -z "$ERROR_TMPFILE" ]; then
    report_error "[!] FATAL: Failed to create temporary state files in $TMPDIR. Aborting."
    exit 1
fi
PREV_STATE=""
STATE_READ_FILE="$STATE_FILE"
if [ "$NO_USER" -eq 1 ] && [ ! -r "$NO_USER_STATE_FILE" ]; then
    STATE_READ_FILE="$FULL_STATE_FILE"
fi
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
STEP1_START=$SECONDS
if [ "$DRY_RUN" -eq 1 ]; then
    printf '[+] Step 1: (DRY RUN) Would trim system and app caches...\n'
else
    printf '[+] Step 1: Trimming system and app caches...\n'
    trim_out=$(pm trim-caches 99999999999 2>&1)
    trim_exit=$?
    if [ $trim_exit -ne 0 ]; then
        report_error "    [!] WARNING: Cache trim failed (Exit Code: $trim_exit)."
        if [ -n "$trim_out" ]; then
            report_error "        Output: $trim_out"
        fi
    fi
fi
STEP1_DURATION=$((SECONDS - STEP1_START))
printf '[+] Cache trim finished in %ss.\n' "$STEP1_DURATION"
STEP2_START=$SECONDS
if [ "$DRY_RUN" -eq 1 ]; then
    printf '[+] Step 2: (DRY RUN) Smart-optimizing system packages...\n'
else
    printf '[+] Step 2: Smart-optimizing system packages...\n'
fi
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
TOTAL_SCANNED=$((SYSTEM_PKGS_COUNT + USER_PKGS_COUNT))
TOTAL_DURATION=$((SECONDS - TOTAL_START_TIME))
error_notice=""
if [ "$TOTAL_FAILED" -gt 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    error_notice="    - [!] Errors occurred. See $ERROR_LOG"
fi
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
if ! print_system_status "FINAL STATUS"; then
    report_error "    [!] ERROR: Final system health check failed. Persistent state will not be updated."
    printf '==========================================\n'
    exit 1
fi
if [ "$DRY_RUN" -eq 1 ]; then
    printf '[+] Dry-run mode: Persistent state file and error logs were not modified.\n'
elif [ "$STATE_COMMIT_SAFE" -ne 1 ]; then
    report_error "    [!] WARNING: Run was incomplete. Persistent state file was NOT updated."
else
    if [ -r "$STATE_FILE" ] && cmp -s "$CURRENT_RUN_STATE" "$STATE_FILE"; then
        printf '[+] State unchanged. Persistent state file left untouched.\n'
    else
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
                    STATE_COMMIT_SAFE=0
                else
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
if [ "$DRY_RUN" -eq 0 ] &&
    [ "$NO_USER" -eq 0 ] &&
    [ "$STATE_COMMIT_SAFE" -eq 1 ] &&
    [ -f "$NO_USER_STATE_FILE" ]; then
    debug_print "Removing superseded system-only state file: $NO_USER_STATE_FILE"
    if ! rm -f "$NO_USER_STATE_FILE" 2>/dev/null; then
        report_error "    [!] WARNING: Failed to remove superseded system-only state file $NO_USER_STATE_FILE"
    fi
fi
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
if [ "$STATE_COMMIT_SAFE" -ne 1 ]; then
    exit 1
fi
SUCCESSFUL_RUN=1
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
