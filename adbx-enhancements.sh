#!/usr/bin/env bash
# ==============================================================================
#  Galaxy S24 Ultra — Enhancements (Performance & Privacy) — v9
#  - Uses adbx if present (falls back to adb), single $ADB for all calls
#  - Reversible (revert-enhancements.sh), CSV logging
#  - PROFILE presets (maxperf|balanced|battery) + env overrides
#  - ART secondary-dex & reset toggles; compile verification
#  - AppOps clamp for BACKGROUND_SYNC_BLACKLIST (RUN_*_IN_BACKGROUND, WAKE_LOCK)
#  - Robust list parsing, device guard, plan banner, action summary
# ==============================================================================

set -Eeuo pipefail
umask 077
IFS=$' \t\n'

VERBOSE="${VERBOSE:-0}"

log()   { printf '[*] %s\n' "$*"; }
warn()  { printf '[!] %s\n' "$*" >&2; }
error() { printf '[ERROR] %s\n' "$*" >&2; }
die()   { error "$*"; exit 1; }
vlog()  { [[ "$VERBOSE" == "1" ]] && log "$*"; }
run()   { if [[ "${DRY_RUN:-0}" == "1" ]]; then echo "DRY:" "$@"; else "$@"; fi; }

# ---------- ADB selection (prefer adbx) ---------------------------------------
ADB="$(command -v adbx || true)"
if [[ -z "$ADB" ]]; then ADB="$(command -v adb || true)"; fi
[[ -n "$ADB" ]] || die "adb/adbx not found in PATH"
"$ADB" start-server >/dev/null 2>&1 || true
log "Using ADB: $ADB"

# ---------- Device guard -------------------------------------------------------
pick_device() {
  mapfile -t devs < <("$ADB" devices | awk 'NR>1 && $2=="device"{print $1}')
  case "${#devs[@]}" in
    0) die "No device. Connect via USB and enable USB debugging." ;;
    1) export ANDROID_SERIAL="${devs[0]}" ;;
    *)
      if [[ -z "${ANDROID_SERIAL:-}" ]]; then
        printf "[!] Multiple devices: %s\n" "${devs[*]}" >&2
        die "Set ANDROID_SERIAL to the target device serial and re-run."
      fi
      ;;
  esac
  "$ADB" -s "${ANDROID_SERIAL}" shell true >/dev/null 2>&1 \
    || die "adb shell unreachable on $ANDROID_SERIAL"
}
pick_device

MODEL="$("$ADB" shell getprop ro.product.model | tr -d '\r')"
DEVICE="$("$ADB" shell getprop ro.product.device | tr -d '\r')"
ANDROID_VER="$("$ADB" shell getprop ro.build.version.release | tr -d '\r')"
ONEUI="$("$ADB" shell getprop ro.build.version.oneui 2>/dev/null | tr -d '\r' || true)"

# ---------- Preset profiles (env may override) --------------------------------
PROFILE="${PROFILE:-}"   # maxperf|balanced|battery|""

# Safe default-if-unset (no eval)
set_if_unset() {
  local name="$1" val="$2"
  # If variable is unset or empty, assign default
  if [[ -z "${!name-}" ]]; then
    printf -v "$name" '%s' "$val"
  fi
}

