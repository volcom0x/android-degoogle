#!/usr/bin/env bash
# ==============================================================================
#  adbx-harden-s24u.sh — Harden Galaxy S24 Ultra (reversible, per-user)
#  - Uses adbx (if present) or adb+serial picker, never requires root on host
#  - Modes: strict | balanced (default) | permissive
#  - Per-user disable with full revert helper, CSV logs, and package snapshots
#  - Protects essential telephony/IMS, core Android, Play Services/Store/GSF/Sync,
#    System WebView, Samsung Pass & Wallet, launcher/dialer/messaging/contacts/camera
#  - Protected items can only be disabled if explicitly listed in --allow-core FILE
#  - Safety guards: SMS Role check, unauthorized/offline device checks
#
#  References:
#   - Roles/SMS guard: RoleManager roles (SMS role) — Android docs
#   - Multi-user model & pm --user: AOSP multi-user docs
#   - AppOps/Package management: Android docs
#   - Samsung Wallet & Samsung Pass purpose: official Samsung pages
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 077
shopt -s lastpipe

# --------------------------- Defaults ------------------------------------------
readonly SCRIPT_NAME="$(basename "$0")"
readonly TS="$(date +%Y%m%d-%H%M%S)"

MODE="balanced"            # strict|balanced|permissive
USER_ID="0"
OUTDIR="./adb-harden-${TS}"
DRY_RUN="0"
LIST_TARGETS_ONLY="0"
NO_PROMPT="0"

WITH_FLAGS=""              # comma list to KEEP (non-core only): push,store,sync,rcs,wear,ar,tts,galaxystore,sbrowser,health
ALLOW_CORE_FILE=""         # a file containing package names that are allowed to bypass PROTECT_LIST (dangerous!)
ADB_BIN="${ADB_BIN:-}"     # prefer adbx if healthy; else set to adb with -s SERIAL

# --------------------------- CLI -----------------------------------------------
usage() {
  cat <<USAGE
Usage:
  ${SCRIPT_NAME} [--mode strict|balanced|permissive] [--user N]
                 [--with LIST] [--allow-core FILE]
                 [--dry-run] [--list-targets] [--no-prompt]
                 [--out DIR]

Options:
  --mode M        : strict | balanced (default) | permissive
  --user N        : Android user id (default: 0)
  --with LIST     : Comma list of NON-CORE features to KEEP:
                    push,store,sync,rcs,wear,ar,tts,galaxystore,sbrowser,health
                    (Core items like telephony/IMS/Play/Pass/Wallet are protected regardless.)
  --allow-core F  : File with package names to ALLOW disabling even if protected (dangerous).
                    One package per line; lines starting with '#' are ignored.
  --dry-run       : Show actions only
  --list-targets  : Print resolved disable targets and exit (no changes)
  --no-prompt     : Skip confirmation prompt
  --out DIR       : Output dir (default: ./adb-harden-<timestamp>)

Examples:
  ${SCRIPT_NAME} --mode strict --with push,store,sync --user 0
  ${SCRIPT_NAME} --mode balanced --with rcs,wear,tts --out ./out
  ${SCRIPT_NAME} --mode strict --allow-core ./i-really-mean-it.txt --no-prompt
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="${2:-}"; shift 2;;
    --user) USER_ID="${2:-}"; shift 2;;
    --with) WITH_FLAGS="${2:-}"; shift 2;;
    --allow-core) ALLOW_CORE_FILE="${2:-}"; shift 2;;
    --dry-run) DRY_RUN="1"; shift;;
    --list-targets) LIST_TARGETS_ONLY="1"; shift;;
    --no-prompt) NO_PROMPT="1"; shift;;
    --out) OUTDIR="${2:-}"; shift 2;;
    -h|--help) usage; exit 0;;
    *) printf "[ERROR] Unknown arg: %s\n" "$1" >&2; exit 1;;
  esac
done

readonly MODE USER_ID OUTDIR DRY_RUN LIST_TARGETS_ONLY NO_PROMPT WITH_FLAGS ALLOW_CORE_FILE

# --------------------------- Utilities ------------------------------------------
info(){ printf "[*] %s\n" "$*"; }
warn(){ printf "[!] %s\n" "$*" >&2; }
die(){  printf "[ERROR] %s\n" "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"; }
in_csv(){ local needle="$1" hay="$2"; [[ ",${hay}," == *",$needle,"* ]]; }

