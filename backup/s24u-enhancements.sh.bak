#!/usr/bin/env bash
# ==============================================================================
#  Galaxy S24 Ultra — Optional Enhancements (Performance & Privacy)
#  Robust, reversible: generates revert-enhancements.sh with PREVIOUS values
#  - Strict mode, device selection, dry-run, detailed logs
#  - Records old settings and writes exact restore commands
#  - Disables optional bloat and writes corresponding re-enable lines
# ==============================================================================

set -Eeuo pipefail

# --------------------------- Configuration ------------------------------------
# DRY_RUN=1 will show intended changes without applying them
DRY_RUN="${DRY_RUN:-0}"

# Optional tunables (uncomment or override via env)
ANIM_SCALE="${ANIM_SCALE:-0.5}"              # 0..1 (0 disables, 1 default); typical 0.5 for snappy feel
SET_APP_STANDBY="${SET_APP_STANDBY:-1}"     # 1 to ensure App Standby is on
# Limit cached/background processes (developer option). Empty = do not change.
# Values commonly seen: 1,2,3,4 (cap), or 0/empty for default platform behavior.
BACKGROUND_PROCESS_LIMIT="${BACKGROUND_PROCESS_LIMIT:-}"

# Advanced (optional, experimental per-build): ActivityManager device_config
# Example: ACTIVITY_MAX_CACHED=4 to hint lower cache. Leave empty to skip.
ACTIVITY_MAX_CACHED="${ACTIVITY_MAX_CACHED:-}"

TS="$(date +%Y%m%d-%H%M%S)"
OUTDIR="${OUTDIR:-./adb-enhancements-$TS}"
mkdir -p "$OUTDIR"

ACTIONS_CSV="$OUTDIR/actions.csv"
REENABLE_SCRIPT="$OUTDIR/revert-enhancements.sh"
REVERT_MARKERS="$OUTDIR/revert.markers"
REVERT_MARKERS_DC="$OUTDIR/revert.dc.markers"
printf "type,target,scope,key,value,action,status,message\n" > "$ACTIONS_CSV"
: > "$REVERT_MARKERS"; : > "$REVERT_MARKERS_DC"

# --------------------------- Utilities ----------------------------------------
info() { printf "[*] %s\n" "$*"; }
warn() { printf "[!] %s\n" "$*" >&2; }
die()  { printf "[ERROR] %s\n" "$*" >&2; exit 1; }

cleanup(){ :; }
trap cleanup EXIT

# --------------------------- ADB & Device Selection ---------------------------
command -v adb >/dev/null 2>&1 || die "adb not found. Install Android platform-tools."

