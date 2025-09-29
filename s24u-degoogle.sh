#!/usr/bin/env bash
# ==============================================================================
#  Galaxy S24 Ultra — De-Google (Reversible) via ADB — v2 (hardened)
#  Primary method: pm disable-user --user 0  (safe & reversible per-user)
#  Highlights:
#    - Strict mode, robust preflight (ADB, auth, device, user)
#    - Multi-user aware: always targets --user 0 explicitly
#    - Dry-run mode, CSV action log, inventories, re-enable helper
#    - Safe-mode (Google-only prefixes). Optional opt-in to non-Google extras.
#    - Protect list (e.g., WebView), exclude list, and role guards (SMS/Dialer)
# ==============================================================================

set -Eeuo pipefail
shopt -s lastpipe

# --------------------------- Configuration ------------------------------------
# Extra package list file (one package name per line, '#' for comments)
EXTRA_PKG_FILE="${EXTRA_PKG_FILE:-./extra-google-packages.txt}"

# Optional exclude/keep file (one package per line) that should never be disabled
EXCLUDE_PKG_FILE="${EXCLUDE_PKG_FILE:-}"

# Dry-run only prints actions and writes logs, but does NOT change the device
DRY_RUN="${DRY_RUN:-0}"

# Safe mode: only allow packages that start with common Google prefixes unless
# ALLOW_NON_GOOGLE=1 is provided (helps prevent accidental breakage).
SAFE_MODE="${SAFE_MODE:-1}"
ALLOW_NON_GOOGLE="${ALLOW_NON_GOOGLE:-0}"

# Directory for artifacts
TS="$(date +%Y%m%d-%H%M%S)"
OUTDIR="${OUTDIR:-./adb-degoogle-$TS}"
mkdir -p "$OUTDIR"

REENABLE_SCRIPT="$OUTDIR/reenable.sh"
INVENTORY_ALL="$OUTDIR/packages-all.txt"
INVENTORY_ENABLED="$OUTDIR/packages-enabled.txt"
INVENTORY_DISABLED="$OUTDIR/packages-disabled.txt"
ACTIONS_CSV="$OUTDIR/actions.csv"
SESSION_LOG="$OUTDIR/session.log"

# Log also to a session file (best-effort)
exec > >(tee -a "$SESSION_LOG") 2>&1

# --------------------------- Utility: printing & traps -------------------------
info()  { printf "[*] %s\n" "$*"; }
warn()  { printf "[!] %s\n" "$*" >&2; }
err()   { printf "[ERROR] %s\n" "$*" >&2; }
die()   { err "$*"; exit 1; }

cleanup() { :; }
trap cleanup EXIT

# --------------------------- Verify ADB / device state -------------------------
command -v adb >/dev/null 2>&1 || die "adb not found in PATH. Install Android platform-tools."

# Select a target device (handles multiple devices)
select_device() {
  mapfile -t lines < <(adb devices | awk 'NR>1 && NF{print $1" "$2}')
  local count="${#lines[@]}"
  (( count == 0 )) && die "No device found. Connect via USB and enable USB debugging. (See Android adb docs)"
  if (( count == 1 )); then
    local serial status; read -r serial status <<<"${lines[0]}"
    [[ "$status" != "device" ]] && die "Device state is '$status'. Authorize USB debugging or reconnect."
    export ANDROID_SERIAL="$serial"; return
  fi
  info "Multiple devices detected:"
  local i=1; for l in "${lines[@]}"; do printf "  [%d] %s\n" "$i" "$l"; ((i++)); done
  read -r -p "Select device [1-$count]: " pick
  [[ "$pick" =~ ^[0-9]+$ ]] || die "Invalid selection."
  local idx=$((pick-1)) serial status; read -r serial status <<<"${lines[$idx]}"
  [[ "$status" != "device" ]] && die "Selected device state is '$status'."
  export ANDROID_SERIAL="$serial"
}

select_device

# Quick sanity: shell reachable?
adb shell true 1>/dev/null 2>&1 || die "adb shell failed. Check cable, drivers, and authorization."