apply_profile() {
  case "${PROFILE}" in
    maxperf)
      set_if_unset ANIM_SCALE "0.2"
      set_if_unset REFRESH_MIN "85.0"; set_if_unset REFRESH_MAX "120.0"
      set_if_unset ART_ACTION "speed-all"; set_if_unset ART_INCLUDE_SECONDARY "1"
      set_if_unset PHANTOM_MODE "relaxed"
      set_if_unset DATA_SAVER "off"
      set_if_unset DISABLE_ALWAYS_SCANNING "1"; set_if_unset WIFI_SCAN_THROTTLE "0"
      set_if_unset BACKGROUND_PROCESS_LIMIT "2"
      set_if_unset ACTIVITY_MAX_CACHED "256"
      set_if_unset TEST_DOZE "off"
      ;;
    balanced)
      set_if_unset ANIM_SCALE "0.5"
      set_if_unset REFRESH_MIN "60.0"; set_if_unset REFRESH_MAX "120.0"
      set_if_unset ART_ACTION "bg"
      set_if_unset PHANTOM_MODE "default"
      set_if_unset DATA_SAVER "off"
      set_if_unset DISABLE_ALWAYS_SCANNING "1"; set_if_unset WIFI_SCAN_THROTTLE "1"
      set_if_unset BACKGROUND_PROCESS_LIMIT ""
      set_if_unset TEST_DOZE "off"
      ;;
    battery)
      set_if_unset ANIM_SCALE "0.5"
      set_if_unset REFRESH_MIN "60.0"; set_if_unset REFRESH_MAX "60.0"
      set_if_unset ART_ACTION ""
      set_if_unset DATA_SAVER "on"
      set_if_unset DISABLE_ALWAYS_SCANNING "1"; set_if_unset WIFI_SCAN_THROTTLE "1"
      set_if_unset TEST_DOZE "off"
      ;;
    "" ) ;;
    *  ) warn "Unknown PROFILE='${PROFILE}', ignoring." ;;
  esac
}

# ---------- Config (parsed then frozen) ---------------------------------------
DRY_RUN="${DRY_RUN:-0}"

# UI / multitasking
ANIM_SCALE="${ANIM_SCALE:-0.5}"                          # 0..1
BACKGROUND_PROCESS_LIMIT="${BACKGROUND_PROCESS_LIMIT:-}"  # 1..4 or "" to skip
ACTIVITY_MAX_CACHED="${ACTIVITY_MAX_CACHED:-}"            # device_config activity_manager

# Network policy / sync clamps
DATA_SAVER="${DATA_SAVER:-}"                               # on|off|""
BACKGROUND_SYNC_BLACKLIST="${BACKGROUND_SYNC_BLACKLIST:-}" # space-separated pkgs

# Private DNS
PRIVATE_DNS_MODE="${PRIVATE_DNS_MODE:-}"                  # off|opportunistic|hostname|""
PRIVATE_DNS_HOST="${PRIVATE_DNS_HOST:-}"

# Refresh
REFRESH_MIN="${REFRESH_MIN:-}"                            # e.g., 60.0
REFRESH_MAX="${REFRESH_MAX:-}"                            # e.g., 120.0

# Scanning / radios
DISABLE_ALWAYS_SCANNING="${DISABLE_ALWAYS_SCANNING:-0}"   # 1=off Wi-Fi/BLE always scanning
WIFI_SCAN_THROTTLE="${WIFI_SCAN_THROTTLE:-}"

# ART compilation
ART_ACTION="${ART_ACTION:-}"                              # ""|bg|speed-profile-all|speed-all
ART_SPEED_PROFILE_PKGS="${ART_SPEED_PROFILE_PKGS:-}"
ART_INCLUDE_SECONDARY="${ART_INCLUDE_SECONDARY:-0}"       # 1= --secondary-dex
ART_RESET_FIRST="${ART_RESET_FIRST:-0}"                   # 1= compile --reset -a before

# Process policy
PHANTOM_MODE="${PHANTOM_MODE:-default}"                   # default|relaxed
STANDBY_BUCKETS="${STANDBY_BUCKETS:-}"                    # "pkg1:rare pkg2:restricted"

# Permissions / AppOps
PERMISSIONS_TO_REVOKE="${PERMISSIONS_TO_REVOKE:-}"
PERMISSIONS_REVOKE_PACKAGES="${PERMISSIONS_REVOKE_PACKAGES:-}"
APP_OPS_PACKAGES="${APP_OPS_PACKAGES:-}"
APP_OPS_BLOCK_OPS="${APP_OPS_BLOCK_OPS:-}"

# Auto AppOps clamp for BACKGROUND_SYNC_BLACKLIST
APP_OPS_CLAMP_BLACKLIST="${APP_OPS_CLAMP_BLACKLIST:-on}"  # on|off
APP_OPS_CLAMP_OPS="${APP_OPS_CLAMP_OPS:-RUN_IN_BACKGROUND RUN_ANY_IN_BACKGROUND WAKE_LOCK}"

# Doze tests
TEST_DOZE="${TEST_DOZE:-off}"                             # off|on|unforce

