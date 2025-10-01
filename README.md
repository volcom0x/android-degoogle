Absolutely—here’s a more **generalized** `README.md` you can drop in at the root of the repo.

---

````markdown
# android-degoogle

**Safely de-Google and optimize modern Samsung Galaxy devices (tested on Galaxy S24 Ultra / One UI) using ADB—reversibly and without root.**

This repository provides two hardened Bash tools:

- `s24u-degoogle.sh` — **Per-user, reversible de-Google** using the official package manager surfaces (e.g., `pm disable-user --user N` / `pm enable --user N`).  
- `s24u-enhancements.sh` — **Performance, battery, and privacy enhancements** with a generated **full revert helper** (restores every setting the script changed).

Both scripts prioritize **safety**, **observability**, and **easy rollback**.

---

## Table of contents

- [Critical disclaimer](#critical-disclaimer)
- [What these scripts do / don’t do](#what-these-scripts-do--dont-do)
- [Supported devices & requirements](#supported-devices--requirements)
- [Quick start](#quick-start)
- [Repository layout](#repository-layout)
- [Script 1 — `s24u-degoogle.sh`](#script-1--s24u-degooglesh)
  - [Key features](#key-features)
  - [Modes & “keep” flags](#modes--keep-flags)
  - [Usage examples](#usage-examples)
  - [Artifacts](#artifacts)
- [Script 2 — `s24u-enhancements.sh`](#script-2--s24u-enhancementssh)
  - [Key features](#key-features-1)
  - [Usage examples](#usage-examples-1)
  - [Artifacts](#artifacts-1)
- [Reverting changes](#reverting-changes)
- [Verification checklist](#verification-checklist)
- [Troubleshooting](#troubleshooting)
- [Security & safety notes](#security--safety-notes)
- [Contributing](#contributing)
- [License](#license)

---

## Critical disclaimer

**⚠️ Proceed at your own risk.**  
Disabling or tweaking system components can break features, cause data loss, or require a factory reset. These tools are intended for **advanced users** comfortable with ADB and Android’s package manager. **Back up your device** before use. The authors are not responsible for any outcome.

> Reference: Android’s official ADB and shell tooling (including `pm`) are documented by Google. `pm disable-user --user`/`pm enable --user` manipulate **per-user** app state (reversible; no system partition writes). :contentReference[oaicite:0]{index=0}

---

## What these scripts do / don’t do

**They _do_:**
- Disable Google apps/services **per user** (default user **0**), and optionally Samsung/carrier extras—**reversibly**. :contentReference[oaicite:1]{index=1}
- Offer 3 **privacy modes** plus granular **keep flags** (e.g., keep Play Services / Store / Sync / RCS / Auto / Wear / AR / TTS).
- Provide **observability**: CSV action logs, full session logs, and generated **revert helpers**.
- Apply **enhancements** (UI animation scale, Private DNS, Data Saver, refresh-rate, scan toggles, ART optimization, standby buckets) using Android’s documented power-management and networking features. :contentReference[oaicite:2]{index=2}

**They _don’t_:**
- Root the phone or modify system partitions.
- Globally uninstall system apps.
- Guarantee every regional/carrier build—**missing packages are skipped safely**.

---

## Supported devices & requirements

- **Devices:** Modern Samsung Galaxy devices running recent Android / One UI (actively tested on **Galaxy S24 Ultra**).  
- **Host OS:** Linux or macOS with **Android platform-tools (ADB)** in `PATH`.  
- **Phone prep:** Enable **Developer options → USB debugging** and authorize your computer (verify `adb shell` works). :contentReference[oaicite:3]{index=3}

---

## Quick start

```bash
git clone https://github.com/your-org/android-degoogle.git
cd android-degoogle
chmod +x s24u-degoogle.sh s24u-enhancements.sh

# Dry-run first (no changes; full logs)
DRY_RUN=1 ./s24u-degoogle.sh --list-targets
DRY_RUN=1 ./s24u-enhancements.sh

# Apply for real (example: balanced profile, auto-detected region)
./s24u-degoogle.sh --mode balanced --csc auto --include-samsung on
./s24u-enhancements.sh
````

---

## Repository layout

```
android-degoogle/
├─ s24u-degoogle.sh          # De-Google (reversible, per-user)
├─ s24u-enhancements.sh      # Enhancements (reversible settings + revert)
├─ HOWTO.md                  # Deep-dive, step-by-step guide (optional)
└─ README.md                 # This file
```

---

## Script 1 — `s24u-degoogle.sh`

### Key features

* **Reversible per-user disable:** Uses `pm disable-user --user N` and can be undone with `pm enable --user N`. ([Android Open Source Project][1])
* **Three privacy modes:** `strict`, `balanced` (default), `permissive`.
* **Granular “keep” flags:** Keep Play Services/Store/Sync/Carrier Services/Android Auto/Wear OS/ARCore/TTS as needed.
* **CSC-aware (optional):** Region-aware toggles for Samsung/carrier extras; targets only if present (safe).
* **Guardrails:** Protects critical components (telephony, contacts providers, WebView) and checks SMS/Dialer roles.
* **Observability:** `actions.csv` + `session.log` + generated `reenable.sh`.

### Modes & “keep” flags

* **`strict`** — maximal de-Google; selectively keep essentials via `--with push,store,sync,rcs,auto,wear,ar,tts`.
* **`balanced`** — removes consumer Google apps; keeps Play/GSF/Sync by default.
* **`permissive`** — removes only consumer Google apps (max compatibility).

> Tip: Per-user state lets you experiment and roll back quickly. You can inspect/confirm current package lists via `adb shell pm list packages` (and variants). ([adbshell.com][2])

### Usage examples

```bash
# See exactly what would be targeted (no changes)
./s24u-degoogle.sh --mode strict --list-targets

# Strict, but keep notifications/sign-in/sync via Play stack
./s24u-degoogle.sh --mode strict --with push,store,sync

# Balanced, include Samsung extras, but keep Wallet/Pass
./s24u-degoogle.sh --mode balanced --include-samsung on --keep-samsung wallet,pass

# Power-user: act only on packages listed in a file
./s24u-degoogle.sh --only-file ./my-exact-targets.txt
```

### Artifacts

Each run creates an output directory with:

* **`reenable.sh`** — re-enables every package changed in that run.
* **`actions.csv`** — machine-readable action log (disable/skip/fail).
* **`session.log`** — full transcript for audit & support.

---

## Script 2 — `s24u-enhancements.sh`

### Key features

* **Reversible settings:** Generates `revert-enhancements.sh` with the **previous values** of every key it changed.
* **Performance/UI:** Animation scale; optional background process/caching hints.
* **Battery & network:**

  * **Data Saver** (system background data policy) and per-app background restrictions. ([Android Developers][3])
  * **Private DNS (DoT)** modes: off / automatic / provider hostname (for example `dns.google`). ([Google for Developers][4])
* **Display:** Min/peak refresh-rate tuning (e.g., 60–120 Hz or force 120 Hz).
* **Radio scans:** Toggle Wi-Fi/BLE “always scanning,” Wi-Fi scan throttling.
* **ART optimization:** Background profile compilation and selective AOT options (with an automatic “reset-to-defaults” step).
* **Power management hooks:** App Standby Buckets (e.g., `active`, `working_set`, `frequent`, `rare`, `restricted`) to throttle background work. ([Android Developers][5])

### Usage examples

```bash
# Snappy UI (0.5x animations), leave everything else default
./s24u-enhancements.sh

# Battery-lean: Data Saver ON, 60–120 Hz, throttle scans
DATA_SAVER=on REFRESH_MIN=60.0 REFRESH_MAX=120.0 WIFI_SCAN_THROTTLE=1 ./s24u-enhancements.sh

# Smooth: pin 120 Hz (higher power use)
REFRESH_MIN=120.0 REFRESH_MAX=120.0 ./s24u-enhancements.sh

# Private DNS via hostname (DNS-over-TLS)
PRIVATE_DNS_MODE=hostname PRIVATE_DNS_HOST=dns.google ./s24u-enhancements.sh
```

### Artifacts

* **`revert-enhancements.sh`** — restores all settings to their **previous** values.
* **`actions.csv`**, **`session.log`**, and (if ART used) **`dexopt-status.txt`**.

---

## Reverting changes

* From a **de-Google** run:

  ```bash
  ./reenable.sh
  ```
* From an **enhancements** run:

  ```bash
  ./revert-enhancements.sh
  ```
* Manual one-off:

  ```bash
  adb shell pm enable --user 0 <package.name>
  ```

---

## Verification checklist

* Place/receive **calls**; send/receive **SMS/MMS** (ensure your default SMS app is set).
* **Wi-Fi**, **mobile data**, **Bluetooth**, **Location** operate as expected.
* **Camera**/Gallery OK; **notifications** arrive for critical apps.
* If you used **Private DNS**, confirm status in Settings (Android 9+ supports DoT). ([Google for Developers][4])
* If you used **App Standby Buckets** or **Data Saver**, confirm background behavior aligns with expectations. ([Android Developers][5])

---

## Troubleshooting

* **`adb devices` shows `unauthorized`/`offline`:** Re-plug cable, accept RSA prompt on device, ensure USB debugging is enabled. ([Android Developers][6])
* **Package disable fails (“permission/policy”)**: Some vendor/region policies block certain disables; the scripts log and continue.
* **RCS/Visual Voicemail problems**: Keep or re-enable Carrier Services / Messages as needed (use `--with rcs` or `--with rcs` + re-enable).
* **Private DNS not applying**: Use **Automatic** or **hostname** and provide a valid host (e.g., `dns.google`). ([Google for Developers][4])

---

## Security & safety notes

* **Per-user disable** is intentionally **reversible** and doesn’t alter system partitions. ([Android Open Source Project][1])
* Power features like **Doze** and **App Standby Buckets** are designed to limit background work and network usage for battery life. ([Android Developers][5])
* Always keep **WebView** and critical telephony/contacts providers enabled unless you fully understand the impact.

---

## Contributing

PRs welcome! Please include:

1. `DRY_RUN=1` logs (`actions.csv` + relevant `session.log` snippets).
2. Device/One UI/Android versions and region/carrier details.
3. A concise rationale for changes and test notes.
