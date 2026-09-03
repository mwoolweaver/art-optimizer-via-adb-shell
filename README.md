[![Gatekeeper](https://github.com/mwoolweaver/art-optimizer-via-adb-shell/actions/workflows/gatekeeper.yml/badge.svg?branch=main)](https://github.com/mwoolweaver/art-optimizer-via-adb-shell/actions/workflows/gatekeeper.yml)
[![ART Maintenance Tests](https://github.com/mwoolweaver/art-optimizer-via-adb-shell/actions/workflows/art-maintenance-tests.yml/badge.svg?branch=main)](https://github.com/mwoolweaver/art-optimizer-via-adb-shell/actions/workflows/art-maintenance-tests.yml)
[![Update README](https://github.com/mwoolweaver/art-optimizer-via-adb-shell/actions/workflows/update-readme.yml/badge.svg?branch=main)](https://github.com/mwoolweaver/art-optimizer-via-adb-shell/actions/workflows/update-readme.yml)
[![Android API](https://img.shields.io/badge/Android-7.0%2B%20%28API%2024%2B%29-green.svg)](https://developer.android.com)
[![License: Unlicense](https://img.shields.io/badge/License-Unlicense-blue.svg)](https://unlicense.org/)
![Shell](https://img.shields.io/badge/Shell-MirBSD_ksh_R59-3DDC84?logo=android&logoColor=white)
![Utilities](https://img.shields.io/badge/Utilities-Toybox_0.8.14-blue)

# ART Optimizer via ADB Shell

A shell script that automates Android ART cache trimming and package optimization, written directly to the device via a heredoc from an ADB shell.

## Overview & Features

This script performs Android package-manager cache trimming and ART package compilation while using persistent package fingerprints to avoid redundant compilation work. Depending on the device, Android version, package state, and usage patterns, the practical performance impact may vary.

* **No File Transfers:** Use the heredoc provided below to create the script directly on the device from an ADB shell, without `adb push`.
* **Ultra-Lean Execution:** Tuned for Android's MirBSD ksh and Toybox environment, minimizing unnecessary subprocesses, parsing, disk I/O, and persistent writes on performance-sensitive paths.
* **Smart Compilation:** Tracks package APK metadata with persistent fingerprints and skips unchanged packages, reducing unnecessary compilation, CPU work, I/O, and thermal load.
* **System Safeguards:** Checks thermal conditions and memory pressure before and after maintenance, aborting on critical conditions. Battery level is reported for visibility, and available `/data` storage is validated before compilation.
* **Dry-Run Support:** Simulate the maintenance workflow without compiling packages or modifying persistent state.
* **System-Only Mode:** Skip user/third-party packages with `--no-user` while using a dedicated system-only state cache.
* **Debug Diagnostics:** Enable verbose diagnostic output with `--debug` for troubleshooting and validation.

## Prerequisites

Before running the script, ensure your environment meets the following requirements:

1. **Android Device Requirements:**
   * **Android Version:** Android 7.0+ (API Level 24+).
   * **Developer Options:** Enable **USB Debugging** or, on Android 11+, **Wireless Debugging**.
   * **Available Storage:** At least **500 MB** of free space on `/data`. The script checks this before package compilation.

2. **Host Machine Setup:**
   * **Terminal Access:** A command-line terminal on macOS, Linux, or Windows (PowerShell/WSL).
   * **ADB (Android Debug Bridge):** Android Platform Tools installed and accessible through your system `$PATH`.

3. **Execution Environment:**
   * **Shell Privileges:** Standard `adb shell` access (UID 2000) or `root` (UID 0).
   * **Script Location:** This README uses `/sdcard/monthly/` as the persistent script location. Real runs require the directory containing the script to be writable for state and diagnostic files.
   * **Temporary Directory:** Temporary working files default to `/data/local/tmp/` through `$TMPDIR`, which must exist and be writable.

## Usage

### 1. Connect to your device

Connect your host machine to your Android device using the method supported by your Android version.

* **Android 7.0 – 10**

  Connect by USB with **USB Debugging** enabled.

  Optional: switch ADB to TCP/IP mode after the initial USB connection:

  ```bash
  adb tcpip 5555
  # Disconnect USB, then connect over Wi-Fi:
  adb connect <IP_ADDRESS>:5555
  ```

* **Android 11+**

  Enable **Wireless Debugging** in Developer Options and connect over Wi-Fi:

  ```bash
  # First-time pairing:
  adb pair <IP_ADDRESS>:<PAIRING_PORT>

  # Connect using the connection port shown by Android:
  adb connect <IP_ADDRESS>:<CONNECTION_PORT>
  ```

> **Verification:** Run `adb devices`. If the device status is `unauthorized`, accept the RSA authorization prompt on the device.

### 2. Open an ADB shell and create the script directory

```bash
adb shell
mkdir -p /sdcard/monthly/
```

> **Why `/sdcard/monthly/`?**
> It provides a convenient persistent location for the script and its state files, while `/data/local/tmp/` is reserved for temporary working files. Exact persistence behavior across reboots or system updates can vary by device and update process.

### 3. Write the script using a heredoc

Expand the section below, paste the block into your terminal, and press **Enter** to save `maintenance.sh` directly to the device.

<!-- NOTE: Do not remove SCRIPT_START and SCRIPT_END comments below.
     They are used by update-readme.yml to auto-inject maintenance.sh -->

<details>
<summary><b>Click to Expand Heredoc</b></summary>

<!-- SCRIPT_START -->
```bash

```
<!-- SCRIPT_END -->

</details>

### 4. Run the script

Execute the script by passing it explicitly to `sh`:

```bash
sh /sdcard/monthly/maintenance.sh
```

> **Note:** Running the script through `sh` allows the shell interpreter to read it directly even when `/sdcard/` is mounted with `noexec`.

### Command-Line Options

```text
--dry-run   Simulate maintenance without compiling packages or modifying persistent state.
--debug     Enable verbose diagnostic output.
--no-user   Skip user/third-party app optimization and use the system-only state cache.
--help      Display built-in usage information.
```

Examples:

```bash
sh /sdcard/monthly/maintenance.sh --dry-run
sh /sdcard/monthly/maintenance.sh --debug
sh /sdcard/monthly/maintenance.sh --no-user
sh /sdcard/monthly/maintenance.sh --debug --dry-run
```

The same modes can also be enabled through environment variables:

```text
DEBUG=0|1
DRY_RUN=0|1
NO_USER=0|1
```

### Example Output

Output varies by device, Android version, package set, thermal source, and whether packages have changed. A typical cached run may look like:

```text
    [~] (116/117) Skipping unchanged: com.wireguard.android
    [~] (117/117) Skipping unchanged: org.videolan.vlc
[+] User app optimization finished in 1s.

    ─────────────────────────────────
    FINAL STATUS
    ─────────────────────────────────
[*] Thermal:  Status 0 (OK)
[!] Memory:   88% (MODERATE)
[*] Battery:  57%
    ─────────────────────────────────

[+] State unchanged. Persistent state file left untouched.

==========================================
[+] Maintenance Summary:
    - Step 1 (Cache Trim):       2s
    - Step 2 (System Stage):     1s
    - Step 3 (User Stage):       1s
    --------------------------------------
    - Grand Total:               4s
    - Packages Compiled:         0
    - Packages Skipped (Cached): 483
    - Packages Failed:           0
    - Packages Invalid:          0
    - Total Scanned:             483
    - Persistent state:          Complete state current.
==========================================
```


> **Note:**  On devices where Android's thermal-status API is unavailable, the script may display a Celsius temperature instead.

## 💡 Pro-Tip: Automation

The script is designed to support unattended automation because it performs pre-flight health checks, avoids redundant package compilation, and prevents concurrent runs. Device-specific behavior still varies, so schedule it conservatively—ideally while the device is idle and, if practical, charging.

### Command by Setup Type

* **Rooted Devices:**

  Use a standard **Run Shell** action with **Use Root** enabled:

  ```bash
  sh /sdcard/monthly/maintenance.sh
  ```

* **Non-Rooted Devices:**

  Use an automation tool capable of executing commands with ADB shell privileges, such as Tasker's **ADB WiFi** functionality or MacroDroid's **ADB Shell Command** action:

  ```bash
  sh /sdcard/monthly/maintenance.sh
  ```

> **Note for Non-Rooted Automation:**
> Non-rooted automation requires ADB shell privileges. On Android 11+, automation tools may be able to simplify Wireless Debugging pairing or reconnection, but behavior depends on the Android build, device vendor, and app configuration. On Android 7–10, ADB TCP/IP mode generally needs to be enabled again after a reboot with `adb tcpip 5555`.

## License

This project is free and unencumbered software released into the public domain under [The Unlicense](LICENSE). For more information, see <https://unlicense.org/>.