# CSC hints
CSC="${CSC:-auto}"                                        # auto|THL|EUX
INCLUDE_SAMSUNG_HINTS="${INCLUDE_SAMSUNG_HINTS:-off}"     # on|off

# Apply profile defaults before freezing
apply_profile

# ---------- Freeze -------------------------------------------------------------
readonly PROFILE DRY_RUN ANIM_SCALE BACKGROUND_PROCESS_LIMIT ACTIVITY_MAX_CACHED \
  DATA_SAVER BACKGROUND_SYNC_BLACKLIST PRIVATE_DNS_MODE PRIVATE_DNS_HOST \
  REFRESH_MIN REFRESH_MAX DISABLE_ALWAYS_SCANNING WIFI_SCAN_THROTTLE \
  ART_ACTION ART_SPEED_PROFILE_PKGS ART_INCLUDE_SECONDARY ART_RESET_FIRST \
  PHANTOM_MODE STANDBY_BUCKETS PERMISSIONS_TO_REVOKE PERMISSIONS_REVOKE_PACKAGES \
  APP_OPS_PACKAGES APP_OPS_BLOCK_OPS APP_OPS_CLAMP_BLACKLIST APP_OPS_CLAMP_OPS \
  TEST_DOZE CSC INCLUDE_SAMSUNG_HINTS

OUTDIR="${OUTDIR:-./adb-enhancements-$(date +%Y%m%d-%H%M%S)}"; readonly OUTDIR
mkdir -p "$OUTDIR"
ACTIONS_CSV="$OUTDIR/actions.csv"; REENABLE_SCRIPT="$OUTDIR/revert-enhancements.sh"
REVERT_MARKERS="$OUTDIR/revert.markers"; REVERT_MARKERS_DC="$OUTDIR/revert.dc.markers"
REVERT_APPOPS_MARKERS="$OUTDIR/revert.appops.markers"
readonly ACTIONS_CSV REENABLE_SCRIPT REVERT_MARKERS REVERT_MARKERS_DC REVERT_APPOPS_MARKERS
printf "type,target,scope,key,value,action,status,message\n" > "$ACTIONS_CSV"
: > "$REVERT_MARKERS"; : > "$REVERT_MARKERS_DC"; : > "$REVERT_APPOPS_MARKERS"
printf "#!/usr/bin/env bash\nset -Eeuo pipefail\n" > "$REENABLE_SCRIPT"; chmod +x "$REENABLE_SCRIPT"

# ---------- Helpers (all via $ADB) --------------------------------------------
get_setting(){ "$ADB" shell settings get "$1" "$2" 2>/dev/null | tr -d '\r'; }
put_setting(){ "$ADB" shell settings put "$1" "$2" "$3" >/dev/null 2>&1; }
del_setting(){ "$ADB" shell settings delete "$1" "$2" >/dev/null 2>&1; }
dc_get(){ "$ADB" shell device_config get "$1" "$2" 2>/dev/null | tr -d '\r'; }
dc_put(){ "$ADB" shell device_config put "$1" "$2" "$3" >/dev/null 2>&1; }
dc_del(){ "$ADB" shell device_config delete "$1" "$2" >/dev/null 2>&1; }
pkg_uid(){ "$ADB" shell "cmd package list packages -U $1" 2>/dev/null | sed -n 's/.*uid:\([0-9]\+\).*/\1/p' | tr -d '\r'; }