# Device identity (helpful in logs)
MODEL="$(adb shell getprop ro.product.model | tr -d '\r')"
DEVICE="$(adb shell getprop ro.product.device | tr -d '\r')"
ANDROID_VER="$(adb shell getprop ro.build.version.release | tr -d '\r')"
ONEUI="$(adb shell getprop ro.build.version.oneui | tr -d '\r' || true)"
info "Target: $MODEL ($DEVICE), Android $ANDROID_VER, One UI ${ONEUI:-unknown}"

# Confirm multi-user targeting best-practice: we always address --user 0 explicitly.
# (Android recommends specifying user ID to avoid ambiguity across commands.)  # Ref in notes.
CURRENT_USER="$(adb shell 'am get-current-user' 2>/dev/null | tr -d '\r' || echo 0)"
[[ "$CURRENT_USER" != "0" ]] && warn "Current foreground user is $CURRENT_USER; script will still target --user 0 explicitly."

# --------------------------- Confirm Understanding -----------------------------
echo "============================================================================="
echo "  DE-GOOGLE (reversible) for Galaxy S24 Ultra"
echo "  This disables Google apps/services for USER 0 using:"
echo "     pm disable-user --user 0 <package>"
echo "  You can undo with:"
echo "     adb shell pm enable --user 0 <package>"
echo "  DRY_RUN=$DRY_RUN  SAFE_MODE=$SAFE_MODE  ALLOW_NON_GOOGLE=$ALLOW_NON_GOOGLE"
echo "============================================================================="
read -r -p "Type 'I UNDERSTAND' to proceed: " ACK
[[ "$ACK" == "I UNDERSTAND" ]] || { warn "Aborting by user."; exit 1; }

# --------------------------- Export inventories --------------------------------
info "Exporting package inventories to $OUTDIR ..."
adb shell "cmd package list packages -u -f" | sed 's/\r$//' > "$INVENTORY_ALL"
adb shell "cmd package list packages"       | sed 's/\r$//' > "$INVENTORY_ENABLED"
adb shell "cmd package list packages -d"    | sed 's/\r$//' > "$INVENTORY_DISABLED"
printf "package,group,action,status,message\n" > "$ACTIONS_CSV"

# Prepare re-enable helper
printf "#!/usr/bin/env bash\nset -Eeuo pipefail\n" > "$REENABLE_SCRIPT"
chmod +x "$REENABLE_SCRIPT"

# --------------------------- Helpers -------------------------------------------
pm_supports_disable_user() {
  adb shell "pm help | grep -q 'disable-user'" >/dev/null 2>&1
}
pm_supports_disable_user || warn "pm may restrict disabling certain system packages. If errors occur, enable 'USB debugging' and OEM options correctly."

pkg_exists() { adb shell "pm path $1" >/dev/null 2>&1; }

# Protect list: never disable these
PROTECT_LIST=(
  com.google.android.webview
  com.android.webview
  # Core telephony / contacts providers (defensive; normally not Google)
  com.android.providers.contacts
  com.android.providers.telephony
  com.samsung.android.dialer
  com.samsung.android.messaging
  com.android.server.telecom
  com.samsung.android.contacts
  com.android.phone
  com.android.mms.service
  com.samsung.android.incallui
)

# Exclude list: user-provided
EXCLUDE_LIST=()
if [[ -n "${EXCLUDE_PKG_FILE}" && -f "$EXCLUDE_PKG_FILE" ]]; then
  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    EXCLUDE_LIST+=("$line")
  done < "$EXCLUDE_PKG_FILE"
fi

in_list() {
  local x="$1"; shift
  local y
  for y in "$@"; do [[ "$x" == "$y" ]] && return 0; done
  return 1
}

safe_mode_allows() {
  local p="$1"
  # Common Google prefixes we intend to target
  [[ "$p" =~ ^com\.google\. ]] || [[ "$p" == "com.android.vending" ]] || [[ "$p" == "com.google.android.gsf" ]] || [[ "$p" == "com.google.android.gsf.login" ]]
}

