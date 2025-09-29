#!/usr/bin/env bash
# ==============================================================================
#  Galaxy S24 Ultra — De-Google (Reversible) via ADB
#  Primary method: pm disable-user --user 0
#  Safety-first, robust logging, dry-run, and re-enable script generation
# ==============================================================================

set -Eeuo pipefail

# ------------- Configuration (edit if needed) ---------------------------------
# Extra package list file (one package name per line, comments with '#'):
EXTRA_PKG_FILE="${EXTRA_PKG_FILE:-./extra-google-packages.txt}"

# When true, only print actions, do not change device state:
DRY_RUN="${DRY_RUN:-0}"

# Directory for logs & artifacts
TS="$(date +%Y%m%d-%H%M%S)"
OUTDIR="${OUTDIR:-./adb-degoogle-$TS}"
mkdir -p "$OUTDIR"

REENABLE_SCRIPT="$OUTDIR/reenable.sh"
INVENTORY_ALL="$OUTDIR/packages-all.txt"
INVENTORY_ENABLED="$OUTDIR/packages-enabled.txt"
INVENTORY_DISABLED="$OUTDIR/packages-disabled.txt"
ACTIONS_CSV="$OUTDIR/actions.csv"

# ------------- Utility: printing & traps --------------------------------------
info()  { printf "[*] %s\n" "$*"; }
warn()  { printf "[!] %s\n" "$*" >&2; }
err()   { printf "[ERROR] %s\n" "$*" >&2; }
die()   { err "$*"; exit 1; }

cleanup() { :; }  # reserved for future temp cleanup
trap cleanup EXIT

# ------------- Verify ADB / device state --------------------------------------
command -v adb >/dev/null 2>&1 || die "adb not found in PATH. Install platform-tools."

# If multiple devices, ask to set ADB_SERIAL or choose interactively.
select_device() {
  mapfile -t lines < <(adb devices | awk 'NR>1 && NF{print $1" "$2}')
  local count="${#lines[@]}"
  (( count == 0 )) && die "No device found. Connect via USB and enable USB debugging."
  if (( count == 1 )); then
    local serial status
    read -r serial status <<<"${lines[0]}"
    [[ "$status" != "device" ]] && die "Device state is '$status'. Authorize USB debugging or reconnect."
    export ANDROID_SERIAL="$serial"
    return
  fi
  info "Multiple devices detected:"
  local i=1
  for l in "${lines[@]}"; do
    printf "  [%d] %s\n" "$i" "$l"
    ((i++))
  done
  read -r -p "Select device [1-$count]: " pick
  [[ "$pick" =~ ^[0-9]+$ ]] || die "Invalid selection."
  local idx=$((pick-1))
  local serial status
  read -r serial status <<<"${lines[$idx]}"
  [[ "$status" != "device" ]] && die "Selected device state is '$status'."
  export ANDROID_SERIAL="$serial"
}

select_device

# Quick sanity: shell reachable?
adb shell true 1>/dev/null 2>&1 || die "adb shell failed. Check cable, drivers, and authorization."

# ------------- Device identity & helpful context ------------------------------
MODEL="$(adb shell getprop ro.product.model | tr -d '\r')"
DEVICE="$(adb shell getprop ro.product.device | tr -d '\r')"
ANDROID_VER="$(adb shell getprop ro.build.version.release | tr -d '\r')"
ONEUI="$(adb shell getprop ro.build.version.oneui | tr -d '\r' || true)"
info "Target: $MODEL ($DEVICE), Android $ANDROID_VER, One UI ${ONEUI:-unknown}"

# ------------- Confirm Understanding ------------------------------------------
echo "============================================================================="
echo "  DE-GOOGLE (reversible) for Galaxy S24 Ultra"
echo "  This will disable Google apps/services for the CURRENT USER (user 0)."
echo "  You can re-enable any package with:"
echo "     adb shell pm enable --user 0 <package.name>"
echo "============================================================================="
read -r -p "Type 'I UNDERSTAND' to proceed: " ACK
[[ "$ACK" == "I UNDERSTAND" ]] || { warn "Aborting by user."; exit 1; }

# ------------- Export inventories for rollback awareness ----------------------
info "Exporting package inventories to $OUTDIR ..."
adb shell "cmd package list packages -u -f" | sed 's/\r$//' > "$INVENTORY_ALL"        # all, incl. uninstalled for user
adb shell "cmd package list packages"       | sed 's/\r$//' > "$INVENTORY_ENABLED"    # enabled
adb shell "cmd package list packages -d"    | sed 's/\r$//' > "$INVENTORY_DISABLED"   # disabled
# (These commands and flags are part of the AOSP 'cmd package' tool.)  # docs cited in Section 1
printf "package,action,status,message\n" > "$ACTIONS_CSV"