ensure_revert(){
  local scope="$1" key="$2" marker="$scope:$key"
  grep -qxF "$marker" "$REVERT_MARKERS" && return 0
  local old; old="$(get_setting "$scope" "$key")"
  if [[ -z "$old" || "$old" == "null" ]]; then
    echo "$ADB shell settings delete $scope $key" >> "$REENABLE_SCRIPT"
  else
    echo "$ADB shell settings put $scope $key $(printf "%q" "$old")" >> "$REENABLE_SCRIPT"
  fi
  echo "$marker" >> "$REVERT_MARKERS"
}
apply_setting(){
  local scope="$1" key="$2" val="${3-}" act
  ensure_revert "$scope" "$key"
  act=$([[ -z "${val+x}" || -z "$val" ]] && echo delete || echo put)
  if [[ "$DRY_RUN" == "1" ]]; then
    printf "setting,,%s,%s,%s,%s,dry-run,\n" "$scope" "$key" "${val:-}" "$act" >> "$ACTIONS_CSV"
    vlog "DRY setting $scope/$key := '${val-<delete>}'"
    return
  fi
  if [[ "$act" == "delete" ]]; then
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
ensure_dc_revert(){
  local ns="$1" key="$2" marker="$ns:$key"
  grep -qxF "$marker" "$REVERT_MARKERS_DC" && return 0
  local old; old="$(dc_get "$ns" "$key")"
  if [[ -z "$old" || "$old" == "null" ]]; then
    echo "$ADB shell device_config delete $ns $key" >> "$REENABLE_SCRIPT"
  else
    echo "$ADB shell device_config put $ns $key $(printf "%q" "$old")" >> "$REENABLE_SCRIPT"
  fi
  echo "$marker" >> "$REVERT_MARKERS_DC"
}
apply_dc(){
  local ns="$1" key="$2" val="${3-}" act
  ensure_dc_revert "$ns" "$key"
  act=$([[ -z "${val+x}" || -z "$val" ]] && echo delete || echo put)
  if [[ "$DRY_RUN" == "1" ]]; then
    printf "device_config,,%s,%s,%s,%s,dry-run,\n" "$ns" "$key" "${val:-}" "$act" >> "$ACTIONS_CSV"
    vlog "DRY device_config $ns/$key := '${val-<delete>}'"
    return
  fi
  if [[ "$act" == "delete" ]]; then
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

# AppOps helpers (with revert markers)
ensure_appops_revert(){
  local pkg="$1"
  grep -qxF "$pkg" "$REVERT_APPOPS_MARKERS" && return 0
  echo "$ADB shell cmd appops reset $pkg" >> "$REENABLE_SCRIPT"
  echo "$pkg" >> "$REVERT_APPOPS_MARKERS"
}
apply_appops(){
  local pkg="$1" op="$2" mode="$3" # mode: ignore|allow|deny
  ensure_appops_revert "$pkg"
  if [[ "$DRY_RUN" == "1" ]]; then
    printf "cmd,appops,%s,,%s,set,dry-run,%s\n" "$pkg" "$op" "$mode" >> "$ACTIONS_CSV"
    vlog "DRY appops set $pkg $op $mode"
  else
    if "$ADB" shell "cmd appops set $pkg $op $mode" >/dev/null 2>&1; then
      printf "cmd,appops,%s,,%s,set,ok,%s\n" "$pkg" "$op" "$mode" >> "$ACTIONS_CSV"
    else
      printf "cmd,appops,%s,,%s,set,fail,%s\n" "$pkg" "$op" "$mode" >> "$ACTIONS_CSV"
    fi
  fi
}

# ---------- Banner -------------------------------------------------------------
echo "==============================================================================="
echo "  S24U Enhancements v9 | ${MODEL} (${DEVICE}) Android ${ANDROID_VER} OneUI ${ONEUI:-n/a}"
echo "  Serial: ${ANDROID_SERIAL} | Profile=${PROFILE:-<none>} | Dry-run=${DRY_RUN} | Verbose=${VERBOSE}"
echo "  Outdir: ${OUTDIR}"
echo "-------------------------------------------------------------------------------"
echo "  Effective config:"
printf "   - ANIM_SCALE=%s | REFRESH_MIN=%s | REFRESH_MAX=%s\n" "$ANIM_SCALE" "${REFRESH_MIN:-<skip>}" "${REFRESH_MAX:-<skip>}"
printf "   - ART: ACTION=%s SECONDARY=%s RESET_FIRST=%s PGO_PKGS=%s\n" "${ART_ACTION:-<none>}" "$ART_INCLUDE_SECONDARY" "$ART_RESET_FIRST" "${ART_SPEED_PROFILE_PKGS:-<none>}"
printf "   - PHANTOM_MODE=%s | ACTIVITY_MAX_CACHED=%s | BG_LIMIT=%s\n" "$PHANTOM_MODE" "${ACTIVITY_MAX_CACHED:-<skip>}" "${BACKGROUND_PROCESS_LIMIT:-<skip>}"
printf "   - DATA_SAVER=%s | PRIVATE_DNS=%s/%s\n" "${DATA_SAVER:-<skip>}" "${PRIVATE_DNS_MODE:-<skip>}" "${PRIVATE_DNS_HOST:-<n/a>}"
printf "   - ALWAYS_SCANNING_OFF=%s | WIFI_SCAN_THROTTLE=%s\n" "$DISABLE_ALWAYS_SCANNING" "${WIFI_SCAN_THROTTLE:-<skip>}"
printf "   - BACKGROUND_SYNC_BLACKLIST: %s\n" "${BACKGROUND_SYNC_BLACKLIST:-<none>}"
printf "   - STANDBY_BUCKETS: %s\n" "${STANDBY_BUCKETS:-<none>}"
printf "   - APP_OPS_CLAMP_BLACKLIST=%s (%s)\n" "$APP_OPS_CLAMP_BLACKLIST" "$APP_OPS_CLAMP_OPS"
echo "==============================================================================="

# ---------- UI speed ----------
apply_setting global window_animation_scale "${ANIM_SCALE}"
apply_setting global transition_animation_scale "${ANIM_SCALE}"
apply_setting global animator_duration_scale "${ANIM_SCALE}"

[[ -n "$BACKGROUND_PROCESS_LIMIT" ]] && apply_setting global background_process_limit "$BACKGROUND_PROCESS_LIMIT"
[[ -n "$ACTIVITY_MAX_CACHED" ]]     && apply_dc      activity_manager max_cached_processes "$ACTIVITY_MAX_CACHED"

# ---------- Data Saver + per-UID restrict ----------
if [[ -n "$DATA_SAVER" ]]; then
  case "$DATA_SAVER" in
    on|off)
      current="$("$ADB" shell 'dumpsys netpolicy | grep -i restrictBackground' 2>/dev/null | tr -d '\r ' | awk -F: '{print $2}')"
      echo "$ADB cmd netpolicy set restrict-background ${current:-false}" >> "$REENABLE_SCRIPT"
      if [[ "$DRY_RUN" == "1" ]]; then
        printf "cmd,netpolicy,,,,set,dry-run,restrict-background=%s\n" "$DATA_SAVER" >> "$ACTIONS_CSV"
      else
        if "$ADB" shell "cmd netpolicy set restrict-background $([[ "$DATA_SAVER" == "on" ]] && echo true || echo false)" >/dev/null 2>&1; then
          printf "cmd,netpolicy,,,,set,ok,restrict-background\n" >> "$ACTIONS_CSV"
        else
          printf "cmd,netpolicy,,,,set,fail,restrict-background\n" >> "$ACTIONS_CSV"
        fi
      fi
      ;;
    *) warn "DATA_SAVER must be on|off (got '$DATA_SAVER')" ;;
  esac
