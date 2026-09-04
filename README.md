[![Gatekeeper](https://github.com/mwoolweaver/art-optimizer-via-adb-shell/actions/workflows/gatekeeper.yml/badge.svg?branch=main)](https://github.com/mwoolweaver/art-optimizer-via-adb-shell/actions/workflows/gatekeeper.yml)
[![ART Maintenance Tests](https://github.com/mwoolweaver/art-optimizer-via-adb-shell/actions/workflows/art-maintenance-tests.yml/badge.svg?branch=main)](https://github.com/mwoolweaver/art-optimizer-via-adb-shell/actions/workflows/art-maintenance-tests.yml)
[![Update README](https://github.com/mwoolweaver/art-optimizer-via-adb-shell/actions/workflows/update-readme.yml/badge.svg?branch=main)](https://github.com/mwoolweaver/art-optimizer-via-adb-shell/actions/workflows/update-readme.yml)
[![License: Unlicense](https://img.shields.io/badge/License-Unlicense-blue.svg)](https://unlicense.org/)
[![Android API](https://img.shields.io/badge/Android-7.0%2B%20%28API%2024%2B%29-green.svg)](https://developer.android.com)
![Tested Shell](https://img.shields.io/badge/Tested_Shell-MirBSD_ksh_R59-3DDC84?logo=android&logoColor=white)
![Tested Utilities](https://img.shields.io/badge/Tested_Utilities-Toybox_0.8.14-blue)

# ART Optimizer via ADB Shell

An ADB shell script that trims Android caches and optimizes ART packages without treating every run as the first chapter, using persistent package fingerprints to remember what has already earned its compilation.

## Overview & Features

The script combines Android Package Manager cache maintenance with scope-aware ART compilation and deliberately conservative state handling. It is tuned for Android's MirBSD ksh/Toybox environment, where needless subprocesses, repeated parsing, disk I/O, persistent writes, and encore compilations are treated as expenses rather than traditions.

* **Smart Incremental Compilation:** Remembers trustworthy package fingerprints so unchanged APKs are spared another appointment with the compiler.
* **Scope-Aware Optimization:** Supports full, system-only (`--no-user`), and user-only (`--user-only`) maintenance because not every performance needs the entire cast.
* **Dedicated State Caches:** Keeps full, system-only, and user-only histories separate; a partial truth is never promoted to the authoritative whole.
* **Compilation Policy:** Not every package dresses for the same occasion: preinstalled system packages use `speed`, while updated system apps under `/data/` and user apps use `speed-profile`.
* **Dry-Run Support:** `--dry-run` rehearses discovery, fingerprinting, accounting, and policy logic without letting compilation or persistent state onto the stage.
* **Quiet Operation:** `--quiet` dismisses the per-package chorus while keeping warnings, errors, stage output, and the final verdict.
* **Forced Recompilation:** `--force` gives selected packages an encore without changing compile policy or burning the state library before the show.
* **Optional Cache-Trim Bypass:** `--no-trim` excuses only Package Manager cache trimming; the ART package procession continues as written.
* **Battery Policy Gates:** `--require-charging` and `--min-battery` insist on evidence before unattended maintenance begins; optimism is not a power source.
* **Standalone Health Checks:** `--health-only` inspects thermal state, memory pressure, battery/power policy, and `/data` storage without pretending an inspection was maintenance.
* **Machine-Readable Automation:** `--json` gives stdout exactly one machine-readable voice; routine prose disappears while warnings and errors keep their place on stderr.
* **Debug Diagnostics:** `--debug` opens the backstage ledger with detailed accounting and pipeline diagnostics. With `--json --debug`, stdout keeps its clean JSON monologue while diagnostics move to stderr.
* **System Safeguards:** Checks boot completion, Package Manager availability, thermal conditions, memory pressure, and free `/data` space before allowing enthusiasm to outrun the device.
* **Transactional State Handling:** The old chronicle remains authoritative until its successor is complete; state is committed atomically and identical history earns no rewrite.
* **Failure Retry Semantics:** Failed compilations are not written into trusted history, ensuring the next run gives them another hearing.
* **Concurrency Protection:** Allows one maintenance run on the stage at a time; shared state and logs do not benefit from dueling narrators.
* **Automated Regression Testing:** GitHub Actions puts deterministic fixtures, package-pipeline behavior, options, state lifecycles, JSON behavior, and failure paths through the laboratory under `mksh`.

## Prerequisites

A little stagecraft before curtain: the device, host, and shell environment need the following pieces in place.

1. **Android Device Requirements**
   * **Android Version:** Android 7.0+ (API Level 24+).
   * **Developer Options:** Enable **USB Debugging** or, on Android 11+, **Wireless Debugging**.
   * **Available Storage:** At least **500 MB** of free space on `/data`. The script verifies this before compilation because optimism does not create disk blocks.

2. **Host Machine Setup**
   * **Terminal Access:** A command-line terminal on macOS, Linux, or Windows (PowerShell/WSL).
   * **ADB (Android Debug Bridge):** Android Platform Tools installed and accessible through your system `$PATH`.

3. **Execution Environment**
   * **Shell Privileges:** Standard `adb shell` access (UID 2000) or `root` (UID 0).
   * **Script Location:** This README uses `/sdcard/monthly/` as the persistent home for the script. Real runs require that directory to be writable; state and diagnostics need somewhere respectable to live.
   * **Temporary Directory:** Temporary work uses `$TMPDIR`; when it is unset or empty, `/data/local/tmp/` takes the role. A custom `TMPDIR` must already exist and be writable, or the script declines the engagement.

## Usage

### 1. Connect to your device

Connect the host to the Android device using the method appropriate to its generation; the plot changes slightly at Android 11.

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

> **Verification:** Run `adb devices`. If the device answers `unauthorized`, the RSA prompt on the device is waiting for its formal introduction.

### 2. Open an ADB shell and create the script directory

```bash
adb shell
mkdir -p /sdcard/monthly/
```

> **Why `/sdcard/monthly/`?**
> It gives the script and its persistent state a convenient home while `/data/local/tmp/` handles temporary scenery. Exact persistence across reboots or system updates can still vary by device and update process.

### 3. Write the script using a heredoc

The repository README normally carries an expandable heredoc that writes `maintenance.sh` directly to `/sdcard/monthly/`; the canonical script travels with its own installation instructions.

> **Note:** The embedded script body is intentionally absent from this returned copy. Keep `SCRIPT_START` and `SCRIPT_END` intact; the README-update workflow knows where the missing chapter belongs.

<!-- NOTE: Do not remove SCRIPT_START and SCRIPT_END comments below.
     They are used by update-readme.yml to auto-inject maintenance.sh -->

<details>
<summary><b>Click to Expand Heredoc</b></summary>

<!-- SCRIPT_START -->
```text
Embedded maintenance.sh omitted from this returned copy.
The README-update workflow will replace this region with the current canonical script.
```
<!-- SCRIPT_END -->

</details>

### 4. Run the script

Give the script explicitly to `sh`; the interpreter can read the manuscript even when the storage mount refuses to execute it directly:

```bash
sh /sdcard/monthly/maintenance.sh
```

> **Note:** This explicit `sh` invocation is intentional: `/sdcard/` may be mounted `noexec`, but that need not end the story when the shell reads the file itself.

## Command-Line Options

```text
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
```

`--min-battery=N` is also accepted; punctuation need not become a policy dispute.

`--no-user` and `--user-only` are mutually exclusive. A run cannot omit the user scope and consist only of it in the same sentence.

The environment-configurable modes remain:

```text
DEBUG=0|1
DRY_RUN=0|1
NO_USER=0|1
TMPDIR=/path/to/writable/temp/directory
```

The newer operational flags are CLI-only; transient intentions belong on the command line rather than lingering in the environment.

### Common Examples

The complete performance:

```bash
sh /sdcard/monthly/maintenance.sh
```

Rehearse the full logic without compiling or editing persistent history:

```bash
sh /sdcard/monthly/maintenance.sh --dry-run
```

Dismiss the routine chorus while keeping the summary and warnings:

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

Request an encore for the selected scope without changing its normal compile-mode policy:

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

Ask stdout for one machine-readable answer and nothing ornamental:

```bash
sh /sdcard/monthly/maintenance.sh --json
```

Keep the JSON monologue on stdout while opening the diagnostic backstage on stderr:

```bash
sh /sdcard/monthly/maintenance.sh --json --debug
```

## JSON Output

`--json` is written for automation, where a monologue is a virtue. On a successful non-debug run, stdout contains exactly one JSON object; routine human output is suppressed while warnings and errors remain on stderr.

Example:

```json
{"success":true,"mode":"maintenance","scope":"full","dry_run":false,"force":false,"cache_trim":true,"require_charging":false,"min_battery_percent":null,"thermal":"status:0","memory_percent":92,"battery_percent":60,"charging":null,"data_free_kb":33985688,"compiled":0,"would_compile":0,"skipped":483,"failed":0,"invalid":0,"scanned":483,"duration_seconds":4,"state":"current"}
```

With `--health-only`, package maintenance never enters the scene, so `scope`, `cache_trim`, and `state` say so explicitly rather than inventing work that did not occur:

```json
{"success":true,"mode":"health-only","scope":"none","dry_run":false,"force":false,"cache_trim":null,"require_charging":false,"min_battery_percent":null,"thermal":"status:0","memory_percent":93,"battery_percent":59,"charging":true,"data_free_kb":33875376,"compiled":0,"would_compile":0,"skipped":0,"failed":0,"invalid":0,"scanned":0,"duration_seconds":1,"state":"not-applicable"}
```

For diagnostics without contaminating machine-readable stdout:

```bash
sh /sdcard/monthly/maintenance.sh --json --debug
```

JSON keeps stdout to itself while the human-readable and debug conversation moves to stderr.

## Health and Power Policies

Normal maintenance inspects the device before the work begins and checks thermal/memory health again before committing persistent state; congratulations come after the measurements.

`--health-only` performs the inspection without staging a maintenance performance: health, charging state, battery policy, and `/data` storage are checked without trimming caches, compiling packages, or modifying persistent package state:

```bash
sh /sdcard/monthly/maintenance.sh --health-only
```

For unattended execution, let the optional power gates demand proof before proceeding:

```bash
sh /sdcard/monthly/maintenance.sh --require-charging
sh /sdcard/monthly/maintenance.sh --min-battery 40
sh /sdcard/monthly/maintenance.sh --require-charging --min-battery=40
```

When a requested power policy cannot be verified or satisfied, the run fails closed. A safety requirement that quietly excuses itself was never much of a requirement.

## Persistent State Model

The state files are the script's memory, and it is deliberately particular about what becomes history. Scope-specific fingerprint caches live next to `maintenance.sh`:

| File | Meaning |
| --- | --- |
| `.last_optimized` | Authoritative complete state from the most recent successful full run. |
| `.last_optimized_system` | Dedicated state for successful `--no-user` runs. |
| `.last_optimized_user` | Dedicated state for successful `--user-only` runs. |

A successful full run becomes the authoritative chronicle and supersedes scope-limited caches. Partial runs keep their own records and never impersonate the complete-device history.

Additional state behavior:

* Dry runs rehearse the logic without writing persistent optimization history.
* A trustworthy fingerprint that has not changed earns the package a graceful exit from recompilation.
* `--force` overrides the skip decision for this performance, but it does not burn the trusted archive before compilation.
* Failed compilations do not receive a line in the new trusted history, so a later run will try them again.
* If the completed chronicle is byte-for-byte identical to the selected persistent state, the old copy is left in peace.
* A replacement state is staged first and committed atomically only after the run reaches a healthy ending.

## Diagnostics

When a real run misbehaves, evidence should outlive the drama. Diagnostic files may appear next to the script when needed:

* `compile_errors.log` records package compilation failures from the most recent applicable real run.
* `maintenance_errors.log` records operational/runtime errors.
* `.early_exit` may preserve the latest usable partial state snapshot from an aborted or failed real run.

Dry runs may complain, but they leave no persistent diagnostic scandal behind.

Use:

```bash
sh /sdcard/monthly/maintenance.sh --debug
```

for the full backstage ledger: pipeline accounting, stat/metadata diagnostics, fingerprint decisions, state handling, and cleanup.

## Example Human-Readable Output

Every device tells the story with slightly different scenery: Android version, packages, thermal source, scope, and changed APKs all matter. A fully cached performance may resemble:

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

> **Note:** If Android's thermal-status API declines to narrate, the script may fall back to the less literary but perfectly serviceable language of Celsius.

## Testing & Validation

The repository keeps both a laboratory and a field notebook: deterministic fixtures are exercised by GitHub Actions before real devices get a vote.

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

CI first checks the grammar with `mksh`, then prepares fresh fixtures and sends the script through the laboratory on Ubuntu 24.04.

The script has also left the laboratory and run on Android 17 / SDK 37 with MirBSD ksh R59 and Toybox 0.8.14. Vendor behavior remains its own genre, so additional devices and Android releases are still welcome reviewers.

## 💡 Pro-Tip: Automation

For unattended use, pair the guardrails with the audience: quiet prose for humans, JSON for machines, and health-only when the caller merely wants a pulse.

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

  A standard **Run Shell** action with **Use Root** enabled gives the script the necessary stage access:

  ```bash
  sh /sdcard/monthly/maintenance.sh --quiet
  ```

* **Non-Rooted Devices**

  Use an automation tool that can speak with ADB shell privileges, such as Tasker's **ADB WiFi** functionality or MacroDroid's **ADB Shell Command** action:

  ```bash
  sh /sdcard/monthly/maintenance.sh --quiet
  ```

> **Note for Non-Rooted Automation:**
> Non-rooted automation still requires ADB shell privileges. Android 11+ may let automation tools simplify Wireless Debugging pairing or reconnection, though the exact plot depends on the build, vendor, and app. On Android 7–10, ADB TCP/IP mode generally needs a fresh `adb tcpip 5555` after reboot.

## License

This project is free and unencumbered software released into the public domain under [The Unlicense](LICENSE). Even the copyright has been excused from the cast; for the formal text, see <https://unlicense.org/>.
