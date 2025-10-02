#!/usr/bin/env bash
# s24u-harden.sh — Harden Galaxy S24 Ultra (reversible, per-user) with modes & keep flags
# - Disables non-essential Google/Samsung/partner bloat *per user* (safe, reversible)
# - Preserves essentials like Play Services/Store/Sync and Samsung Pass by default
# - Modes: strict | balanced (default) | permissive
# - Keep flags: --with push,store,sync,rcs,wear,ar,tts,wallet,pass,health,galaxystore,sbrowser
# - Dry-run, device selector, SMS role guard, logging, generated re-enable script
#
# References:
#   - Per-user enable/disable (pm --user) & multi-user tools.  See AOSP docs.      [1]
#   - Android Roles API (e.g., SMS role) used for guardrails.                      [2]
#   - ADB device selection with ANDROID_SERIAL and device states.                 [3]
#
# [1] https://source.android.com/docs/devices/admin/multi-user-testing
# [2] https://source.android.com/docs/core/permissions/android-roles
# [3] https://developer.android.com/tools/adb

set -Eeuo pipefail
IFS=$'\n\t'
umask 077
shopt -s lastpipe

# --------------------------- Constants (readonly) --------------------------------
readonly SCRIPT_NAME="$(basename "$0")"
readonly TS="$(date +%Y%m%d-%H%M%S)"
readonly DEFAULT_MODE="balanced"         # strict|balanced|permissive
readonly DEFAULT_USER_ID="0"
readonly DEFAULT_OUTDIR="./adb-harden-${TS}"
readonly DEFAULT_DRYRUN="0"

# --------------------------- CLI -------------------------------------------------
MODE="${DEFAULT_MODE}"
USER_ID="${DEFAULT_USER_ID}"
OUTDIR="${DEFAULT_OUTDIR}"
DRY_RUN="${DEFAULT_DRYRUN}"
WITH_FLAGS=""                 # comma list: push,store,sync,rcs,wear,ar,tts,wallet,pass,health,galaxystore,sbrowser
LIST_TARGETS_ONLY="0"
NO_PROMPT="0"

usage() {
cat <<USAGE
Usage:
  ${SCRIPT_NAME} [--mode strict|balanced|permissive] [--user N] [--with list]
                 [--dry-run] [--list-targets] [--no-prompt] [--out DIR]

Options:
  --mode M           One of: strict | balanced (default) | permissive
  --user N           Android user id (default: ${DEFAULT_USER_ID})
  --with LIST        Comma list of features to KEEP (whitelist), e.g.:
                     push,store,sync,rcs,wear,ar,tts,wallet,pass,health,galaxystore,sbrowser
                     Note: In balanced/permissive, RCS and TTS are kept by default.
  --dry-run          Show actions, make no changes
  --list-targets     Only print packages that would be disabled and exit
  --no-prompt        Skip the safety confirmation
  --out DIR          Output dir for logs & re-enable helper (default: ${DEFAULT_OUTDIR})

Examples:
  ${SCRIPT_NAME} --mode strict --with push,store,sync,pass
  ${SCRIPT_NAME} --mode balanced --with rcs,wear
  ${SCRIPT_NAME} --mode permissive --with galaxystore,sbrowser
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="${2:-}"; shift 2;;
    --user) USER_ID="${2:-}"; shift 2;;
    --with) WITH_FLAGS="${2:-}"; shift 2;;
    --dry-run) DRY_RUN="1"; shift;;
    --list-targets) LIST_TARGETS_ONLY="1"; shift;;
    --no-prompt) NO_PROMPT="1"; shift;;
    --out) OUTDIR="${2:-}"; shift 2;;
    -h|--help) usage; exit 0;;
    *) printf "[ERROR] Unknown arg: %s\n" "$1" >&2; exit 1;;
  esac
done

# Freeze the parsed values
readonly MODE USER_ID OUTDIR DRY_RUN WITH_FLAGS LIST_TARGETS_ONLY NO_PROMPT