fi

if [[ -n "$BACKGROUND_SYNC_BLACKLIST" ]]; then
  for pkg in $BACKGROUND_SYNC_BLACKLIST; do
    uid="$(pkg_uid "$pkg")"
    if [[ -z "$uid" ]]; then
      warn "UID not found for $pkg (not installed?)"
      printf "cmd,netpolicy,%s,,,add,skip,uid-not-found\n" "$pkg" >> "$ACTIONS_CSV"
      continue
    fi
    if [[ "$DRY_RUN" == "1" ]]; then
      printf "cmd,netpolicy,%s,,,add,dry-run,restrict-background-blacklist\n" "$uid" >> "$ACTIONS_CSV"
    else
      if "$ADB" shell "cmd netpolicy add restrict-background-blacklist $uid" >/dev/null 2>&1; then
        printf "cmd,netpolicy,%s,,,add,ok,restrict-background-blacklist\n" "$uid" >> "$ACTIONS_CSV"
        echo "$ADB cmd netpolicy remove restrict-background-blacklist $uid" >> "$REENABLE_SCRIPT"
      else
        printf "cmd,netpolicy,%s,,,add,fail,restrict-background-blacklist\n" "$uid" >> "$ACTIONS_CSV"
      fi
    fi
  done
fi

# ---------- Private DNS ----------
case "$PRIVATE_DNS_MODE" in
  off)           apply_setting global private_dns_mode off;          apply_setting global private_dns_specifier "" ;;
  opportunistic) apply_setting global private_dns_mode opportunistic; apply_setting global private_dns_specifier "" ;;
  hostname)      [[ -z "$PRIVATE_DNS_HOST" ]] && warn "PRIVATE_DNS_HOST required" \
                   || { apply_setting global private_dns_mode hostname; apply_setting global private_dns_specifier "$PRIVATE_DNS_HOST"; } ;;
  "" ) ;;
  *  ) warn "Unknown PRIVATE_DNS_MODE '$PRIVATE_DNS_MODE'";;