ensure_outdir(){
  mkdir -p "${OUTDIR}"
  printf "package,group,action,status,message\n" > "${OUTDIR}/actions.csv"
  : > "${OUTDIR}/session.log"
}
ensure_outdir
exec > >(tee -a "${OUTDIR}/session.log") 2>&1

need awk
need grep
need sed
need tr

# --------------------------- ADB/adbx selection --------------------------------
pick_with_adb(){
  # Robust device picker with tab delimiter
  mapfile -t lines < <(adb devices | awk 'NR>1 && NF{print $1"\t"$2}')
  local count="${#lines[@]}"
  (( count == 0 )) && die "No device. Connect via USB and enable USB debugging."
  if (( count == 1 )); then
    local serial status
    IFS=$'\t' read -r serial status <<<"${lines[0]}"
    case "$status" in
      device) export ANDROID_SERIAL="$serial";;
      unauthorized) die "Device is 'unauthorized' — confirm RSA prompt on the phone (Developer options → USB debugging).";;
      offline) die "Device is 'offline' — reconnect cable, toggle USB mode, or restart adbd (adb kill-server; adb start-server).";;
      *) die "Device state is '$status'";;
    esac
  else
    info "Multiple devices detected:"
    local i=1
    for l in "${lines[@]}"; do
      IFS=$'\t' read -r serial status <<<"$l"
      printf "  [%d] %s  (%s)\n" "$i" "$serial" "$status"; ((i++))
    done
    read -r -p "Select device [1-$count]: " pick
    [[ "$pick" =~ ^[0-9]+$ ]] || die "Invalid selection."
    local idx=$((pick-1))
    IFS=$'\t' read -r serial status <<<"${lines[$idx]}"
    [[ "$status" == "device" ]] || die "Selected device state: '$status'"
    export ANDROID_SERIAL="$serial"
  fi
  ADB_BIN="adb -s ${ANDROID_SERIAL}"
}

# Prefer adbx if present & healthy
if command -v adbx >/dev/null 2>&1; then
  if adbx get-state >/dev/null 2>&1; then
    ADB_BIN="adbx"
    info "Using ADB: $(command -v adbx)"
  else
    warn "adbx found but not healthy; falling back to adb."
  fi
fi
if [[ -z "${ADB_BIN}" ]]; then
  need adb
  adb start-server >/dev/null 2>&1 || true
  pick_with_adb
  info "Using ADB: ${ADB_BIN}"
fi

ADB(){ ${ADB_BIN} "$@"; }

# Quick reachability
ADB shell true >/dev/null 2>&1 || die "ADB shell not reachable."

# Device info
MODEL="$(ADB shell getprop ro.product.model | tr -d '\r')"
DEVICE="$(ADB shell getprop ro.product.device | tr -d '\r')"
ANDROID_VER="$(ADB shell getprop ro.build.version.release | tr -d '\r')"
ONEUI="$(ADB shell getprop ro.build.version.oneui 2>/dev/null | tr -d '\r' || true)"
SERIAL="$(ADB get-serialno 2>/dev/null || echo unknown)"
info "Target: $MODEL ($DEVICE) Android $ANDROID_VER One UI ${ONEUI:-unknown} | serial=${SERIAL} | user=${USER_ID} | mode=${MODE} | dry-run=${DRY_RUN}"

# --------------------------- Helpers -------------------------------------------
pkg_exists(){ ADB shell "pm path $1" >/dev/null 2>&1; }
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
  if ADB shell "pm disable-user --user ${USER_ID} $pkg" >/dev/null 2>&1; then
    info "Disabled: $pkg"
    printf "%s,%s,disable,ok,\n" "$pkg" "$group" >> "${OUTDIR}/actions.csv"
    echo "${ADB_BIN} shell pm enable --user ${USER_ID} $pkg" >> "${OUTDIR}/reenable.sh"
  else
    warn "Failed to disable: $pkg"
    printf "%s,%s,disable,fail,\n" "$pkg" "$group" >> "${OUTDIR}/actions.csv"
  fi
}