# --------------------------- Utilities ------------------------------------------
info(){ printf "[*] %s\n" "$*"; }
warn(){ printf "[!] %s\n" "$*" >&2; }
die(){  printf "[ERROR] %s\n" "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"; }

in_csv(){ # in_csv "needle" "a,b,c"
  local needle="$1" hay="$2"
  [[ ",${hay}," == *",$needle,"* ]]
}

ensure_outdir(){
  mkdir -p "${OUTDIR}"
  : > "${OUTDIR}/actions.csv"
  : > "${OUTDIR}/session.log"
  printf "package,group,action,status,message\n" > "${OUTDIR}/actions.csv"
}
readonly -f info warn die need in_csv ensure_outdir

# --------------------------- ADB & Device Selection -----------------------------
need adb
ensure_outdir

# Log stdout/err to session.log (while still showing live)
exec > >(tee -a "${OUTDIR}/session.log") 2>&1

# Robust device picker with tab delimiter to avoid whitespace parsing bugs.
select_device() {
  mapfile -t lines < <(adb devices | awk 'NR>1 && NF{print $1"\t"$2}')
  local count="${#lines[@]}"
  (( count == 0 )) && die "No device. Connect via USB and enable USB debugging."
  if (( count == 1 )); then
    local serial status
    IFS=$'\t' read -r serial status <<<"${lines[0]}"
    case "$status" in
      device) export ANDROID_SERIAL="$serial"; return;;
      unauthorized) die "Device state is 'unauthorized' — confirm the RSA fingerprint on the phone or revoke/reauthorize debugging.";;
      offline) die "Device state is 'offline' — reconnect cable, toggle USB, or restart adbd (adb kill-server; adb start-server).";;
      *) die "Device state is '$status' (authorize USB debugging).";;
    esac
  fi
  info "Multiple devices detected:"
  local i=1
  for l in "${lines[@]}"; do
    IFS=$'\t' read -r serial status <<<"$l"
    printf "  [%d] %s  (%s)\n" "$i" "$serial" "$status"; ((i++))
  done
  read -r -p "Select device [1-$count]: " pick
  [[ "$pick" =~ ^[0-9]+$ ]] || die "Invalid selection."
  local idx=$((pick-1)) serial status
  IFS=$'\t' read -r serial status <<<"${lines[$idx]}"
  [[ "$status" == "device" ]] || die "Selected device state is '$status'."
  export ANDROID_SERIAL="$serial"
}
readonly -f select_device

select_device
adb shell true >/dev/null 2>&1 || die "adb shell not reachable."

MODEL="$(adb shell getprop ro.product.model | tr -d '\r')"
DEVICE="$(adb shell getprop ro.product.device | tr -d '\r')"
ANDROID_VER="$(adb shell getprop ro.build.version.release | tr -d '\r')"
ONEUI="$(adb shell getprop ro.build.version.oneui 2>/dev/null | tr -d '\r' || true)"
info "Target: $MODEL ($DEVICE) Android $ANDROID_VER One UI ${ONEUI:-unknown} | user=${USER_ID} | mode=${MODE} | with=${WITH_FLAGS:-none} | dry-run=${DRY_RUN}"

# --------------------------- Inventories & helpers ------------------------------
REENABLE_SCRIPT="${OUTDIR}/reenable.sh"; : > "${REENABLE_SCRIPT}"; chmod +x "${REENABLE_SCRIPT}"

pkg_exists(){ adb shell "pm path $1" >/dev/null 2>&1; }
is_enabled(){ adb shell "cmd package list packages -e --user ${USER_ID} | grep -q \"^package:$1$\"" >/dev/null 2>&1; }
readonly -f pkg_exists is_enabled