esac

# ---------- Refresh rate ----------
[[ -n "$REFRESH_MAX" ]] && apply_setting system peak_refresh_rate "$REFRESH_MAX"
[[ -n "$REFRESH_MIN" ]] && apply_setting system min_refresh_rate  "$REFRESH_MIN"

# ---------- Scanning ----------
[[ "$DISABLE_ALWAYS_SCANNING" == "1" ]] && { apply_setting global wifi_scan_always_enabled 0; apply_setting global ble_scan_always_enabled 0; }
[[ -n "$WIFI_SCAN_THROTTLE" ]] && apply_setting global wifi_scan_throttle_enabled "$WIFI_SCAN_THROTTLE"

# ---------- ART ----------
if [[ -n "$ART_ACTION" || -n "$ART_SPEED_PROFILE_PKGS" ]]; then
  [[ "$ART_RESET_FIRST" == "1" ]] && run "$ADB" shell cmd package compile --reset -a
  grep -q "cmd package compile --reset -a" "$REENABLE_SCRIPT" || echo "$ADB shell cmd package compile --reset -a" >> "$REENABLE_SCRIPT"
  local_sec_flag=""; [[ "$ART_INCLUDE_SECONDARY" == "1" ]] && local_sec_flag=" --secondary-dex"
  case "$ART_ACTION" in
    bg)                run "$ADB" shell cmd package bg-dexopt-job ;;
    speed-profile-all) run "$ADB" shell "cmd package compile -m speed-profile${local_sec_flag} -a" ;;
    speed-all)         run "$ADB" shell "cmd package compile -m speed -f${local_sec_flag} -a" ;;
    "" ) ;;
    *  ) warn "Unknown ART_ACTION '$ART_ACTION'";;
  esac
  for p in $ART_SPEED_PROFILE_PKGS; do run "$ADB" shell "cmd package compile -m speed-profile${local_sec_flag} $p" || true; done
  "$ADB" shell dumpsys package dexopt > "$OUTDIR/dexopt-status.txt" 2>/dev/null || true
  if [[ "$DRY_RUN" != "1" && "${ART_ACTION:-}" == speed-all ]]; then
    not_speed="$("$ADB" shell 'dumpsys package dexopt' 2>/dev/null | grep -E "status=" | grep -v "status=speed" | wc -l || true)"
    log "ART compile verification: packages not at 'speed' = ${not_speed}"
  fi
fi

# ---------- Phantom process guard ----------
case "$PHANTOM_MODE" in
  relaxed)
    echo "$ADB shell cmd device_config set_sync_disabled_for_tests none" >> "$REENABLE_SCRIPT"
    run "$ADB" shell cmd device_config set_sync_disabled_for_tests persistent
    run "$ADB" shell device_config put activity_manager max_phantom_processes 2147483647
    ;;
  default|"") ;;
  * ) warn "Unknown PHANTOM_MODE '$PHANTOM_MODE'";;
esac

# ---------- App Standby Buckets -----------
if [[ -n "$STANDBY_BUCKETS" ]]; then
  for pair in $STANDBY_BUCKETS; do
    pkg="${pair%%:*}"; bucket="${pair##*:}"
    [[ -z "$pkg" || -z "$bucket" ]] && { warn "Bad standby pair '$pair' (expected pkg:bucket)"; continue; }
    if [[ "$DRY_RUN" == "1" ]]; then
      printf "cmd,usagestats,%s,,%s,set,dry-run,set-standby-bucket\n" "$pkg" "$bucket" >> "$ACTIONS_CSV"
    else
      if "$ADB" shell am set-standby-bucket "$pkg" "$bucket" >/dev/null 2>&1; then
        printf "cmd,usagestats,%s,,%s,set,ok,set-standby-bucket\n" "$pkg" "$bucket" >> "$ACTIONS_CSV"
      else
        printf "cmd,usagestats,%s,,%s,set,fail,set-standby-bucket\n" "$pkg" "$bucket" >> "$ACTIONS_CSV"
      fi
    fi
  done
