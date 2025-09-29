# android-degoogle

**De-Google and optimize a Samsung Galaxy S24 Ultra safely and reversibly via ADB.**
This repository contains two hardened shell tools:

* `s24u-degoogle.sh` — **Disable Google apps/services per-user** using `pm disable-user --user 0` (reversible).
* `s24u-enhancements.sh` — **Performance, battery, and privacy tweaks**, with a **full revert helper** that restores every changed setting.

Both scripts emphasize **safety, observability, and rollback** for advanced users.

---

## Table of Contents

* [Critical Disclaimer](#critical-disclaimer)
* [What These Scripts Do / Don’t Do](#what-these-scripts-do--dont-do)
* [Supported Device & Requirements](#supported-device--requirements)
* [Quick Start](#quick-start)
* [Repository Layout](#repository-layout)
* [Script 1 — `s24u-degoogle.sh`](#script-1--s24u-degooglesh)

  * [Key Features](#key-features)
  * [Environment Variables](#environment-variables)
  * [Usage](#usage)
  * [Generated Artifacts](#generated-artifacts)
  * [Customize Targets (Extra/Exclude/Protect)](#customize-targets-extraexcludeprotect)
* [Script 2 — `s24u-enhancements.sh`](#script-2--s24u-enhancementssh)

  * [Key Features](#key-features-1)
  * [Environment Variables](#environment-variables-1)
  * [Usage](#usage-1)
  * [Generated Artifacts](#generated-artifacts-1)
* [Reverting Changes](#reverting-changes)
* [Verification Checklist](#verification-checklist)
* [Troubleshooting](#troubleshooting)
* [Security, Privacy & Safety Notes](#security-privacy--safety-notes)
* [Windows Notes](#windows-notes)
* [Development Guidelines](#development-guidelines)
* [Contributing](#contributing)
* [License](#license)

---

## Critical Disclaimer

**⚠️ PROCEED AT YOUR OWN RISK.**
Disabling or modifying system components may break features, cause data loss, or require a factory reset. These tools are intended for **advanced users** who understand ADB and Android package management. **Back up your device** before use. You are solely responsible for outcomes.

---

## What These Scripts Do / Don’t Do

**They *do*:**

* Disable Google apps/services **per-user** (User 0) with `pm disable-user --user 0`.
* Preserve core phone functionality (calling, SMS/MMS, Wi-Fi, Bluetooth, system UI).
* Generate **logs + helper scripts** that revert everything the tools changed.
* Offer optional performance/privacy enhancements (animation scale, Private DNS, Data Saver, etc.).

**They *do not*:**

* Root the device or modify system partitions.
* Uninstall system apps globally.
* Guarantee compatibility with every region/carrier build (they **skip** missing packages safely).

---

## Supported Device & Requirements

* **Device:** Samsung Galaxy **S24 Ultra** (One UI variants).
  *Other Samsung models may work, but are not the target of this repo.*
* **Host:** macOS or Linux with **Android platform-tools (ADB)** in `PATH`.
* **Phone Settings:** Enable **Developer options**, then enable:

  * **USB debugging**
  * **USB debugging (Security settings)**
* **Backups:** Perform a **full backup** of important data before changes.

---

## Quick Start

```bash
# 1) Clone
git clone git@github.com:volcom0x/android-degoogle.git
cd android-degoogle

# 2) Make scripts executable
chmod +x s24u-degoogle.sh s24u-enhancements.sh

# 3) Dry-run first (no changes applied, full logging)
DRY_RUN=1 ./s24u-degoogle.sh
DRY_RUN=1 ./s24u-enhancements.sh

# 4) Apply for real (review logs and helper scripts afterward)
./s24u-degoogle.sh
./s24u-enhancements.sh
```

> Both tools interactively confirm the risks before proceeding.

---

## Repository Layout

```
android-degoogle/
├── s24u-degoogle.sh           # De-Google (reversible)
├── s24u-enhancements.sh       # Performance & privacy (reversible)
├── extra-google-packages.txt  # (optional) user-extendable package list
└── README.md                  # this file
```

---

## Script 1 — `s24u-degoogle.sh`

### Key Features

* **Reversible de-Google:** Uses `pm disable-user --user 0` (per-user freeze).
* **Defensive design:** Strict mode, device/authorization checks, multi-device selection.
* **Guardrails:** Protect list (e.g., WebView, telephony/contacts), role checks (SMS/Dialer).
* **Safe mode:** By default targets **Google** packages only; opt-in to non-Google extras.
* **Observability:** CSV action logs, full package inventories, and a **reenable helper**.
* **Customizable:** Extra and exclude lists from text files; dry-run support.

### Environment Variables

| Variable           | Default                       | Description                                                               |
| ------------------ | ----------------------------- | ------------------------------------------------------------------------- |
| `DRY_RUN`          | `0`                           | `1` = simulate only; print/log actions but **no changes**                 |
| `OUTDIR`           | `./adb-degoogle-<timestamp>`  | Output folder for logs/artifacts                                          |
| `EXTRA_PKG_FILE`   | `./extra-google-packages.txt` | (Optional) Additional package names (one per line, `#` comments)          |
| `EXCLUDE_PKG_FILE` | *(empty)*                     | (Optional) Never disable packages listed here                             |
| `SAFE_MODE`        | `1`                           | Restrict to known Google prefixes; prevents accidental non-Google changes |
| `ALLOW_NON_GOOGLE` | `0`                           | Set `1` to permit non-Google packages from `EXTRA_PKG_FILE`               |

### Usage

```bash
# Dry-run for audit
DRY_RUN=1 ./s24u-degoogle.sh

# Real run with default behavior (Google-only safe mode)
./s24u-degoogle.sh

# Include extra Google targets from a file
EXTRA_PKG_FILE=./my-extra-google.txt ./s24u-degoogle.sh

# Keep specific packages from being disabled
EXCLUDE_PKG_FILE=./keep-these.txt ./s24u-degoogle.sh

# Allow non-Google extras (advanced)
ALLOW_NON_GOOGLE=1 EXTRA_PKG_FILE=./my-extra.txt ./s24u-degoogle.sh

# Change output directory
OUTDIR=./runs/$(date +%F_%H%M) ./s24u-degoogle.sh
```

### Generated Artifacts

Within `OUTDIR` the script writes:

* `reenable.sh` — **Re-enables every package** this run disabled.
* `packages-all.txt` — `cmd package list packages -u -f`
* `packages-enabled.txt` — currently enabled packages
* `packages-disabled.txt` — currently disabled packages
* `actions.csv` — machine-readable log of each action
* `session.log` — full stdout/stderr transcript

### Customize Targets (Extra/Exclude/Protect)

* **Extra list**: Put additional packages (one per line) in `extra-google-packages.txt` or your own file; comments start with `#`.
* **Exclude list**: Put packages to **keep enabled** in a `keep` file and pass via `EXCLUDE_PKG_FILE`.
* **Protect list** (in-script): Critical components (e.g., WebView, dialer/SMS roles) are **never** disabled.

> **Role guard:** If **Google Messages** holds the SMS role, the script warns before disabling it. Switch your default SMS app (e.g., Samsung Messages) or proceed knowingly.

---

## Script 2 — `s24u-enhancements.sh`

### Key Features

* **Reversible enhancements**: Generates `revert-enhancements.sh` that restores **previous values** of every setting it changed, and re-enables any packages it disabled.
* **Performance/UI**: Animation scale, optional background-process limits, optional cache size hint.
* **Battery/Network**: Data Saver control, Private DNS (DoT) modes.
* **Display**: Refresh-rate min/peak (e.g., 60–120 or pinned 120).
* **Radio Scans**: Toggle Wi-Fi/BLE “always scanning,” Wi-Fi scan throttling.
* **ART Optimization**: Background profile compile, `speed-profile`/`speed` modes, per-package compile — with reset-to-default.
* **Observability**: CSV logs, `dexopt-status.txt`, full session logs, dry-run mode.

### Environment Variables

| Variable                   | Default                          | Description                                                          |
| -------------------------- | -------------------------------- | -------------------------------------------------------------------- |
| `DRY_RUN`                  | `0`                              | `1` = simulate only; no changes                                      |
| `OUTDIR`                   | `./adb-enhancements-<timestamp>` | Output folder for logs/artifacts                                     |
| `ANIM_SCALE`               | `0.5`                            | UI animation scale (0–1; lower feels snappier)                       |
| `SET_APP_STANDBY`          | `1`                              | Ensure App Standby enabled (`1`)                                     |
| `BACKGROUND_PROCESS_LIMIT` | *(empty)*                        | Optional cap on cached processes (e.g., `2`, `4`); empty = unchanged |
| `ACTIVITY_MAX_CACHED`      | *(empty)*                        | Optional `device_config` hint for max cached processes               |
| `DATA_SAVER`               | *(empty)*                        | `on`/`off`; controls `restrict-background`                           |
| `PRIVATE_DNS_MODE`         | *(empty)*                        | `off` / `opportunistic` / `hostname`                                 |
| `PRIVATE_DNS_HOST`         | *(empty)*                        | Required if `PRIVATE_DNS_MODE=hostname`                              |
| `REFRESH_MIN`              | *(empty)*                        | e.g., `60.0`                                                         |
| `REFRESH_MAX`              | *(empty)*                        | e.g., `120.0`                                                        |
| `DISABLE_ALWAYS_SCANNING`  | `0`                              | `1` disables Wi-Fi/BLE “always scanning”                             |
| `WIFI_SCAN_THROTTLE`       | *(empty)*                        | `1` enable (battery-friendly) or `0` disable                         |
| `ART_ACTION`               | *(empty)*                        | `bg` / `speed-profile-all` / `speed-all`                             |
| `ART_SPEED_PROFILE_PKGS`   | *(empty)*                        | Space-separated package list for targeted speed-profile              |

### Usage

```bash
# Dry-run first
DRY_RUN=1 ./s24u-enhancements.sh

# Common snappy preset (animations 0.5x, leave others default)
./s24u-enhancements.sh

# Battery-lean preset (Data Saver ON, cap at 60–120Hz, keep scan throttling)
DATA_SAVER=on REFRESH_MIN=60.0 REFRESH_MAX=120.0 WIFI_SCAN_THROTTLE=1 ./s24u-enhancements.sh

# Smooth preset (pin 120Hz; higher power)
REFRESH_MIN=120.0 REFRESH_MAX=120.0 ./s24u-enhancements.sh

# Private DNS via hostname
PRIVATE_DNS_MODE=hostname PRIVATE_DNS_HOST=dns.adguard-dns.com ./s24u-enhancements.sh

# ART background optimizer + profile for selected apps
ART_ACTION=bg ART_SPEED_PROFILE_PKGS="org.mozilla.firefox com.sec.android.app.sbrowser" ./s24u-enhancements.sh
```

### Generated Artifacts

Within `OUTDIR` the script writes:

* `revert-enhancements.sh` — **Restores** every setting to its **previous** value and **re-enables** any disabled packages.
* `actions.csv` — machine-readable log of each action
* `dexopt-status.txt` — snapshot of ART/dexopt state (if ART used)
* `revert.markers`, `revert.dc.markers` — internal bookkeeping
* `session.log` — full stdout/stderr transcript

---

## Reverting Changes

* From **de-Google** run:

  ```bash
  # In that run's OUTDIR
  ./reenable.sh
  ```
* From **enhancements** run:

  ```bash
  # In that run's OUTDIR
  ./revert-enhancements.sh
  ```
* Or manually re-enable a package:

  ```bash
  adb shell pm enable --user 0 <package.name>
  ```

---

## Verification Checklist

After de-Googling and/or enhancements:

* Place/receive a **phone call**.
* Send/receive **SMS/MMS** (Samsung Messages or your chosen app).
* **Wi-Fi** connects and is stable; **mobile data** works; **Bluetooth** pairs/streams.
* **Location** works in your preferred non-Google maps app.
* **Camera** opens/records/saves; **Gallery** browses media.
* **Notifications** arrive for critical apps (banking, 2FA, messenger).
* **WebView** functionality intact (don’t disable WebView unless you know the impact).
* App installs/updates via **Galaxy Store**, **F-Droid**, etc.

If a function breaks, re-enable the related package(s) and retest.

---

## Troubleshooting

* **`adb devices` shows `unauthorized` or `offline`:**
  Reconnect cable, accept PC fingerprint on the phone, ensure **USB debugging** (and **USB debugging (Security settings)**) are enabled.
* **“Permission/policy” failures when disabling:**
  Some system apps are protected by policy/Knox/region builds. The script logs failures and continues; you can try again after toggling relevant developer or security settings.
* **RCS/Visual Voicemail issues after de-Google:**
  Re-enable `com.google.android.ims` and, if needed, `com.google.android.apps.messaging`.
* **Missing packages:**
  Region/carrier variants differ. The scripts safely **skip** anything not present and record this in `actions.csv`.
* **Role guard (SMS/Dialer) warnings:**
  If **Google Messages** holds the SMS role, switch to Samsung Messages (or your choice) before disabling Google Messages.

---

## Security, Privacy & Safety Notes

* Using `pm disable-user --user 0` is **non-destructive** and **reversible**.
* **Protect list** avoids critical components like WebView and telephony stacks.
* **Safe mode** limits scope to Google prefixes unless you explicitly opt-in to broader targets.
* **Logs + Helper scripts** make it straightforward to revert and audit.

---

## Windows Notes

* Scripts are Bash; run them via **WSL** on Windows.
  *(A PowerShell port can be added; open an issue if you need it.)*

---

## Development Guidelines

* **Coding standards:** `set -Eeuo pipefail`; no unguarded `eval`; sanitize input; skip-missing device/package checks.
* **Static analysis:**

  ```bash
  # ShellCheck (lint)
  shellcheck s24u-degoogle.sh s24u-enhancements.sh

  # shfmt (format)
  shfmt -i 2 -w s24u-degoogle.sh s24u-enhancements.sh
  ```
* **Git hygiene:** Conventional commits (`feat:`, `fix:`, `docs:`, etc.), small PRs, test with `DRY_RUN=1` before real runs.
* **Logging:** Do not remove `actions.csv`/`session.log`—they are essential for support and audits.

---

## Contributing

Issues and pull requests are welcome. Please:

1. Start with **`DRY_RUN=1`** logs that reproduce your case.
2. Provide your `actions.csv` and relevant snippets from `session.log`.
3. Note your **One UI** version, **Android** version, and region/carrier.

---

## License

Choose a license that fits your needs (e.g., **MIT** or **Apache-2.0**). If unspecified, code is provided **as-is**, with no warranties or guarantees.

---

**Stay safe, test with `DRY_RUN=1`, and keep your revert scripts!**