# --------------------------- Core protections (always protected) ----------------
# These are critical for basic phone function, identity, payments or security.
# They are NEVER disabled unless explicitly listed in --allow-core FILE.
PROTECT_LIST=(
  # Core Android / UI / Settings / Storage / Shell / DocsUI
  android com.android.systemui com.android.settings com.android.providers.settings
  com.android.externalstorage com.android.documentsui com.android.vpndialogs
  com.android.inputdevices com.android.intentresolver com.android.proxyhandler
  com.android.wifi.resources com.android.uwb.resources com.android.se com.android.nfc
  com.android.printspooler com.android.mtp com.android.location.fused

  # Telephony/IMS (calling, SMS, VoLTE/VoWiFi/WFC)
  com.android.phone com.android.server.telecom com.android.providers.telephony
  com.sec.imsservice com.sec.imslogger com.sec.sve com.sec.unifiedwfc com.sec.epdg
  com.sec.nrsaentitlement com.sec.phone com.samsung.android.app.telephonyui

  # Contacts/Messages framework bits (Samsung core apps left functional)
  com.samsung.android.contacts com.samsung.android.messaging com.samsung.android.dialer
  com.samsung.android.providers.contacts

  # Camera/Gallery/Files (core media)
  com.sec.android.app.camera com.sec.android.gallery3d com.sec.android.app.myfiles

  # Google Play stack (login, services, sync) — keep for app compatibility
  com.google.android.gms com.android.vending com.google.android.gsf
  com.google.android.syncadapters.contacts com.google.android.syncadapters.calendar

  # WebView (system web rendering)
  com.google.android.webview com.android.webview

  # Emergency/CB
  com.google.android.cellbroadcastservice com.google.android.cellbroadcastreceiver

  # Samsung Pass (biometrics autofill) & Samsung Wallet framework
  com.samsung.android.samsungpass com.samsung.android.samsungpassautofill com.samsung.android.spayfw

  # Launcher (One UI Home)
  com.sec.android.app.launcher
)

# --------------------------- Allow-core overrides (dangerous) -------------------
if [[ -n "${ALLOW_CORE_FILE}" && -f "${ALLOW_CORE_FILE}" ]]; then
  info "Loading allow-core overrides from: ${ALLOW_CORE_FILE}"
  mapfile -t ALLOW_CORE < <(sed -e 's/#.*$//' -e 's/^[[:space:]]*//;s/[[:space:]]*$//' "${ALLOW_CORE_FILE}" | awk 'NF>0' | sort -u)
else
  ALLOW_CORE=()
fi

is_protected(){
  local p="$1"
  # return 0 if protected, 1 otherwise
  if printf '%s\n' "${ALLOW_CORE[@]}" | grep -qx -- "$p"; then
    return 1  # explicitly allowed to be disabled
  fi
  printf '%s\n' "${PROTECT_LIST[@]}" | grep -qx -- "$p"
}

# --------------------------- Keep flags (non-core only) -------------------------
KEEP_PUSH=$( in_csv "push" "${WITH_FLAGS}" && echo 1 || echo 0 )
KEEP_STORE=$( in_csv "store" "${WITH_FLAGS}" && echo 1 || echo 0 )
KEEP_SYNC=$( in_csv "sync" "${WITH_FLAGS}" && echo 1 || echo 0 )
KEEP_RCS=$( in_csv "rcs" "${WITH_FLAGS}" && echo 1 || echo 0 )
KEEP_WEAR=$( in_csv "wear" "${WITH_FLAGS}" && echo 1 || echo 0 )
KEEP_AR=$( in_csv "ar" "${WITH_FLAGS}" && echo 1 || echo 0 )
KEEP_TTS=$( in_csv "tts" "${WITH_FLAGS}" && echo 1 || echo 0 )
KEEP_GALAXYSTORE=$( in_csv "galaxystore" "${WITH_FLAGS}" && echo 1 || echo 0 )
KEEP_SBROWSER=$( in_csv "sbrowser" "${WITH_FLAGS}" && echo 1 || echo 0 )
KEEP_HEALTH=$( in_csv "health" "${WITH_FLAGS}" && echo 1 || echo 0 )

# Defaults for convenience (these are NOT core)
if [[ "$MODE" != "strict" ]]; then
  [[ "$KEEP_RCS" == "1" ]] || KEEP_RCS=1
  [[ "$KEEP_TTS" == "1" ]] || KEEP_TTS=1
fi