fi

# ---------- Optional permission revokes ----------
if [[ -n "$PERMISSIONS_TO_REVOKE" && -n "$PERMISSIONS_REVOKE_PACKAGES" ]]; then
  for pkg in $PERMISSIONS_REVOKE_PACKAGES; do
    for perm in $PERMISSIONS_TO_REVOKE; do
      if [[ "$DRY_RUN" == "1" ]]; then
        printf "pm,permission,%s,,%s,revoke,dry-run,\n" "$pkg" "$perm" >> "$ACTIONS_CSV"
      else
        if "$ADB" shell pm revoke "$pkg" "$perm" >/dev/null 2>&1; then
          printf "pm,permission,%s,,%s,revoke,ok,\n" "$pkg" "$perm" >> "$ACTIONS_CSV"
        else
          printf "pm,permission,%s,,%s,revoke,fail,\n" "$pkg" "$perm" >> "$ACTIONS_CSV"
        fi
      fi
    done
  done
fi

# ---------- Optional app-ops blocking ----------
if [[ -n "$APP_OPS_PACKAGES" && -n "$APP_OPS_BLOCK_OPS" ]]; then
  for pkg in $APP_OPS_PACKAGES; do
    for op in $APP_OPS_BLOCK_OPS; do
      apply_appops "$pkg" "$op" "ignore"
    done
  done
fi

# ---------- Auto clamp: BACKGROUND_SYNC_BLACKLIST → AppOps ---------------------
if [[ -n "$BACKGROUND_SYNC_BLACKLIST" && "${APP_OPS_CLAMP_BLACKLIST,,}" == "on" ]]; then
  for pkg in $BACKGROUND_SYNC_BLACKLIST; do
    for op in $APP_OPS_CLAMP_OPS; do
      apply_appops "$pkg" "$op" "ignore"
    done
  done
fi

# ---------- Doze test ----------
case "$TEST_DOZE" in
  on)      run "$ADB" shell dumpsys battery unplug; run "$ADB" shell dumpsys deviceidle force-idle ;;
  unforce) run "$ADB" shell dumpsys deviceidle unforce; run "$ADB" shell dumpsys battery reset ;;
  off|"")  ;;
esac

# ---------- CSC hints (optional) ----------
if [[ "${INCLUDE_SAMSUNG_HINTS,,}" == "on" ]]; then
  echo "# HINT: If you want to soft-disable Samsung Wallet/Pass/TVPlus/News by CSC here," >> "$REENABLE_SCRIPT"
  echo "# pair this file with s24u-degoogle.sh --include-samsung on and --keep-samsung as needed." >> "$REENABLE_SCRIPT"
fi

# ---------- Summary ------------------------------------------------------------
echo "==============================================================================="

ok_count=$(awk -F, '$6=="ok"'  "$ACTIONS_CSV" | wc -l | tr -d ' ')
fail_count=$(awk -F, '$6=="fail"' "$ACTIONS_CSV" | wc -l | tr -d ' ')
dry_count=$(awk -F, '$6=="dry-run"' "$ACTIONS_CSV" | wc -l | tr -d ' ')
skip_count=$(awk -F, '$6=="skip"' "$ACTIONS_CSV" | wc -l | tr -d ' ')

echo " Done. Artifacts in: ${OUTDIR}"
echo "   - Revert helper    : ${REENABLE_SCRIPT}"
echo "   - Actions CSV      : ${ACTIONS_CSV}"
echo "   - Dexopt snapshot  : ${OUTDIR}/dexopt-status.txt (if ART ran)"
echo " Results: OK=${ok_count}  FAIL=${fail_count}  DRY=${dry_count}  SKIP=${skip_count}"
echo " Reboot recommended. To revert everything from this run:"
echo "   ${REENABLE_SCRIPT}"
echo "==============================================================================="

exit 0
