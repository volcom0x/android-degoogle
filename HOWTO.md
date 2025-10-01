# HOWTO: De-Google & Enhance Your Galaxy (S24 Ultra focused, One UI) — Deep-Dive Guide

> This HOWTO explains, in detail, how to use **both** scripts in this repo:
>
> - `s24u-degoogle.sh` — reversible, per-user de-Google with **three privacy modes** + granular “keep” flags  
> - `s24u-enhancements.sh` — performance, battery & privacy **tweaks with a full revert helper**
>
> The guide covers prerequisites, dry-run/auditing, safe rollbacks, CSC notes (THL/EUX), and advanced ADB techniques.

---

## 0) Read me first (risk, backups, reversibility)

- These tools **don’t** root your phone or modify system partitions. They rely on Android’s official per-user package state and system settings surfaces (e.g., `pm disable-user --user N`, `settings`, `cmd …`) — which are **reversible**. :contentReference[oaicite:0]{index=0}  
- Even so, **you can break app features** (e.g., RCS, Wallet, Wear). Always start with a **dry-run** and keep the generated revert helpers.  
- Know your user: Android is multi-user; our scripts explicitly operate on **User 0** to avoid ambiguity. Verify with `adb shell am get-current-user`. :contentReference[oaicite:1]{index=1}

---

## 1) Prerequisites & device prep

### Install platform tools & enable ADB
1. Install **Android platform-tools** on your computer and ensure `adb` is in `PATH`. :contentReference[oaicite:2]{index=2}  
2. On the phone, enable **Developer options** → **USB debugging** and **authorize** your computer (watch for the RSA prompt). :contentReference[oaicite:3]{index=3}  
3. If **USB debugging is greyed out** on recent Samsung builds (One UI 6+), **turn off**:  
   **Settings → Security & privacy → Auto Blocker** (you can re-enable later). This Samsung feature can restrict debugging & sideloading. :contentReference[oaicite:4]{index=4}

### Verify connectivity
```bash
adb devices        # should show your device as "device"
adb shell true     # should return without error
adb shell am get-current-user
````

If you see `offline/unauthorized`, re-plug, confirm the RSA prompt, or toggle USB mode (File Transfer / Android Auto).

---

## 2) Repository anatomy & safety nets

* **Both** scripts write **per-run output folders** containing:

  * A **revert helper** (`reenable.sh` or `revert-enhancements.sh`)
  * A **CSV log** of every action (`actions.csv`)
  * A **full transcript** (`session.log`)
* Missing packages are auto-skipped (region/carrier variance is expected).

> Tip: You can inspect current packages any time:
> `adb shell pm list packages` (+ `-u` to include uninstalled/disabled, `-d` for disabled). ([yamen.dev][1])

---

## 3) Using `s24u-degoogle.sh` — in depth

### 3.1 What it does (and how it stays safe)

* Uses **per-user disablement**: `pm disable-user --user 0 <package>`. Re-enable with `pm enable --user 0 <package>`. ([Android Open Source Project][2])
* **Three privacy modes** control scope; **keep flags** allow granular opt-in to Play Services, Store, Sync, RCS, Auto, Wear, ARCore, TTS, etc.
* Guardrails:

  * **Protect list**: never touches critical components (telephony providers, WebView, dialer/contacts)
  * **Role checks**: warns if Google Messages currently holds **SMS role** so you don’t strand SMS. (Roles are a standardized system concept.) ([Android Open Source Project][3])

### 3.2 Run it the safe way (audit first)

```bash
# See exactly what *would* be touched — no changes
DRY_RUN=1 ./s24u-degoogle.sh --mode balanced --list-targets
```

Review the console output and `actions.csv`. If happy, run for real (examples below).

### 3.3 Modes (choose one)

| Mode                   | What it targets                                                                                  | Good for                  |
| ---------------------- | ------------------------------------------------------------------------------------------------ | ------------------------- |
| **strict**             | Maximal Google removal; you selectively **keep** only what you need via `--with …`               | Privacy labs / alt-stores |
| **balanced** (default) | Removes consumer Google apps; **keeps Play Services + GSF + Sync** to maintain app compatibility | Most users                |
| **permissive**         | Removes only headline consumer apps (Gmail/Maps/Photos/YouTube/etc.); leaves Play stack intact   | Compatibility-first       |

> If you use **microG**, choose `strict` + `--with store,sync` depending on your setup (Play Store off, GSF/Account Manager on). microG typically needs signature-spoofing ROMs; stock Samsung firmware doesn’t offer that out of the box (outside the scope of this HOWTO).

### 3.4 Granular “keep” flags

Add `--with` to whitelist specific subsystems even in **strict** mode:

* `push` (Play Services core push) — `com.google.android.gms`
* `store` (Play Store) — `com.android.vending`
* `sync` (Contacts/Calendar) — `com.google.android.syncadapters.*`
* `rcs` (Carrier Services / Google Messages RCS) — `com.google.android.ims`, `com.google.android.apps.messaging` ([Google Help][4])
* `auto` (Android Auto) — `com.google.android.projection.gearhead`
* `wear` (Wear OS) — wearable companion bits
* `ar` (ARCore) — `com.google.ar.core`
* `tts` (Google TTS)

Examples:

```bash
# Strict, but keep Play Push + Store + Sync (maximum compatibility)
./s24u-degoogle.sh --mode strict --with push,store,sync