disable_pkg(){
  local pkg="$1" group="$2"
  if ! pkg_exists "$pkg"; then
    info "Skip (not installed): $pkg"
    printf "%s,%s,disable,skip,not-installed\n" "$pkg" "$group" >> "${OUTDIR}/actions.csv"
    return
  fi
  if [[ "${DRY_RUN}" == "1" ]]; then
    info "DRY-RUN disable: $pkg"
    printf "%s,%s,disable,dry-run,\n" "$pkg" "$group" >> "${OUTDIR}/actions.csv"
    return
  fi
  if adb shell "pm disable-user --user ${USER_ID} $pkg" >/dev/null 2>&1; then
    info "Disabled: $pkg"
    printf "%s,%s,disable,ok,\n" "$pkg" "$group" >> "${OUTDIR}/actions.csv"
    echo "adb shell pm enable --user ${USER_ID} $pkg" >> "${REENABLE_SCRIPT}"
  else
    warn "Failed to disable (policy/permission?): $pkg"
    printf "%s,%s,disable,fail,policy\n" "$pkg" "$group" >> "${OUTDIR}/actions.csv"
  fi
}
readonly -f disable_pkg

# --------------------------- Guardrails (never touch) --------------------------
# Essentials (telephony, contacts, messaging, UI, WebView, Play core, Samsung Pass, etc.)
# Keep Play Services + Store + Sync + Samsung Pass by default for compatibility/usability.
PROTECT_LIST=(
  # Core Android / UI
  android com.android.systemui com.android.settings com.android.providers.settings
  com.android.phone com.android.server.telecom com.android.providers.telephony
  com.android.providers.contacts com.android.providers.media com.android.providers.calendar
  com.android.providers.downloads com.android.providers.userdictionary
  com.android.packageinstaller com.android.shell com.android.externalstorage
  com.android.documentsui com.android.vpndialogs com.android.se com.android.nfc com.samsung.android.nfc
  com.android.location.fused com.android.printspooler com.android.certinstaller
  com.android.inputdevices com.android.intentresolver com.android.htmlviewer
  com.android.uwb.resources com.android.wifi.resources

  # Samsung core / launcher / dialer / messaging / contacts / camera / gallery
  com.sec.android.app.launcher com.samsung.android.dialer com.samsung.android.messaging
  com.samsung.android.contacts com.samsung.android.providers.contacts
  com.sec.android.app.camera com.sec.android.gallery3d com.samsung.android.calendar
  com.sec.android.app.myfiles

  # Network / IMS / Calling (do NOT touch unless you know exactly what you are doing)
  com.sec.imsservice com.sec.imslogger com.sec.sve com.sec.unifiedwfc com.sec.epdg com.sec.nrsaentitlement
  com.qualcomm.location com.qualcomm.qti.services.systemhelper

  # Play Services/Store/GSF/Sync (compatibility & login)
  com.google.android.gms com.android.vending com.google.android.gsf
  com.google.android.syncadapters.contacts com.google.android.syncadapters.calendar

  # System WebView & related
  com.google.android.webview com.android.webview

  # Emergency/cell broadcast (keep for safety)
  com.google.android.cellbroadcastservice com.google.android.cellbroadcastreceiver

  # Samsung Pass & Autofill, Wallet framework
  com.samsung.android.samsungpass com.samsung.android.samsungpassautofill
  com.samsung.android.spayfw

  # Galaxy Store (often needed for Samsung app updates)
  com.sec.android.app.samsungapps
)

# --------------------------- Role guard (SMS) -----------------------------------
# If Google Messages holds the SMS role and would be disabled, warn user first.
sms_role_holders="$(adb shell 'cmd role holders android.app.role.SMS' 2>/dev/null | tr -d '\r' || true)"
readonly sms_role_holders
# (Docs on roles: see AOSP roles/RoleManager.)  # Ref: [2]

