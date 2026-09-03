[![Gatekeeper](https://github.com/mwoolweaver/art-optimizer-via-adb-shell/actions/workflows/gatekeeper.yml/badge.svg?branch=main)](https://github.com/mwoolweaver/art-optimizer-via-adb-shell/actions/workflows/gatekeeper.yml)
[![ART Maintenance Tests](https://github.com/mwoolweaver/art-optimizer-via-adb-shell/actions/workflows/art-maintenance-tests.yml/badge.svg?branch=main)](https://github.com/mwoolweaver/art-optimizer-via-adb-shell/actions/workflows/art-maintenance-tests.yml)
[![Update README](https://github.com/mwoolweaver/art-optimizer-via-adb-shell/actions/workflows/update-readme.yml/badge.svg?branch=main)](https://github.com/mwoolweaver/art-optimizer-via-adb-shell/actions/workflows/update-readme.yml)
[![License: Unlicense](https://img.shields.io/badge/License-Unlicense-blue.svg)](https://unlicense.org/)
[![Android API](https://img.shields.io/badge/Android-7.0%2B%20%28API%2024%2B%29-green.svg)](https://developer.android.com)
![Tested Shell](https://img.shields.io/badge/Tested_Shell-MirBSD_ksh_R59-3DDC84?logo=android&logoColor=white)
![Tested Utilities](https://img.shields.io/badge/Tested_Utilities-Toybox_0.8.14-blue)

# ART Optimizer via ADB Shell

An ADB shell script that automates Android cache trimming and ART package optimization while avoiding unnecessary recompilation through persistent package fingerprints.

## Overview & Features

The script combines Android Package Manager cache maintenance with scope-aware ART compilation and conservative state handling. It is tuned for Android's MirBSD ksh/Toybox environment and is designed to minimize unnecessary subprocesses, parsing, disk I/O, persistent writes, and repeated compilation work.

* **Smart Incremental Compilation:** Tracks package APK metadata with persistent fingerprints and skips unchanged packages.
* **Scope-Aware Optimization:** Supports full maintenance, system-only maintenance with `--no-user`, and user-only maintenance with `--user-only`.
* **Dedicated State Caches:** Uses independent full, system-only, and user-only state files so a partial run never masquerades as a complete-device state.
* **Compilation Policy:** Preinstalled system packages use `speed`; updated system apps under `/data/` and user apps use `speed-profile`.
* **Dry-Run Support:** `--dry-run` executes the discovery, fingerprinting, accounting, and policy logic without compiling packages or modifying persistent state.
* **Quiet Operation:** `--quiet` suppresses routine per-package progress while retaining warnings, errors, stage output, and the final summary.
* **Forced Recompilation:** `--force` bypasses unchanged-fingerprint skips without changing the normal compilation policy or destroying cached state first.
* **Optional Cache-Trim Bypass:** `--no-trim` skips only the Package Manager cache-trim step; ART package processing continues normally.
* **Battery Policy Gates:** `--require-charging` and `--min-battery` can prevent unattended maintenance from starting under unsuitable power conditions.
* **Standalone Health Checks:** `--health-only` checks thermal state, memory pressure, battery/power policy, and `/data` storage without performing package maintenance.
* **Machine-Readable Automation:** `--json` emits a single JSON summary on stdout and suppresses routine human output; warnings/errors remain on stderr.
* **Debug Diagnostics:** `--debug` enables detailed accounting and pipeline diagnostics. With `--json --debug`, JSON remains clean on stdout while diagnostics are sent to stderr.
* **System Safeguards:** Checks boot completion, Package Manager availability, thermal conditions, memory pressure, and free `/data` space before or during maintenance as appropriate.
* **Transactional State Handling:** State is written only after successful processing, committed atomically, and left untouched when the generated state is identical.
* **Failure Retry Semantics:** Failed compilations are omitted from the new trusted state so they are retried on the next run.
* **Concurrency Protection:** Prevents overlapping maintenance runs from modifying shared state or logs simultaneously.
* **Automated Regression Testing:** GitHub Actions exercises deterministic fixtures, package-pipeline behavior, option integration, state lifecycles, JSON behavior, and failure paths under `mksh`.

## Prerequisites

Before running the script, ensure your environment meets the following requirements:

1. **Android Device Requirements**
   * **Android Version:** Android 7.0+ (API Level 24+).
   * **Developer Options:** Enable **USB Debugging** or, on Android 11+, **Wireless Debugging**.
   * **Available Storage:** At least **500 MB** of free space on `/data`. The script checks this before package compilation.

2. **Host Machine Setup**
   * **Terminal Access:** A command-line terminal on macOS, Linux, or Windows (PowerShell/WSL).
   * **ADB (Android Debug Bridge):** Android Platform Tools installed and accessible through your system `$PATH`.

3. **Execution Environment**
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

The repository README normally contains an expandable heredoc that writes `maintenance.sh` directly to `/sdcard/monthly/`.

> **Note:** The embedded script body is intentionally omitted from this returned README copy. Keep the `SCRIPT_START` and `SCRIPT_END` markers intact so the repository's README-update workflow can inject the current `maintenance.sh`.

<!-- NOTE: Do not remove SCRIPT_START and SCRIPT_END comments below.
     They are used by update-readme.yml to auto-inject maintenance.sh -->

<details>
<summary><b>Click to Expand Heredoc</b></summary>

<!-- SCRIPT_START -->
<!-- Embedded maintenance.sh intentionally omitted from this returned copy. -->
<!-- SCRIPT_END -->

</details>

### 4. Run the script

Execute the script by passing it explicitly to `sh`:

```bash
sh /sdcard/monthly/maintenance.sh
```

> **Note:** Running the script through `sh` allows the shell interpreter to read it directly even when `/sdcard/` is mounted with `noexec`.

## Command-Line Options

```text
--no-user          Skip user/third-party app optimization and use the system-only state cache.
--user-only        Skip system package optimization and use the user-only state cache.
--dry-run          Simulate maintenance without compiling packages or modifying persistent state.
--quiet            Suppress routine per-package progress output.
--force            Recompile selected packages even when their fingerprints are unchanged.
--no-trim          Skip Package Manager cache trimming.
--require-charging Require external power before maintenance begins.
--min-battery N    Require battery level N (0-100) or higher before maintenance begins.
--json             Emit one JSON summary on stdout; suppress routine output; diagnostics stay on stderr.
--health-only      Run health, battery-policy, and storage checks without package maintenance.
--debug            Enable verbose debug output.
--help             Display built-in usage information.
```

`--min-battery=N` is also accepted as a convenience form.

`--no-user` and `--user-only` are mutually exclusive.

The environment-configurable modes remain:

```text
DEBUG=0|1
DRY_RUN=0|1
NO_USER=0|1
```

The newer operational flags are CLI-only.

### Common Examples

Normal full maintenance:

```bash
sh /sdcard/monthly/maintenance.sh
```

Preview what would change without compiling or modifying persistent state:

```bash
sh /sdcard/monthly/maintenance.sh --dry-run
```

Run quietly while preserving the normal summary and warnings:

```bash
sh /sdcard/monthly/maintenance.sh --quiet
```

Optimize only system packages:

```bash
sh /sdcard/monthly/maintenance.sh --quiet --no-user
```

Optimize only user/third-party packages:

```bash
sh /sdcard/monthly/maintenance.sh --quiet --user-only
```

Force recompilation of the selected scope while preserving the normal compile-mode policy:

```bash
sh /sdcard/monthly/maintenance.sh --quiet --force
```

Skip Package Manager cache trimming:

```bash
sh /sdcard/monthly/maintenance.sh --quiet --no-trim
```

Require external power and at least 40% battery:

```bash
sh /sdcard/monthly/maintenance.sh --quiet --require-charging --min-battery 40
```

Run health checks only:

```bash
sh /sdcard/monthly/maintenance.sh --health-only
```

Emit a single machine-readable JSON result:

```bash
sh /sdcard/monthly/maintenance.sh --json
```

Combine JSON output with debug diagnostics:

```bash
sh /sdcard/monthly/maintenance.sh --json --debug
```

## JSON Output

`--json` is intended for automation. On a successful non-debug run, stdout contains exactly one JSON object and routine human-readable output is suppressed. Warnings and errors remain visible on stderr.

Example:

```json
{"success":true,"mode":"maintenance","scope":"full","dry_run":false,"force":false,"cache_trim":true,"require_charging":false,"min_battery_percent":null,"thermal":"status:0","memory_percent":92,"battery_percent":60,"charging":null,"data_free_kb":33985688,"compiled":0,"would_compile":0,"skipped":483,"failed":0,"invalid":0,"scanned":483,"duration_seconds":4,"state":"current"}
```

With `--health-only`, package maintenance is not applicable, so fields such as `scope`, `cache_trim`, and `state` reflect that explicitly:

```json
{"success":true,"mode":"health-only","scope":"none","dry_run":false,"force":false,"cache_trim":null,"require_charging":false,"min_battery_percent":null,"thermal":"status:0","memory_percent":93,"battery_percent":59,"charging":true,"data_free_kb":33875376,"compiled":0,"would_compile":0,"skipped":0,"failed":0,"invalid":0,"scanned":0,"duration_seconds":1,"state":"not-applicable"}
```

For diagnostics without contaminating machine-readable stdout:

```bash
sh /sdcard/monthly/maintenance.sh --json --debug
```

JSON remains on stdout while the human-readable/debug stream is sent to stderr.

## Health and Power Policies

Normal maintenance performs pre-flight health checks and repeats the thermal/memory health check before committing persistent state.

`--health-only` performs health, charging-state, battery-policy, and `/data` storage checks without trimming caches, compiling packages, or modifying persistent package state:

```bash
sh /sdcard/monthly/maintenance.sh --health-only
```

Use the optional power gates for unattended execution:

```bash
sh /sdcard/monthly/maintenance.sh --require-charging
sh /sdcard/monthly/maintenance.sh --min-battery 40
sh /sdcard/monthly/maintenance.sh --require-charging --min-battery=40
```

When one of these policies is requested, the run fails rather than silently bypassing a requirement that cannot be verified or satisfied.

## Persistent State Model

The script keeps scope-specific fingerprint caches next to `maintenance.sh`:

| File | Meaning |
| --- | --- |
| `.last_optimized` | Authoritative complete state from the most recent successful full run. |
| `.last_optimized_system` | Dedicated state for successful `--no-user` runs. |
| `.last_optimized_user` | Dedicated state for successful `--user-only` runs. |

A successful full run supersedes scope-limited caches. Scope-limited runs never replace the authoritative full-state file.

Additional state behavior:

* Dry runs do not create or commit persistent optimization state.
* A package with an unchanged trustworthy fingerprint is skipped.
* `--force` bypasses the skip decision for the current invocation but does not erase trusted state before compilation.
* Failed package compilations are omitted from the newly generated state so they are retried later.
* If the completed state is byte-for-byte identical to the selected persistent state, the existing file is left untouched.
* State replacement is staged and committed atomically only after a completed, healthy run.

## Diagnostics

Real runs may maintain diagnostic files next to the script when needed:

* `compile_errors.log` records package compilation failures from the most recent applicable real run.
* `maintenance_errors.log` records operational/runtime errors.
* `.early_exit` may preserve the latest usable partial state snapshot from an aborted or failed real run.

Dry runs do not persist these diagnostic logs.

Use:

```bash
sh /sdcard/monthly/maintenance.sh --debug
```

for verbose pipeline accounting, stat/metadata diagnostics, package fingerprint decisions, state handling, and cleanup information.

## Example Human-Readable Output

Output varies by device, Android version, package set, thermal source, selected scope, and whether packages have changed. A fully cached run may resemble:

```text
[+] Starting ART Smart Maintenance on Android 17 (SDK 37)...

    ─────────────────────────────────
    PRE-FLIGHT CHECK
    ─────────────────────────────────
[*] Thermal:  Status 0 (OK)
[!] Memory:   92% (MODERATE)
[*] Battery:  60%
    ─────────────────────────────────

[+] Step 1: Trimming system and app caches...
[+] Cache trim finished in 1s.
[+] Step 2: Smart-optimizing system packages...
[+] System package optimization finished in 2s.
[+] Step 3: Smart-optimizing user apps...
[+] User app optimization finished in 1s.

    ─────────────────────────────────
    FINAL STATUS
    ─────────────────────────────────
[*] Thermal:  Status 0 (OK)
[!] Memory:   92% (MODERATE)
[*] Battery:  60%
    ─────────────────────────────────

[+] State unchanged. Persistent state file left untouched.

==========================================
[+] Maintenance Summary:
    - Packages Compiled:         0
    - Packages Skipped (Cached): 483
    - Packages Failed:           0
    - Packages Invalid:          0
    - Total Scanned:             483
    - Persistent state:          Complete state current.
==========================================
```

> **Note:** On devices where Android's thermal-status API is unavailable, the script may display a Celsius temperature instead.

## Testing & Validation

The repository includes deterministic test fixtures and an ART maintenance laboratory exercised by GitHub Actions.

Coverage includes:

* package normalization and deduplication;
* paths containing `=`;
* CRLF package records;
* invalid package names and reserved delimiters;
* direct APK metadata, parent-directory fallback, and unavailable metadata;
* dry-run accounting;
* real-run state generation;
* compilation failures and retry-state behavior;
* `--force`;
* `--quiet`;
* `--health-only`;
* `--require-charging`;
* both `--min-battery N` and `--min-battery=N`;
* JSON stdout/stderr separation and `--json --debug`;
* `--no-trim`;
* `--user-only` state lifecycle;
* CLI validation and mutually exclusive scope options.

CI performs `mksh` syntax checks, generates fresh fixtures, and executes the laboratory on Ubuntu 24.04.

The script has also been exercised on Android 17 / SDK 37 with MirBSD ksh R59 and Toybox 0.8.14. Android vendor behavior can differ, so testing on additional devices and Android releases remains valuable.

## 💡 Pro-Tip: Automation

For unattended use, combine the safety gates with the output mode that fits the caller.

Human-oriented quiet run:

```bash
sh /sdcard/monthly/maintenance.sh --quiet --require-charging --min-battery 40
```

Machine-oriented run:

```bash
sh /sdcard/monthly/maintenance.sh --json --require-charging --min-battery 40
```

Health probe suitable for automation:

```bash
sh /sdcard/monthly/maintenance.sh --health-only --json
```

### Command by Setup Type

* **Rooted Devices**

  Use a standard **Run Shell** action with **Use Root** enabled:

  ```bash
  sh /sdcard/monthly/maintenance.sh --quiet
  ```

* **Non-Rooted Devices**

  Use an automation tool capable of executing commands with ADB shell privileges, such as Tasker's **ADB WiFi** functionality or MacroDroid's **ADB Shell Command** action:

  ```bash
  sh /sdcard/monthly/maintenance.sh --quiet
  ```

> **Note for Non-Rooted Automation:**
> Non-rooted automation requires ADB shell privileges. On Android 11+, automation tools may be able to simplify Wireless Debugging pairing or reconnection, but behavior depends on the Android build, device vendor, and app configuration. On Android 7–10, ADB TCP/IP mode generally needs to be enabled again after a reboot with `adb tcpip 5555`.

## License

This project is free and unencumbered software released into the public domain under [The Unlicense](LICENSE). For more information, see <https://unlicense.org/>.