should_skip() {
  local pkg="$1"
  in_list "$pkg" "${PROTECT_LIST[@]}" && { printf "protected"; return 0; }
  in_list "$pkg" "${EXCLUDE_LIST[@]}"   && { printf "excluded";  return 0; }
  if [[ "$SAFE_MODE" == "1" && "$ALLOW_NON_GOOGLE" != "1" ]]; then
    safe_mode_allows "$pkg" || { printf "non-google (safe-mode)"; return 0; }
  fi
  return 1
}

disable_pkg() {
  local pkg="$1" group="$2"
  local reason
  if reason="$(should_skip "$pkg")"; then
    info "Skip ($reason): $pkg"
    printf "%s,%s,disable,skip,%s\n" "$pkg" "$group" "$reason" >> "$ACTIONS_CSV"
    return
  fi
  if ! pkg_exists "$pkg"; then
    info "Skip (not installed): $pkg"
    printf "%s,%s,disable,skip,not installed\n" "$pkg" "$group" >> "$ACTIONS_CSV"
    return
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    info "DRY-RUN would disable: $pkg"
    printf "%s,%s,disable,dry-run,\n" "$pkg" "$group" >> "$ACTIONS_CSV"
    return
  fi
  if adb shell "pm disable-user --user 0 $pkg" >/dev/null 2>&1; then
    info "Disabled: $pkg"
    printf "%s,%s,disable,ok,\n" "$pkg" "$group" >> "$ACTIONS_CSV"
    echo "adb shell pm enable --user 0 $pkg" >> "$REENABLE_SCRIPT"
  else
    warn "Failed (permission/policy?): $pkg"
    printf "%s,%s,disable,fail,permission or policy\n" "$pkg" "$group" >> "$ACTIONS_CSV"
  fi
}

# --------------------------- Role/Default-app guards ---------------------------
# If Google Messages is your current SMS app, disabling it will break texting.
# We check roles via 'cmd role holders' and warn. (Non-fatal; user can proceed.)
role_holders() { adb shell "cmd role holders $1" 2>/dev/null | tr -d '\r' || true; }

SMS_ROLE="android.app.role.SMS"
DIALER_ROLE="android.app.role.DIALER"
SMS_HOLDERS="$(role_holders "$SMS_ROLE")"
DIALER_HOLDERS="$(role_holders "$DIALER_ROLE")"

if echo "$SMS_HOLDERS" | grep -q "com.google.android.apps.messaging"; then
  warn "Google Messages is the current SMS app. Disabling it will break SMS until you switch to Samsung Messages or another SMS app."
  read -r -p "Type 'SWITCHED_SMS' after you change the default SMS app (or 'CONTINUE' to proceed anyway): " SMS_ACK
  [[ "$SMS_ACK" =~ ^(SWITCHED_SMS|CONTINUE)$ ]] || { warn "Aborting."; exit 1; }
fi

# --------------------------- Package Sets -------------------------------------
# Presence varies by firmware/region; missing packages are auto-skipped.

GOOGLE_CORE_PLAY_STACK=(
  com.android.vending                         # Play Store
  com.google.android.gms                      # Play services
  com.google.android.gsf                      # Google Services Framework
  com.google.android.gsf.login                # Google Account Manager (some builds)
  com.google.android.feedback                 # Feedback
  com.google.android.backuptransport          # Google Backup Transport
  com.google.android.onetimeinitializer       # One-time init
  com.google.android.partnersetup             # Partner Setup
  com.google.android.apps.restore             # Device restore helper
)

GOOGLE_APPS=(
  com.google.android.googlequicksearchbox     # Google app (Assistant/Discover)
  com.google.android.youtube                  # YouTube
  com.google.android.apps.youtube.music       # YouTube Music
  com.google.android.gm                       # Gmail
  com.google.android.apps.maps                # Maps
  com.google.android.apps.docs                # Drive
  com.google.android.apps.photos              # Photos
  com.google.android.apps.meetings            # Google Meet
  com.google.android.apps.tachyon             # Duo (legacy)
  com.google.android.chrome                   # Chrome
  com.google.android.calendar                 # Google Calendar
  com.google.android.contacts                  # Google Contacts app
  com.google.android.apps.messaging           # Google Messages
  com.google.android.play.games               # Play Games
  com.google.android.apps.podcasts            # Podcasts
  com.google.android.keep                     # Keep
  com.google.android.videos                   # Play Movies & TV
  com.google.android.apps.nbu.files           # Files by Google
)