# Balanced, include Samsung extras, but keep Wallet/Pass
./s24u-degoogle.sh --mode balanced --include-samsung on --keep-samsung wallet,pass

# Power user: act *only* on the packages listed in a file
./s24u-degoogle.sh --only-file ./my-exact-targets.txt
```

### 3.5 CSC awareness (THL/EUX)

Carrier/region bloat varies. The script detects presence and **only disables what actually exists**; e.g., Samsung TV Plus, Global Goals, Game Launcher, partner preloads (Facebook/Netflix/LinkedIn), etc.

> On EUX/THL, **RCS** availability and the default messaging app can differ by carrier. If you need RCS, prefer **keep flag `--with rcs`** or re-enable **Carrier Services** afterward. ([Google Help][4])

### 3.6 After a run: verify & rollback

* Check: calls, SMS/MMS, Wi-Fi, data, Bluetooth, Location, camera, notifications (banking/2FA).
* If something broke, open the run folder and:

  ```bash
  ./reenable.sh     # re-enables everything changed in that run
  # or one-off
  adb shell pm enable --user 0 <package.name>
  ```

---

## 4) Using `s24u-enhancements.sh` — in depth

This script changes **settings** and a few **device_config** flags, logging every change and generating a **revert-enhancements.sh** that restores **previous** values (not just defaults).

### 4.1 UI responsiveness

* **Animation scale** (Global): `window_animation_scale`, `transition_animation_scale`, `animator_duration_scale`. Lower (e.g., `0.5`) feels snappier.

### 4.2 Background management

* **App Standby Buckets**: Android prioritizes apps into `active`, `working_set`, `frequent`, `rare`, `restricted`, limiting background access by bucket. You can **observe or influence** via ADB and the script’s helpers. ([Android Developers][5])
* Optional **background process/cache hints** (device_config). The script records and restores any modified hints.

### 4.3 Network: Data Saver & per-app background

* System “**Data Saver**” uses `cmd netpolicy` and background restrictions. You can toggle the **global** Data Saver state and maintain per-app background allowances. (See: `adb shell cmd netpolicy help` and subcommands.) ([Android Open Source Project][6])

Examples:

```bash
# Battery-lean: enable Data Saver; keep scan-throttle; cap to 60–120 Hz
DATA_SAVER=on REFRESH_MIN=60.0 REFRESH_MAX=120.0 WIFI_SCAN_THROTTLE=1 ./s24u-enhancements.sh
```

### 4.4 Private DNS (DNS-over-TLS)

Android supports **Private DNS** modes: `off`, `opportunistic` (automatic), or `hostname` (explicit DoT provider). The script writes:

* `settings put global private_dns_mode <off|opportunistic|hostname>`
* `settings put global private_dns_specifier <host>` (for `hostname` mode)
  Configure, e.g., `one.one.one.one` or a filtering provider if desired. ([Cloudflare Docs][7])

Examples:

```bash
# Set Cloudflare DoT
PRIVATE_DNS_MODE=hostname PRIVATE_DNS_HOST=one.one.one.one ./s24u-enhancements.sh
# Restore to automatic
PRIVATE_DNS_MODE=opportunistic ./s24u-enhancements.sh
```

### 4.5 Display: refresh-rate tuning

On devices exposing system keys, you can guide the display stack:

* **`Settings.System.MIN_REFRESH_RATE`**
* **`Settings.System.PEAK_REFRESH_RATE`**
  Used by OEMs to clamp ranges like **60–120 Hz** or pin 120 Hz. The script records previous values for clean rollback. ([Android Open Source Project][8])

Examples:

```bash
# Smooth: pin 120 Hz (more power use)
REFRESH_MIN=120.0 REFRESH_MAX=120.0 ./s24u-enhancements.sh
# Balanced LTPO range on many panels
REFRESH_MIN=60.0  REFRESH_MAX=120.0 ./s24u-enhancements.sh
```

### 4.6 Radio scans & battery

* **Always scanning** toggles: `wifi_scan_always_enabled`, `ble_scan_always_enabled` (Global).
* **Wi-Fi scan throttling**: `wifi_scan_throttle_enabled` (Global).
  These reduce background scan churn at the cost of discovery speed (script restores prior values).

### 4.7 ART optimizations (optional)

* `cmd package bg-dexopt-job` (profile-guided background compile) or AOT profiles (`-m speed-profile` / `speed`). Android’s ART/JIT/AOT pipeline evolves — the script **always** adds a `compile --reset -a` line to your revert helper so you can undo. ([Android Open Source Project][9])

Examples:

```bash
# Let the system profile & compile in background, then snapshot dexopt status
ART_ACTION=bg ./s24u-enhancements.sh