select_device() {
  mapfile -t lines < <(adb devices | awk 'NR>1 && NF{print $1" "$2}')
  local count="${#lines[@]}"
  (( count == 0 )) && die "No device found. Connect and enable USB debugging."
  if (( count == 1 )); then
    local serial status; read -r serial status <<<"${lines[0]}"
    [[ "$status" != "device" ]] && die "Device state is '$status'. Authorize or reconnect."
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
adb shell true >/dev/null 2>&1 || die "adb shell not reachable."

MODEL="$(adb shell getprop ro.product.model | tr -d '\r')"
DEVICE="$(adb shell getprop ro.product.device | tr -d '\r')"
ANDROID_VER="$(adb shell getprop ro.build.version.release | tr -d '\r')"
ONEUI="$(adb shell getprop ro.build.version.oneui | tr -d '\r' || true)"
info "Target: $MODEL ($DEVICE) Android $ANDROID_VER OneUI ${ONEUI:-unknown}"
echo "============================================================================="
echo " This script tweaks animation scales, standby, background limits (optional),"
echo " privacy toggles, and disables optional Samsung/partner bloat (reversible)."
echo " It will generate: $REENABLE_SCRIPT  (to restore ALL previous values)"
echo " Dry-run: DRY_RUN=$DRY_RUN"
echo "============================================================================="
read -r -p "Type 'I UNDERSTAND' to proceed: " ACK
[[ "$ACK" == "I UNDERSTAND" ]] || { warn "Aborting by user."; exit 1; }

printf "#!/usr/bin/env bash\nset -Eeuo pipefail\n" > "$REENABLE_SCRIPT"
chmod +x "$REENABLE_SCRIPT"

# --------------------------- Setting helpers ----------------------------------
# settings get/put/delete across {global,secure,system}
get_setting()   { adb shell settings get "$1" "$2" 2>/dev/null | tr -d '\r'; }
put_setting()   { adb shell settings put "$1" "$2" "$3" >/dev/null 2>&1; }
del_setting()   { adb shell settings delete "$1" "$2" >/dev/null 2>&1; }

ensure_revert_recorded() {
  # $1=scope, $2=key
  local scope="$1" key="$2" marker="$scope:$key"
  if grep -qxF "$marker" "$REVERT_MARKERS"; then return; fi
  local old; old="$(get_setting "$scope" "$key")" || old=""
  # When a key is not set, AOSP 'settings get' typically prints 'null'
  if [[ "$old" == "null" || -z "$old" ]]; then
    echo "adb shell settings delete $scope $key" >> "$REENABLE_SCRIPT"
  else
    # shell-escape value for safety
    local esc; esc=$(printf "%q" "$old")
    echo "adb shell settings put $scope $key $esc" >> "$REENABLE_SCRIPT"
  fi
  echo "$marker" >> "$REVERT_MARKERS"
}

apply_setting() {
  # $1=scope, $2=key, $3=new value (empty means delete)
  local scope="$1" key="$2" val="${3-}"
  ensure_revert_recorded "$scope" "$key"
  if [[ "$DRY_RUN" == "1" ]]; then
    if [[ -z "${val+x}" || -z "$val" ]]; then
      info "DRY-RUN delete: settings $scope $key"
      printf "setting,,%s,%s,,delete,dry-run,\n" "$scope" "$key" >> "$ACTIONS_CSV"
    else
      info "DRY-RUN put   : settings $scope $key = $val"
      printf "setting,,%s,%s,%s,put,dry-run,\n" "$scope" "$key" "$val" >> "$ACTIONS_CSV"
    fi
    return
  fi
  if [[ -z "${val+x}" || -z "$val" ]]; then
    if del_setting "$scope" "$key"; then
      printf "setting,,%s,%s,,delete,ok,\n" "$scope" "$key" >> "$ACTIONS_CSV"
    else
      printf "setting,,%s,%s,,delete,fail,\n" "$scope" "$key" >> "$ACTIONS_CSV"
    fi
  else
    if put_setting "$scope" "$key" "$val"; then
      printf "setting,,%s,%s,%s,put,ok,\n" "$scope" "$key" "$val" >> "$ACTIONS_CSV"
    else
      printf "setting,,%s,%s,%s,put,fail,\n" "$scope" "$key" "$val" >> "$ACTIONS_CSV"
    fi
  fi
}

# device_config helpers (advanced/optional)
dc_get()  { adb shell device_config get "$1" "$2" 2>/dev/null | tr -d '\r'; }
dc_put()  { adb shell device_config put "$1" "$2" "$3" >/dev/null 2>&1; }
dc_del()  { adb shell device_config delete "$1" "$2" >/dev/null 2>&1; }

ensure_dc_revert_recorded() {
  local ns="$1" key="$2" marker="$ns:$key"
  if grep -qxF "$marker" "$REVERT_MARKERS_DC"; then return; fi
  local old; old="$(dc_get "$ns" "$key")" || old=""
  if [[ -z "$old" || "$old" == "null" ]]; then
    echo "adb shell device_config delete $ns $key" >> "$REENABLE_SCRIPT"
  else
    local esc; esc=$(printf "%q" "$old")
    echo "adb shell device_config put $ns $key $esc" >> "$REENABLE_SCRIPT"
  fi
  echo "$marker" >> "$REVERT_MARKERS_DC"
}

apply_device_config() {
  # $1=namespace, $2=key, $3=value (empty => delete)
  local ns="$1" key="$2" val="${3-}"
  ensure_dc_revert_recorded "$ns" "$key"
  if [[ "$DRY_RUN" == "1" ]]; then
    if [[ -z "${val+x}" || -z "$val" ]]; then
      info "DRY-RUN device_config delete $ns $key"
      printf "device_config,,%s,%s,,delete,dry-run,\n" "$ns" "$key" >> "$ACTIONS_CSV"
    else
      info "DRY-RUN device_config put $ns $key=$val"
      printf "device_config,,%s,%s,%s,put,dry-run,\n" "$ns" "$key" "$val" >> "$ACTIONS_CSV"
    fi
    return
  fi
  if [[ -z "${val+x}" || -z "$val" ]]; then
    if dc_del "$ns" "$key"; then
      printf "device_config,,%s,%s,,delete,ok,\n" "$ns" "$key" >> "$ACTIONS_CSV"
    else
      printf "device_config,,%s,%s,,delete,fail,\n" "$ns" "$key" >> "$ACTIONS_CSV"
    fi
  else
    if dc_put "$ns" "$key" "$val"; then
      printf "device_config,,%s,%s,%s,put,ok,\n" "$ns" "$key" "$val" >> "$ACTIONS_CSV"
    else
      printf "device_config,,%s,%s,%s,put,fail,\n" "$ns" "$key" "$val" >> "$ACTIONS_CSV"
    fi
  fi
}

# Package disable helper (reversible)
pkg_exists() { adb shell "pm path $1" >/dev/null 2>&1; }
disable_pkg() {
  local pkg="$1"
  if ! pkg_exists "$pkg"; then
    info "Skip (not installed): $pkg"
    printf "package,%s,,,,disable,skip,not-installed\n" "$pkg" >> "$ACTIONS_CSV"
    return
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    info "DRY-RUN would disable: $pkg"
    printf "package,%s,,,,disable,dry-run,\n" "$pkg" >> "$ACTIONS_CSV"
  else
    if adb shell "pm disable-user --user 0 $pkg" >/dev/null 2>&1; then
      printf "package,%s,,,,disable,ok,\n" "$pkg" >> "$ACTIONS_CSV"
      echo "adb shell pm enable --user 0 $pkg" >> "$REENABLE_SCRIPT"
    else
      warn "Failed to disable (permission/policy?): $pkg"
      printf "package,%s,,,,disable,fail,permission\n" "$pkg" >> "$ACTIONS_CSV"
    fi
  fi
}

# --------------------------- Apply Tweaks -------------------------------------
info "Applying UI animation scale = $ANIM_SCALE (Global)"
apply_setting global window_animation_scale "$ANIM_SCALE"
apply_setting global transition_animation_scale "$ANIM_SCALE"
apply_setting global animator_duration_scale "$ANIM_SCALE"

info "Ensuring App Standby enabled = $SET_APP_STANDBY (Global)"
apply_setting global app_standby_enabled "$SET_APP_STANDBY"

if [[ -n "$BACKGROUND_PROCESS_LIMIT" ]]; then
  info "Setting Background Process Limit (Global) = $BACKGROUND_PROCESS_LIMIT"
  apply_setting global background_process_limit "$BACKGROUND_PROCESS_LIMIT"
else
  info "Background Process Limit: unchanged"
fi

# Advanced / experimental per-build: activity_manager max_cached_processes
if [[ -n "$ACTIVITY_MAX_CACHED" ]]; then
  info "Setting device_config activity_manager max_cached_processes = $ACTIVITY_MAX_CACHED"
  apply_device_config activity_manager max_cached_processes "$ACTIVITY_MAX_CACHED"
else
  info "device_config max_cached_processes: unchanged"
fi

info "Privacy toggles (best-effort)"
# Note: These keys may be ignored on some builds; still safe to set.
apply_setting global limit_ad_tracking 1
# Disable print service recommendations/selection list (clears list)
apply_setting secure enabled_print_services ""

# --------------------------- Optional Samsung/Partner Debloat ------------------
info "Optional bloat (Likely Safe) — reversible"
LIKELY_SAFE=(
  com.facebook.katana
  com.facebook.appmanager
  com.facebook.services
  com.facebook.system
  com.linkedin.android
  com.netflix.mediaclient
  com.netflix.partner.activation
  com.samsung.sree                          # Samsung Global Goals
  com.samsung.android.game.gamehome         # Game Launcher
  com.samsung.android.game.gametools        # Game Tools
  com.samsung.android.game.gos              # Game Optimizing Service
  com.samsung.android.aremoji               # AR Emoji
  com.samsung.android.arzone                # AR Zone
  com.samsung.android.app.spage             # Samsung Free
  com.samsung.android.tvplus                # Samsung TV Plus
  com.samsung.android.app.tips              # Tips
  com.microsoft.skydrive                    # OneDrive preload
  com.microsoft.office.officehubrow         # Office Hub
  com.skype.raider                          # Skype
)

info "Optional bloat (Use Caution) — reversible"
USE_CAUTION=(
  com.samsung.android.bixby.agent
  com.samsung.android.bixby.service
  com.samsung.systemui.bixby2
  com.samsung.android.visionintelligence
  com.samsung.android.app.routines
  com.samsung.android.mdx
  com.samsung.android.mdx.quickboard
  com.samsung.android.mdecservice
  com.samsung.android.smartmirroring
  com.samsung.android.allshare.service.mediashare
  com.samsung.android.app.sharelive
  com.samsung.android.beaconmanager
)

# Disable sets (comment out any you want to keep)
for p in "${LIKELY_SAFE[@]}"; do disable_pkg "$p"; done
for p in "${USE_CAUTION[@]}"; do disable_pkg "$p"; done

# --------------------------- Summary ------------------------------------------
DISABLED_COUNT="$(awk -F, '$1=="package" && $6=="disable" && $7=="ok"{c++} END{print c+0}' "$ACTIONS_CSV")"
SET_OK_COUNT="$(awk -F, '$1!="package" && $7=="ok"{c++} END{print c+0}' "$ACTIONS_CSV")"
DRY_COUNT="$(awk -F, '$7=="dry-run"{c++} END{print c+0}' "$ACTIONS_CSV")"

echo "============================================================================="
echo " Enhancements complete (or simulated). Artifacts:"
echo "   - Revert helper     : $REENABLE_SCRIPT"
echo "   - Actions CSV       : $ACTIONS_CSV"
echo "   - Markers (settings): $REVERT_MARKERS"
echo "   - Markers (dev.conf): $REVERT_MARKERS_DC"
echo " Result: settings changed=$SET_OK_COUNT  packages disabled=$DISABLED_COUNT  dry-run=$DRY_COUNT"
echo " Reboot is recommended to settle services."
echo " To revert ALL changes: $REENABLE_SCRIPT"
echo "============================================================================="