# Prepare re-enable helper
printf "#!/usr/bin/env bash\nset -Eeuo pipefail\n" > "$REENABLE_SCRIPT"
chmod +x "$REENABLE_SCRIPT"

# ------------- Helpers ---------------------------------------------------------
pm_supports_disable_user() {
  adb shell "pm help | grep -q 'disable-user'" >/dev/null 2>&1
}
pm_supports_disable_user || warn "Device pm may restrict disabling some system packages. If errors occur, enable \"USB debugging (Security settings)\" in Developer options and retry."

pkg_exists() { adb shell "pm path $1" >/dev/null 2>&1; }

disable_pkg() {
  local pkg="$1"
  if pkg_exists "$pkg"; then
    if [[ "$DRY_RUN" == "1" ]]; then
      info "DRY-RUN would disable: $pkg"
      printf "%s,disable,dry-run,skipped\n" "$pkg" >> "$ACTIONS_CSV"
    else
      if adb shell "pm disable-user --user 0 $pkg" >/dev/null 2>&1; then
        info "Disabled: $pkg"
        printf "%s,disable,ok,\n" "$pkg" >> "$ACTIONS_CSV"
        echo "adb shell pm enable --user 0 $pkg" >> "$REENABLE_SCRIPT"
      else
        warn "Failed (permission/restriction?): $pkg"
        printf "%s,disable,fail,permission or policy\n" "$pkg" >> "$ACTIONS_CSV"
      fi
    fi
  else
    info "Skip (not installed): $pkg"
    printf "%s,disable,skip,not installed\n" "$pkg" >> "$ACTIONS_CSV"
  fi
}

# ------------- Google Packages -------------------------------------------------
# Curated from common S24U payloads & community debloat lists (GFAM/Google sets).
# Presence varies by region/carrier/firmware; missing packages are skipped.
# References: UAD lists and S24 debloat writeups.  # see citations below

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

# ------------- Load extra packages from file (optional) -----------------------
if [[ -f "$EXTRA_PKG_FILE" ]]; then
  info "Loading extra package names from $EXTRA_PKG_FILE ..."
  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    GOOGLE_OPTIONAL+=("$line")
  done < "$EXTRA_PKG_FILE"
fi

# ------------- DO-NOT-DISABLE guardrails -------------------------------------
# Android System WebView is widely used by apps. On Samsung, this may be
# com.google.android.webview OR com.android.webview depending on build.
# We avoid touching it automatically.
PROTECT_LIST=(
  com.google.android.webview
  com.android.webview
)
protect() { for x in "${PROTECT_LIST[@]}"; do [[ "$1" == "$x" ]] && return 0; done; return 1; }

safe_disable() {
  local pkg="$1"
  protect "$pkg" && { warn "Protected (skipping): $pkg"; return; }
  disable_pkg "$pkg"
}

# ------------- Execute ---------------------------------------------------------
info "Disabling Google Core Play Stack..."
for p in "${GOOGLE_CORE_PLAY_STACK[@]}"; do safe_disable "$p"; done

info "Disabling Google Apps..."
for p in "${GOOGLE_APPS[@]}"; do safe_disable "$p"; done

info "Disabling Google Services / Android Auto / Wear / AR / misc..."
for p in "${GOOGLE_SERVICES_MISC[@]}"; do safe_disable "$p"; done

info "Disabling Optional Google components..."
for p in "${GOOGLE_OPTIONAL[@]}"; do safe_disable "$p"; done

# ------------- Summary ---------------------------------------------------------
DISABLED_COUNT="$(awk -F, '$2=="disable" && $3=="ok"{c++} END{print c+0}' "$ACTIONS_CSV")"
SKIP_COUNT="$(awk -F, '$3=="skip"{c++} END{print c+0}' "$ACTIONS_CSV")"
FAIL_COUNT="$(awk -F, '$3=="fail"{c++} END{print c+0}' "$ACTIONS_CSV")"

echo "============================================================================="
echo " Done. Artifacts:"
echo "   - Re-enable helper: $REENABLE_SCRIPT"
echo "   - Inventory (all):  $INVENTORY_ALL"
echo "   - Inventory (on):   $INVENTORY_ENABLED"
echo "   - Inventory (off):  $INVENTORY_DISABLED"
echo "   - Actions (CSV):    $ACTIONS_CSV"
echo " Result: disabled=$DISABLED_COUNT  skipped=$SKIP_COUNT  failed=$FAIL_COUNT"
echo " Re-enable any package: adb shell pm enable --user 0 <package>"
echo "============================================================================="