# --------------------------- Target groups (disable candidates) -----------------
# Google consumer apps & assistants
GOOGLE_APPS=(
  com.google.android.gm com.google.android.apps.maps com.google.android.apps.photos
  com.google.android.youtube com.google.android.apps.youtube.music com.android.chrome
  com.google.android.apps.docs com.google.android.videos com.google.android.googlequicksearchbox
  com.android.hotwordenrollment.okgoogle com.android.hotwordenrollment.xgoogle
  com.google.android.apps.bard com.google.android.apps.turbo
)
# Optional Google services/features (kept with flags)
GOOGLE_OPTIONAL=(
  com.google.ar.core com.google.android.tts
  com.google.android.projection.gearhead com.google.android.apps.wear.companion
  com.google.android.ims                        # Carrier Services (RCS)
  com.google.android.apps.messaging             # Google Messages
)

# Samsung consumer/experience
SAMSUNG_BLOAT=(
  com.samsung.android.app.tips com.samsung.android.app.spage     # Samsung Free
  com.samsung.android.tvplus com.samsung.sree
  com.samsung.android.game.gamehome com.samsung.android.game.gametools com.samsung.android.game.gos
  com.samsung.android.aremoji com.samsung.android.arzone com.samsung.android.aremojieditor
  com.sec.android.app.kidshome com.samsung.android.kidsinstaller
  com.sec.android.app.quicktool com.samsung.mediasearch com.samsung.ecomm.global.gbr
  com.samsung.android.app.parentalcare com.samsung.android.app.readingglass
  com.samsung.android.app.routines
  com.samsung.android.smartmirroring
  com.samsung.android.aicore
)
# Bixby
SAMSUNG_BIXBY=(
  com.samsung.android.bixby.agent com.samsung.android.bixby.wakeup
  com.samsung.android.bixbyvision.framework com.samsung.android.visionintelligence
  com.samsung.android.intellivoiceservice
)
# Services (optional)
SAMSUNG_SERVICES_OPTIONAL=( com.samsung.android.oneconnect com.samsung.android.scloud com.samsung.android.fmm )
# Partner preloads
PARTNER_PRELOADS=(
  com.facebook.katana com.facebook.appmanager com.facebook.services com.facebook.system
  com.linkedin.android com.netflix.mediaclient com.microsoft.skydrive
  com.microsoft.office.officehubrow com.microsoft.office.outlook
  com.spotify.music com.hiya.star
)
# Light telemetry/diag
OEM_TELEMETRY_LIGHT=( com.sec.android.diagmonagent com.samsung.android.dqagent )

append_targets(){ local -n arr="$1"; TARGETS+=("${arr[@]}"); }

TARGETS=()
case "${MODE}" in
  strict)
    append_targets GOOGLE_APPS
    append_targets GOOGLE_OPTIONAL
    append_targets SAMSUNG_BLOAT
    append_targets SAMSUNG_BIXBY
    append_targets PARTNER_PRELOADS
    append_targets OEM_TELEMETRY_LIGHT
    append_targets SAMSUNG_SERVICES_OPTIONAL
    ;;
  balanced)
    append_targets GOOGLE_APPS
    append_targets GOOGLE_OPTIONAL
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

# --------------------------- Filter by keep flags & protection ------------------
FILTERED_TARGETS=()
for p in "${TARGETS[@]}"; do
  # Skip protected unless overridden
  if is_protected "$p"; then
    continue
  fi
  case "$p" in
    com.google.android.ims|com.google.android.apps.messaging)
      [[ "${KEEP_RCS}" == "1" ]] && continue;;
    com.google.android.projection.gearhead|com.google.android.apps.wear.companion)
      [[ "${KEEP_WEAR}" == "1" ]] && continue;;
    com.google.ar.core)
      [[ "${KEEP_AR}" == "1" ]] && continue;;
    com.google.android.tts)
      [[ "${KEEP_TTS}" == "1" ]] && continue;;
    com.sec.android.app.samsungapps)
      [[ "${KEEP_GALAXYSTORE}" == "1" ]] && continue;;
    com.sec.android.app.sbrowser)
      [[ "${KEEP_SBROWSER}" == "1" ]] && continue;;
    com.sec.android.app.shealth|com.sec.android.app.shealthlite|com.sec.android.app.shealthservice|com.sec.android.app.service.health)
      [[ "${KEEP_HEALTH}" == "1" ]] && continue;;
  esac
  FILTERED_TARGETS+=("$p")
done