GOOGLE_SERVICES_MISC=(
  com.google.android.syncadapters.contacts    # Contacts sync
  com.google.android.syncadapters.calendar    # Calendar sync
  com.google.android.ims                      # Carrier Services / RCS (disable only if not needed)
  com.google.android.projection.gearhead      # Android Auto
  com.google.android.wearable.app             # Wear OS
  com.google.android.apps.wear.companion      # Wear OS companion
  com.google.ar.core                          # ARCore
  com.google.vr.vrcore                        # Google VR Services
  com.google.android.printservice.recommendation # Print svc recommender
  com.google.android.tts                      # Google TTS (keep if you need TTS)
  com.google.android.adservices.api           # Privacy Sandbox / Ads services (module API)
)

GOOGLE_OPTIONAL=(
  com.google.android.inputmethod.latin        # Gboard (keep Samsung Keyboard if preferred)
  com.google.android.deskclock                # Google Clock
  com.google.android.calculator               # Google Calculator
  com.google.android.as                       # Action Services / Live Caption deps (varies)
  com.google.android.apps.subscriptions.red   # Google One (varies/region)
  com.google.android.marvin.talkback          # TalkBack (KEEP if you rely on accessibility)
)

# Load extra packages (user-provided). In SAFE_MODE, non-Google entries are refused unless ALLOW_NON_GOOGLE=1.
if [[ -f "$EXTRA_PKG_FILE" ]]; then
  info "Loading extra package names from $EXTRA_PKG_FILE ..."
  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    GOOGLE_OPTIONAL+=("$line")
  done < "$EXTRA_PKG_FILE"
fi

# --------------------------- Execution ----------------------------------------
info "Disabling Google Core Play Stack..."
for p in "${GOOGLE_CORE_PLAY_STACK[@]}"; do disable_pkg "$p" "core"; done

info "Disabling Google Apps..."
for p in "${GOOGLE_APPS[@]}"; do disable_pkg "$p" "apps"; done

info "Disabling Google Services / Android Auto / Wear / AR / misc..."
for p in "${GOOGLE_SERVICES_MISC[@]}"; do disable_pkg "$p" "services"; done

info "Disabling Optional Google components..."
for p in "${GOOGLE_OPTIONAL[@]}"; do disable_pkg "$p" "optional"; done

# --------------------------- Summary ------------------------------------------
DISABLED_COUNT="$(awk -F, '$3=="disable" && $4=="ok"{c++} END{print c+0}' "$ACTIONS_CSV")"
SKIP_COUNT="$(awk -F, '$4=="skip"{c++} END{print c+0}' "$ACTIONS_CSV")"
FAIL_COUNT="$(awk -F, '$4=="fail"{c++} END{print c+0}' "$ACTIONS_CSV")"
DRY_COUNT="$(awk -F, '$4=="dry-run"{c++} END{print c+0}' "$ACTIONS_CSV")"

echo "============================================================================="
echo " Done. Artifacts:"
echo "   - Re-enable helper: $REENABLE_SCRIPT"
echo "   - Inventory (all):  $INVENTORY_ALL"
echo "   - Inventory (on):   $INVENTORY_ENABLED"
echo "   - Inventory (off):  $INVENTORY_DISABLED"
echo "   - Actions (CSV):    $ACTIONS_CSV"
echo " Result: disabled=$DISABLED_COUNT  skipped=$SKIP_COUNT  failed=$FAIL_COUNT  dry-run=$DRY_COUNT"
echo " Re-enable any package: adb shell pm enable --user 0 <package>"
echo "============================================================================="