# Aggressive AOT for everything (larger storage footprint)
ART_ACTION=speed-all ./s24u-enhancements.sh

# Targeted speed-profile for specific apps
ART_SPEED_PROFILE_PKGS="org.mozilla.firefox com.sec.android.app.sbrowser" ./s24u-enhancements.sh
```

### 4.8 Advanced: device_config guard & phantom processes (optional)

When experimenting with `device_config` flags, it’s useful to **freeze server-side config sync** during tests:

```bash
adb shell cmd device_config set_sync_disabled_for_tests persistent
# ... your device_config tweaks ...
adb shell cmd device_config set_sync_disabled_for_tests none   # then reboot
```

This prevents Google/partner config from instantly overwriting your local test values. The script’s revert helper restores prior flags. ([Android Open Source Project][10])

---

## 5) Presets you can copy-paste

### 5.1 De-Google profiles

```bash
# STRICT but functional: keep Play push, Store, Sync (sign-in + notifications)
./s24u-degoogle.sh --mode strict --with push,store,sync

# Balanced default: remove consumer Google apps; keep Play stack
./s24u-degoogle.sh --mode balanced

# Permissive: only remove the obvious Google apps (YouTube/Gmail/Maps/Photos, etc.)
./s24u-degoogle.sh --mode permissive
```

**RCS users (THL/EUX carriers):**

```bash
# Strict privacy, but preserve RCS stack (Carrier Services + Messages)
./s24u-degoogle.sh --mode strict --with rcs
```

(If you disable Carrier Services or Google Messages, **RCS may stop working**; SMS/MMS still works via your chosen SMS app.) ([Google Help][4])

### 5.2 Enhancement profiles

```bash
# Battery-lean (daily driver)
DATA_SAVER=on WIFI_SCAN_THROTTLE=1 REFRESH_MIN=60.0 REFRESH_MAX=120.0 ./s24u-enhancements.sh

# Smooth UI (demo days)
REFRESH_MIN=120.0 REFRESH_MAX=120.0 ANIM_SCALE=0.5 ./s24u-enhancements.sh

# Privacy DNS (system-wide DoT)
PRIVATE_DNS_MODE=hostname PRIVATE_DNS_HOST=one.one.one.one ./s24u-enhancements.sh
```

---

## 6) Auditing your run (what changed?)

Each run folder contains:

* `actions.csv` — machine-readable log of every package/settings action
* `session.log` — full transcript (great for issue reports)
* `reenable.sh` (de-Google) / `revert-enhancements.sh` (enhancements) — **your lifeline**

Quick checks:

```bash
# Packages now disabled for user 0
adb shell pm list packages -d

