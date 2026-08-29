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

<!-- START_MINIFIED -->

<!-- END_MINIFIED -->

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