# --------------------------- Feature keep-whitelist -----------------------------
KEEP_PUSH=$( in_csv "push" "${WITH_FLAGS}" && echo 1 || echo 0 )
KEEP_STORE=$( in_csv "store" "${WITH_FLAGS}" && echo 1 || echo 0 )
KEEP_SYNC=$( in_csv "sync" "${WITH_FLAGS}" && echo 1 || echo 0 )
KEEP_RCS=$( in_csv "rcs" "${WITH_FLAGS}" && echo 1 || echo 0 )
KEEP_WEAR=$( in_csv "wear" "${WITH_FLAGS}" && echo 1 || echo 0 )
KEEP_AR=$( in_csv "ar" "${WITH_FLAGS}" && echo 1 || echo 0 )
KEEP_TTS=$( in_csv "tts" "${WITH_FLAGS}" && echo 1 || echo 0 )
KEEP_WALLET=$( in_csv "wallet" "${WITH_FLAGS}" && echo 1 || echo 0 )
KEEP_PASS=$( in_csv "pass" "${WITH_FLAGS}" && echo 1 || echo 0 )
KEEP_HEALTH=$( in_csv "health" "${WITH_FLAGS}" && echo 1 || echo 0 )
KEEP_GALAXYSTORE=$( in_csv "galaxystore" "${WITH_FLAGS}" && echo 1 || echo 0 )
KEEP_SBROWSER=$( in_csv "sbrowser" "${WITH_FLAGS}" && echo 1 || echo 0 )

# Ensure defaults are kept regardless of flags (push/store/sync/pass are already protected)
: "${KEEP_PUSH:=1}" ; : "${KEEP_STORE:=1}" ; : "${KEEP_SYNC:=1}" ; : "${KEEP_PASS:=1}"

# Safer defaults: Keep RCS + TTS in non-strict modes unless explicitly overridden
if [[ "$MODE" != "strict" ]]; then
  [[ "$KEEP_RCS" == "1" ]] || KEEP_RCS=1
  [[ "$KEEP_TTS" == "1" ]] || KEEP_TTS=1
fi

readonly KEEP_PUSH KEEP_STORE KEEP_SYNC KEEP_RCS KEEP_WEAR KEEP_AR KEEP_TTS KEEP_WALLET KEEP_PASS KEEP_HEALTH KEEP_GALAXYSTORE KEEP_SBROWSER

# --------------------------- Target groups (only acted on if installed) --------
# Google consumer apps & assistants (safe to disable if you don't use them)
GOOGLE_APPS=( com.google.android.gm com.google.android.apps.maps com.google.android.apps.photos
  com.google.android.youtube com.google.android.apps.youtube.music com.android.chrome
  com.google.android.apps.docs com.google.android.videos com.google.android.googlequicksearchbox
  com.android.hotwordenrollment.okgoogle com.android.hotwordenrollment.xgoogle
  com.google.android.apps.bard com.google.android.apps.turbo
)
# Optional Google services/features (kept if flags request)
GOOGLE_OPTIONAL=( com.google.ar.core com.google.android.tts
  com.google.android.projection.gearhead com.google.android.apps.wear.companion
  com.google.android.ims    # Carrier Services (RCS)
  com.google.android.apps.messaging   # Google Messages
)
# Samsung consumer/experience (often removable)
SAMSUNG_BLOAT=( com.samsung.android.app.tips com.samsung.android.app.spage     # Samsung Free
  com.samsung.android.tvplus com.samsung.sree                                 # TV Plus, Global Goals
  com.samsung.android.game.gamehome com.samsung.android.game.gametools com.samsung.android.game.gos
  com.samsung.android.aremoji com.samsung.android.arzone com.samsung.android.aremojieditor
  com.sec.android.app.kidshome com.samsung.android.kidsinstaller
  com.sec.android.app.quicktool com.samsung.mediasearch com.samsung.ecomm.global.gbr
  com.samsung.android.app.parentalcare com.samsung.android.app.readingglass
  com.samsung.android.app.routines    # Bixby Routines (optional)
  com.samsung.android.smartmirroring  # Smart View
  com.samsung.android.aicore          # AI Wallpapers/AICore dependencies vary by build
)
# Bixby stack
SAMSUNG_BIXBY=( com.samsung.android.bixby.agent com.samsung.android.bixby.wakeup
  com.samsung.android.bixbyvision.framework com.samsung.android.visionintelligence
  com.samsung.android.intellivoiceservice
)
# Samsung cloud/oneconnect (optional)
SAMSUNG_SERVICES_OPTIONAL=( com.samsung.android.oneconnect com.samsung.android.scloud
  com.samsung.android.fmm  # Find My Mobile (KEEP if you use FMM)
)
# Partner preloads
PARTNER_PRELOADS=( com.facebook.katana com.facebook.appmanager com.facebook.services com.facebook.system
  com.linkedin.android com.netflix.mediaclient com.microsoft.skydrive com.microsoft.office.officehubrow
  com.microsoft.office.outlook com.spotify.music com.hiya.star
)
# Extras many users disable for privacy/telemetry (use caution; leave core intact)
OEM_TELEMETRY_LIGHT=( com.sec.android.diagmonagent com.samsung.android.dqagent )