# Data Saver / background restrictions view (example)
adb shell cmd netpolicy     # list subcommands
adb shell cmd netpolicy list restrict-background-whitelist
```

([Android Open Source Project][6])

---

## 7) Reverting & incremental recovery

* **Full revert** for a run:

  ```bash
  ./reenable.sh                  # from s24u-degoogle.sh
  ./revert-enhancements.sh       # from s24u-enhancements.sh
  ```
* **Targeted**:
  `adb shell pm enable --user 0 <package>` (app or service)
  `adb shell settings put <scope> <key> <oldValue>` (use the revert helper’s recorded values)

If RCS/visual voicemail features broke, re-enable **Carrier Services** and your messaging app; then check **Messages → RCS status**. ([Google Help][4])

---

## 8) Troubleshooting (field-tested)

**ADB shows `unauthorized`/`offline`**
Re-plug cable, confirm RSA prompt, try another cable/port, or `adb kill-server && adb start-server`. ([Android Developers][11])

**USB debugging greyed out on Samsung**
Disable **Auto Blocker** at **Settings → Security & privacy → Auto Blocker**; then return to Developer options. ([Samsung it][12])

**No device found (multiple devices)**
Use the script’s selector or set `ANDROID_SERIAL=<device-serial>` and re-run.

**RCS not working after strict mode**
Re-enable **Carrier Services (`com.google.android.ims`)** and/or keep RCS via `--with rcs`. ([Google Help][4])

**Display rate changes don’t stick**
Some OEM builds clamp or ignore keys; confirm the device actually honors `MIN_REFRESH_RATE` / `PEAK_REFRESH_RATE`. ([Android Open Source Project][8])

**Settings revert “by themselves”**
Server-driven **device_config** may overwrite test values; temporarily freeze sync during testing. ([Android Open Source Project][10])

---

## 9) Advanced ADB appendix (handy references)

* **General ADB usage & shells**: Android Developer docs (install, connect, shell). ([Android Developers][11])
* **Per-user package state**: `pm disable/enable --user <id>`; discover users with `pm list users`; check current with `am get-current-user`. ([Android Open Source Project][2])
* **App Standby Buckets**: learn the concepts and how background access is limited per bucket (Android 9+). Use `am set-standby-bucket` for tests. ([Android Developers][5])
* **Data Saver & background policies**: `cmd netpolicy` (list, whitelist/blacklist, restrict-background). ([Android Open Source Project][6])
* **Private DNS (DoT)**: system supports `off | opportunistic | hostname` + host specifier; the script writes the corresponding settings keys. ([Cloudflare Docs][7])
* **Refresh-rate keys**: see AOSP notes on multiple refresh rates and System settings. ([Android Open Source Project][8])
* **ART/JIT/AOT**: background profiling (`bg-dexopt-job`) and compile modes. ([Android Open Source Project][9])

---

## 10) CSC (THL/EUX) notes & safe experimenting

* Region builds differ in preloads (Samsung TV Plus, Facebook services, Netflix activation, MS bundles, etc.). The de-Google script **skips** anything not present and logs it.
* **THL/EUX** messaging: if you rely on **RCS**, run `strict` with `--with rcs` or re-enable RCS bits after testing. ([Google Help][4])

---

## 11) Support & reproducibility checklists

When opening an issue or asking for help:

1. Re-run both scripts with `DRY_RUN=1` and attach the **latest** `actions.csv` + relevant `session.log` snippets.
2. Include One UI/Android versions, model (e.g., **SM-S928B**) and CSC (e.g., **THL/EUX**).
3. Describe which **preset + flags** you used and what broke (e.g., RCS registration, Wear sync, Wallet NFC).
4. If a setting didn’t “stick,” tell us whether **device_config** sync was frozen. ([Android Open Source Project][10])

---

### TL;DR quick recipes

```bash
# Strict but functional day-1
./s24u-degoogle.sh --mode strict --with push,store,sync

# Keep RCS (THL/EUX carriers using Google Messages)
./s24u-degoogle.sh --mode strict --with rcs

# Battery-lean, still smooth
DATA_SAVER=on REFRESH_MIN=60.0 REFRESH_MAX=120.0 WIFI_SCAN_THROTTLE=1 ./s24u-enhancements.sh

# Private DNS (DoT) – Cloudflare
PRIVATE_DNS_MODE=hostname PRIVATE_DNS_HOST=one.one.one.one ./s24u-enhancements.sh
```

---

**You’re set.** Start with a **dry-run**, read the logs, then apply gradually and keep the revert helpers close. Happy tuning!

```
::contentReference[oaicite:33]{index=33}
```

[1]: https://yamen.dev/posts/configure-private-dns-android-tv/?utm_source=chatgpt.com "Configuring Private DNS on Android TV - yamen.dev"
[2]: https://source.android.com/docs/devices/admin/multi-user-testing?utm_source=chatgpt.com "Test multiple users"
[3]: https://source.android.com/docs/core/permissions/android-roles?utm_source=chatgpt.com "Android roles"
[4]: https://support.google.com/messages/answer/7189714?hl=en&utm_source=chatgpt.com "Turn on RCS chats in Google Messages"
[5]: https://developer.android.com/topic/performance/appstandby?utm_source=chatgpt.com "App Standby Buckets | App quality"
[6]: https://source.android.com/docs/core/data/data-saver?utm_source=chatgpt.com "Data Saver mode"
[7]: https://developers.cloudflare.com/1.1.1.1/setup/android/?utm_source=chatgpt.com "Set up 1.1.1.1 on Android"
[8]: https://source.android.com/docs/core/graphics/multiple-refresh-rate?utm_source=chatgpt.com "Multiple refresh rate"
[9]: https://source.android.com/docs/core/runtime/jit-compiler?utm_source=chatgpt.com "Implement ART just-in-time compiler"
[10]: https://source.android.com/docs/core/connect/time?utm_source=chatgpt.com "Time overview"
[11]: https://developer.android.com/tools/adb?utm_source=chatgpt.com "Android Debug Bridge (adb) | Android Studio"
[12]: https://www.samsung.com/latin_en/support/mobile-devices/protect-your-galaxy-device-with-the-new-auto-blocker-feature/?utm_source=chatgpt.com "Protect your Galaxy device with the Auto Blocker feature"
