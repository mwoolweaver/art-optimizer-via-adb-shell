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
USER_ID=$(id -u 2>/dev/null || printf '9999')
if [ "$USER_ID" -ne 0 ] && [ "$USER_ID" -ne 2000 ]; then
    printf '[!] FATAL: Elevated privileges required (root or adb shell). Aborting.\n' >&2
    exit 1
fi
BOOT_WAIT_ELAPSED=0
while [ $BOOT_WAIT_ELAPSED -lt 300 ]; do
    [ "$(getprop sys.boot_completed)" = "1" ] && break
    sleep 2
    BOOT_WAIT_ELAPSED=$((BOOT_WAIT_ELAPSED + 2))
done
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
MIN_SDK=24
if [ "$sdk_version" -lt "$MIN_SDK" ]; then
    printf '[!] FATAL: Android 7.0 (API %d) or higher required. Current API: %s\n' "$MIN_SDK" "$sdk_version" >&2
    exit 1
fi
printf '[+] Starting ART Smart Maintenance on Android %s (SDK %s)...\n' "$android_version" "$sdk_version"
export TMPDIR=/data/local/tmp
if ! [ -d "$TMPDIR" ] || ! [ -w "$TMPDIR" ]; then
    printf '[!] FATAL: Temporary directory '\''%s'\'' is missing or not writable. Aborting.\n' "$TMPDIR" >&2
    exit 1
fi
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly SCRIPT_DIR
if ! [ -w "$SCRIPT_DIR" ]; then
    printf '[!] FATAL: Script directory '\''%s'\'' is not writable. Aborting.\n' "$SCRIPT_DIR" >&2
    exit 1
fi
STATE_FILE="${SCRIPT_DIR}/.last_optimized"
readonly STATE_FILE
ERROR_LOG="${SCRIPT_DIR}/compile_errors.log"
readonly ERROR_LOG
cleanup() {
    if [ "$SUCCESSFUL_RUN" -eq 0 ] && [ -n "${CURRENT_RUN_STATE:-}" ] && [ -f "$CURRENT_RUN_STATE" ] && [ -s "$CURRENT_RUN_STATE" ]; then
        cp "$CURRENT_RUN_STATE" "${SCRIPT_DIR}/.early_exit" 2>/dev/null || true
    fi
    if [ "$SUCCESSFUL_RUN" -eq 0 ] && [ -n "${ERROR_TMPFILE:-}" ] && [ -f "$ERROR_TMPFILE" ] && [ -s "$ERROR_TMPFILE" ]; then
        mv "$ERROR_TMPFILE" "$ERROR_LOG" 2>/dev/null || true
    fi
    for tmpfile in "${CURRENT_RUN_STATE:-}" "${STAGE_STATS:-}" "${STAGE_MERGED:-}" "${ERROR_TMPFILE:-}"; do
        if [ -n "$tmpfile" ] && [ -e "$tmpfile" ]; then
            if ! rm -f "$tmpfile" 2>/dev/null; then
                printf '    [!] Warning: Failed to clean up %s\n' "$tmpfile" >&2
            fi
        fi
    done
}
trap 'printf "\n    [!] Interrupted by user (SIGINT). Cleaning up...\n"; exit 130' INT
trap 'printf "\n    [!] Terminated by system (SIGTERM). Cleaning up...\n"; exit 143' TERM
LOCK_DIR="${TMPDIR}/art_maintenance.lock"
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
            printf '%s\n' "$bat_temp"
            return 0
        fi
    fi
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
get_memory_pressure() {
    if [ -r /proc/meminfo ]; then
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
    [ -z "$pkg_list" ] && return 0
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
if [ -n "$FREE_KB" ] && [ "$FREE_KB" -lt 512000 ]; then
    printf '[!] FATAL: Insufficient storage on /data (%d MB available, 500 MB required). Aborting.\n' "$((FREE_KB / 1024))" >&2
    exit 1
fi
CURRENT_RUN_STATE=$(mktemp "${TMPDIR}/opt_state.$$.XXXXXX")
STAGE_STATS=$(mktemp "${TMPDIR}/opt_stats.$$.XXXXXX")
STAGE_MERGED=$(mktemp "${TMPDIR}/opt_merged.$$.XXXXXX")
ERROR_TMPFILE=$(mktemp "${TMPDIR}/errors.$$.XXXXXX")
if [ -z "$CURRENT_RUN_STATE" ] || [ -z "$STAGE_STATS" ] || [ -z "$STAGE_MERGED" ] || [ -z "$ERROR_TMPFILE" ]; then
    printf '[!] FATAL: Failed to create temporary state files in %s. Aborting.\n' "$TMPDIR" >&2
    exit 1
fi
PREV_STATE=""
if [ -r "$STATE_FILE" ]; then
    PREV_STATE="
$(<"$STATE_FILE")
"
fi
printf '[+] Step 1: Trimming system and app caches...\n'
STEP1_START=$(date +%s)
pm trim-caches 100G >/dev/null 2>&1
STEP1_DURATION=$(($(date +%s) - STEP1_START))
printf '[+] Cache trim finished in %ss.\n' "$STEP1_DURATION"
printf '[+] Step 2: Smart-optimizing system packages...\n'
STEP2_START=$(date +%s)
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