readonly GOOGLE_APPS GOOGLE_OPTIONAL SAMSUNG_BLOAT SAMSUNG_BIXBY SAMSUNG_SERVICES_OPTIONAL PARTNER_PRELOADS OEM_TELEMETRY_LIGHT

# --------------------------- Mode → target selection ---------------------------
TARGETS=()
append_targets(){ local -n arr="$1"; TARGETS+=("${arr[@]}"); }
readonly -f append_targets

case "${MODE}" in
  strict)
    append_targets GOOGLE_APPS
    append_targets GOOGLE_OPTIONAL         # <-- included
    append_targets SAMSUNG_BLOAT
    append_targets SAMSUNG_BIXBY
    append_targets PARTNER_PRELOADS
    append_targets OEM_TELEMETRY_LIGHT
    append_targets SAMSUNG_SERVICES_OPTIONAL
    ;;
  balanced)
    append_targets GOOGLE_APPS
    append_targets GOOGLE_OPTIONAL         # <-- included
    append_targets SAMSUNG_BLOAT
    append_targets SAMSUNG_BIXBY
    append_targets PARTNER_PRELOADS
    append_targets OEM_TELEMETRY_LIGHT
    ;;
  permissive)
    append_targets SAMSUNG_BLOAT
    append_targets SAMSUNG_BIXBY
    append_targets PARTNER_PRELOADS
    ;;
  *) die "Unsupported --mode '${MODE}' (use strict|balanced|permissive)";;
esac
readonly TARGETS

# --------------------------- Apply keep flags (remove from TARGETS) ------------
FILTERED_TARGETS=()
for p in "${TARGETS[@]}"; do
  # Autobypass if in protect list
  if printf '%s\n' "${PROTECT_LIST[@]}" | grep -qx "${p}"; then
    continue
  fi
  # Keep feature gates
  case "${p}" in
    com.google.android.ims|com.google.android.apps.messaging)
      [[ "${KEEP_RCS}" == "1" ]] && continue;;
    com.google.android.projection.gearhead|com.google.android.apps.wear.companion)
      [[ "${KEEP_WEAR}" == "1" ]] && continue;;
    com.google.ar.core)
      [[ "${KEEP_AR}" == "1" ]] && continue;;
    com.google.android.tts)
      [[ "${KEEP_TTS}" == "1" ]] && continue;;
    com.samsung.android.spayfw)
      [[ "${KEEP_WALLET}" == "1" ]] && continue;;
    com.samsung.android.samsungpass|com.samsung.android.samsungpassautofill)
      [[ "${KEEP_PASS}" == "1" ]] && continue;;
    com.sec.android.app.samsungapps)
      [[ "${KEEP_GALAXYSTORE}" == "1" ]] && continue;;
    com.sec.android.app.sbrowser)
      [[ "${KEEP_SBROWSER}" == "1" ]] && continue;;
    com.sec.android.app.shealth|com.sec.android.app.shealthlite|com.sec.android.app.shealthservice|com.sec.android.app.service.health)
      [[ "${KEEP_HEALTH}" == "1" ]] && continue;;
  esac
  FILTERED_TARGETS+=("$p")
done