# --------------------------- SMS Role guard -------------------------------------
SMS_ROLE="$(ADB shell 'cmd role holders android.app.role.SMS' 2>/dev/null | tr -d '\r' || true)"
if echo "${SMS_ROLE}" | grep -q "com.google.android.apps.messaging" &&
   printf '%s\n' "${FILTERED_TARGETS[@]}" | grep -q "^com.google.android.apps.messaging$"; then
  warn "Google Messages currently holds the SMS role. Disabling it will break SMS until you change the default SMS app."
  [[ "${NO_PROMPT}" == "1" ]] || { read -r -p "Type 'SWITCHED_SMS' after changing default SMS app, or 'CONTINUE' to proceed: " ACK; [[ "$ACK" =~ ^(SWITCHED_SMS|CONTINUE)$ ]] || die "Aborted."; }
fi

# --------------------------- Confirm -------------------------------------------
echo "================================================================================"
echo " HARDEN (reversible) will DISABLE per-user the following categories in MODE=${MODE}:"
echo "   - Google consumer apps, Bixby stack, Samsung 'Free/TV Plus/AR/Game' bits, partner preloads"
echo "   - Telemetry-lite (diag agents) — core telephony/IMS & essentials are PROTECTED"
echo " Kept by default (protected): Play Services/Store/GSF/Sync, WebView, Samsung Pass & Wallet,"
echo "   telephony/IMS, launcher/dialer/messaging/contacts/camera/gallery/myfiles."
[[ -n "${ALLOW_CORE_FILE}" ]] && echo " Allow-core file: ${ALLOW_CORE_FILE} (may override protections for listed packages)."
echo " DRY_RUN=${DRY_RUN}  USER=${USER_ID}  OUTDIR=${OUTDIR}"
echo "================================================================================"
if [[ "${NO_PROMPT}" != "1" ]]; then
  read -r -p "Type 'I UNDERSTAND' to proceed: " ACK
  [[ "$ACK" == "I UNDERSTAND" ]] || die "Aborted by user."
fi

# --------------------------- Resolve installed targets --------------------------
INSTALLED_TARGETS=()
for p in "${FILTERED_TARGETS[@]}"; do
  pkg_exists "$p" && INSTALLED_TARGETS+=("$p")
done

# Preview only?
if [[ "${LIST_TARGETS_ONLY}" == "1" ]]; then
  printf "%s\n" "${INSTALLED_TARGETS[@]}" | LC_ALL=C sort -u
  exit 0
fi

# --------------------------- Re-enable helper -----------------------------------
REENABLE="${OUTDIR}/reenable.sh"
printf "#!/usr/bin/env bash\nset -Eeuo pipefail\n" > "${REENABLE}"
chmod +x "${REENABLE}"

# --------------------------- Execute --------------------------------------------
for p in "${INSTALLED_TARGETS[@]}"; do
  group="harden"
  [[ " ${GOOGLE_APPS[*]} " == *" $p "* ]] && group="google-apps"
  [[ " ${GOOGLE_OPTIONAL[*]} " == *" $p "* ]] && group="google-optional"
  [[ " ${SAMSUNG_BLOAT[*]} " == *" $p "* ]] && group="samsung-bloat"
  [[ " ${SAMSUNG_BIXBY[*]} " == *" $p "* ]] && group="bixby"
  [[ " ${PARTNER_PRELOADS[*]} " == *" $p "* ]] && group="partner"
  [[ " ${OEM_TELEMETRY_LIGHT[*]} " == *" $p "* ]] && group="telemetry-lite"
  [[ " ${SAMSUNG_SERVICES_OPTIONAL[*]} " == *" $p "* ]] && group="samsung-services"
  disable_pkg "$p" "$group"
done

# Snapshots
ADB shell "cmd package list packages --user ${USER_ID}" | sed 's/\r$//' \
  > "${OUTDIR}/packages-enabled-${USER_ID}.txt" || true
ADB shell "cmd package list packages -d --user ${USER_ID}" | sed 's/\r$//' \
  > "${OUTDIR}/packages-disabled-${USER_ID}.txt" || true

echo "================================================================================"
echo " Done. Artifacts in: ${OUTDIR}"
echo "   - Re-enable helper: ${REENABLE}"
echo "   - Actions CSV     : ${OUTDIR}/actions.csv"
echo "   - Enabled list    : ${OUTDIR}/packages-enabled-${USER_ID}.txt"
echo "   - Disabled list   : ${OUTDIR}/packages-disabled-${USER_ID}.txt"
echo " Reboot recommended. To revert everything from this run:"
echo "   ${REENABLE}"
echo "================================================================================"