# If SMS role is held by Google Messages and Messages is in targets, warn
if echo "${sms_role_holders}" | grep -q "com.google.android.apps.messaging" &&
   printf '%s\n' "${FILTERED_TARGETS[@]}" | grep -q "^com.google.android.apps.messaging$"; then
  warn "Google Messages currently holds the SMS role. Disabling it will break SMS until you switch the default SMS app."
  if [[ "${NO_PROMPT}" != "1" ]]; then
    read -r -p "Type 'SWITCHED_SMS' after you change default SMS app (or 'CONTINUE' to proceed): " SMS_ACK
    [[ "$SMS_ACK" =~ ^(SWITCHED_SMS|CONTINUE)$ ]] || die "Aborting."
  fi
fi

# Safety confirmation
if [[ "${NO_PROMPT}" != "1" ]]; then
  echo "================================================================================"
  echo " HARDEN (reversible) will DISABLE per-user the following categories in MODE=${MODE}:"
  echo "   - Google consumer apps, Bixby stack, Samsung 'Free/TV Plus/AR/Game' bits, partner preloads"
  echo "   - Telemetry-lite (diag agents) — core telephony/IMS not touched"
  echo " Kept by default: Play Services/Store/GSF/Sync, Samsung Pass (+Autofill), WebView, core UI."
  echo " Keep flags: ${WITH_FLAGS:-<none>}"
  echo " DRY_RUN=${DRY_RUN}  USER=${USER_ID}  OUTDIR=${OUTDIR}"
  echo "================================================================================"
  read -r -p "Type 'I UNDERSTAND' to proceed: " ACK
  [[ "$ACK" == "I UNDERSTAND" ]] || die "Aborted by user."
fi

# --------------------------- Resolve installed + (optional) preview -------------
INSTALLED_TARGETS=()
for p in "${FILTERED_TARGETS[@]}"; do
  if pkg_exists "$p"; then INSTALLED_TARGETS+=("$p"); fi
done
readonly INSTALLED_TARGETS

if [[ "${LIST_TARGETS_ONLY}" == "1" ]]; then
  printf "%s\n" "${INSTALLED_TARGETS[@]}" | LC_ALL=C sort -u
  exit 0
fi

# --------------------------- Execute -------------------------------------------
for p in "${INSTALLED_TARGETS[@]}"; do
  group="harden"
  # Tag groups more specifically for your logs
  if [[ " ${GOOGLE_APPS[*]} " == *" $p "* ]]; then group="google-apps"; fi
  if [[ " ${GOOGLE_OPTIONAL[*]} " == *" $p "* ]]; then group="google-optional"; fi
  if [[ " ${SAMSUNG_BLOAT[*]} " == *" $p "* ]]; then group="samsung-bloat"; fi
  if [[ " ${SAMSUNG_BIXBY[*]} " == *" $p "* ]]; then group="bixby"; fi
  if [[ " ${PARTNER_PRELOADS[*]} " == *" $p "* ]]; then group="partner"; fi
  if [[ " ${OEM_TELEMETRY_LIGHT[*]} " == *" $p "* ]]; then group="telemetry-lite"; fi
  disable_pkg "$p" "$group"
done

# Inventory snapshot for your records
adb shell "cmd package list packages --user ${USER_ID}" | sed 's/\r$//' \
  > "${OUTDIR}/packages-enabled-${USER_ID}.txt"
adb shell "cmd package list packages -d --user ${USER_ID}" | sed 's/\r$//' \
  > "${OUTDIR}/packages-disabled-${USER_ID}.txt"

echo "================================================================================"
echo " Done. Artifacts in: ${OUTDIR}"
echo "   - Re-enable helper: ${REENABLE_SCRIPT}"
echo "   - Actions CSV     : ${OUTDIR}/actions.csv"
echo "   - Enabled list    : ${OUTDIR}/packages-enabled-${USER_ID}.txt"
echo "   - Disabled list   : ${OUTDIR}/packages-disabled-${USER_ID}.txt"
echo " Reboot recommended. To revert everything from this run:"
echo "   ${REENABLE_SCRIPT}"
echo "================================================================================"
