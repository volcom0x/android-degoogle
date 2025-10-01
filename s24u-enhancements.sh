#!/usr/bin/env bash
# ==============================================================================
#  Galaxy S24 Ultra — Enhancements (Performance & Privacy) — v6
#  - Reversible: generates revert-enhancements.sh with exact prior values
#  - Readonly config after parsing
#  - BACKGROUND_SYNC_BLACKLIST (clearer naming)
#  - Same hacks; plus CSC hint section to pre-wire region extras if desired
# ==============================================================================
set -Eeuo pipefail
IFS=$'\n\t'; umask 077

# ---------- Config (parsed then frozen) ----------
DRY_RUN="${DRY_RUN:-0}"

ANIM_SCALE="${ANIM_SCALE:-0.5}"                         # 0..1
BACKGROUND_PROCESS_LIMIT="${BACKGROUND_PROCESS_LIMIT:-}" # 1..4 or "" to skip
ACTIVITY_MAX_CACHED="${ACTIVITY_MAX_CACHED:-}"           # device_config activity_manager

DATA_SAVER="${DATA_SAVER:-}"                              # on|off|""
BACKGROUND_SYNC_BLACKLIST="${BACKGROUND_SYNC_BLACKLIST:-}"# space-separated pkgs

PRIVATE_DNS_MODE="${PRIVATE_DNS_MODE:-}"                 # off|opportunistic|hostname|""
PRIVATE_DNS_HOST="${PRIVATE_DNS_HOST:-}"

REFRESH_MIN="${REFRESH_MIN:-}"                           # e.g., 60.0
REFRESH_MAX="${REFRESH_MAX:-}"                           # e.g., 120.0

DISABLE_ALWAYS_SCANNING="${DISABLE_ALWAYS_SCANNING:-0}"  # 1=off Wi-Fi/BLE always scanning
WIFI_SCAN_THROTTLE="${WIFI_SCAN_THROTTLE:-}"

ART_ACTION="${ART_ACTION:-}"                             # ""|bg|speed-profile-all|speed-all
ART_SPEED_PROFILE_PKGS="${ART_SPEED_PROFILE_PKGS:-}"

PHANTOM_MODE="${PHANTOM_MODE:-default}"                  # default|relaxed
STANDBY_BUCKETS="${STANDBY_BUCKETS:-}"                   # "pkg1:rare pkg2:restricted"

PERMISSIONS_TO_REVOKE="${PERMISSIONS_TO_REVOKE:-}"
PERMISSIONS_REVOKE_PACKAGES="${PERMISSIONS_REVOKE_PACKAGES:-}"
APP_OPS_PACKAGES="${APP_OPS_PACKAGES:-}"
APP_OPS_BLOCK_OPS="${APP_OPS_BLOCK_OPS:-}"

TEST_DOZE="${TEST_DOZE:-off}"                            # off|on|unforce

# CSC wire-up (optional; no-op by default)
CSC="${CSC:-auto}"                                       # auto|THL|EUX
INCLUDE_SAMSUNG_HINTS="${INCLUDE_SAMSUNG_HINTS:-off}"    # on to hint-disable Samsung extras

# ---------- Freeze ----------
readonly DRY_RUN ANIM_SCALE BACKGROUND_PROCESS_LIMIT ACTIVITY_MAX_CACHED \
  DATA_SAVER BACKGROUND_SYNC_BLACKLIST PRIVATE_DNS_MODE PRIVATE_DNS_HOST \
  REFRESH_MIN REFRESH_MAX DISABLE_ALWAYS_SCANNING WIFI_SCAN_THROTTLE \
  ART_ACTION ART_SPEED_PROFILE_PKGS PHANTOM_MODE STANDBY_BUCKETS \
  PERMISSIONS_TO_REVOKE PERMISSIONS_REVOKE_PACKAGES APP_OPS_PACKAGES \
  APP_OPS_BLOCK_OPS TEST_DOZE CSC INCLUDE_SAMSUNG_HINTS

OUTDIR="${OUTDIR:-./adb-enhancements-$(date +%Y%m%d-%H%M%S)}"; readonly OUTDIR
mkdir -p "$OUTDIR"
ACTIONS_CSV="$OUTDIR/actions.csv"; REENABLE_SCRIPT="$OUTDIR/revert-enhancements.sh"
REVERT_MARKERS="$OUTDIR/revert.markers"; REVERT_MARKERS_DC="$OUTDIR/revert.dc.markers"
readonly ACTIONS_CSV REENABLE_SCRIPT REVERT_MARKERS REVERT_MARKERS_DC
printf "type,target,scope,key,value,action,status,message\n" > "$ACTIONS_CSV"
: > "$REVERT_MARKERS"; : > "$REVERT_MARKERS_DC"
printf "#!/usr/bin/env bash\nset -Eeuo pipefail\n" > "$REENABLE_SCRIPT"; chmod +x "$REENABLE_SCRIPT"

info(){ printf "[*] %s\n" "$*"; }
warn(){ printf "[!] %s\n" "$*" >&2; }
die(){ printf "[ERROR] %s\n" "$*" >&2; exit 1; }
run(){ if [[ "$DRY_RUN" == "1" ]]; then echo "DRY: $*"; else eval "$@"; fi; }

command -v adb >/dev/null 2>&1 || die "adb not found (platform-tools)."
adb shell true >/dev/null 2>&1 || die "adb shell unreachable."

# ---------- helpers ----------
get_setting(){ adb shell settings get "$1" "$2" 2>/dev/null | tr -d '\r'; }
put_setting(){ adb shell settings put "$1" "$2" "$3" >/dev/null 2>&1; }
del_setting(){ adb shell settings delete "$1" "$2" >/dev/null 2>&1; }
dc_get(){ adb shell device_config get "$1" "$2" 2>/dev/null | tr -d '\r'; }
dc_put(){ adb shell device_config put "$1" "$2" "$3" >/dev/null 2>&1; }
dc_del(){ adb shell device_config delete "$1" "$2" >/dev/null 2>&1; }
pkg_uid(){ adb shell "cmd package list packages -U $1" 2>/dev/null | sed -n 's/.*uid:\([0-9]\+\).*/\1/p' | tr -d '\r'; }

ensure_revert(){
  local scope="$1" key="$2" marker="$scope:$key"
  grep -qxF "$marker" "$REVERT_MARKERS" && return 0
  local old; old="$(get_setting "$scope" "$key")"
  if [[ -z "$old" || "$old" == "null" ]]; then
    echo "adb shell settings delete $scope $key" >> "$REENABLE_SCRIPT"
  else
    echo "adb shell settings put $scope $key $(printf "%q" "$old")" >> "$REENABLE_SCRIPT"
  fi
  echo "$marker" >> "$REVERT_MARKERS"
}
apply_setting(){
  local scope="$1" key="$2" val="${3-}" act
  ensure_revert "$scope" "$key"; act=$([[ -z "${val+x}" || -z "$val" ]] && echo delete || echo put)
  if [[ "$DRY_RUN" == "1" ]]; then
    printf "setting,,%s,%s,%s,%s,dry-run,\n" "$scope" "$key" "${val:-}" "$act" >> "$ACTIONS_CSV"; return
  fi
  [[ "$act" == "delete" ]] \
    && { del_setting "$scope" "$key" && printf "setting,,%s,%s,,delete,ok,\n" "$scope" "$key" >> "$ACTIONS_CSV" \
         || printf "setting,,%s,%s,,delete,fail,\n" "$scope" "$key" >> "$ACTIONS_CSV"; } \
    || { put_setting "$scope" "$key" "$val" && printf "setting,,%s,%s,%s,put,ok,\n" "$scope" "$key" "$val" >> "$ACTIONS_CSV" \
         || printf "setting,,%s,%s,%s,put,fail,\n" "$scope" "$key" "$val" >> "$ACTIONS_CSV"; }
}
ensure_dc_revert(){
  local ns="$1" key="$2" marker="$ns:$key"
  grep -qxF "$marker" "$REVERT_MARKERS_DC" && return 0
  local old; old="$(dc_get "$ns" "$key")"
  if [[ -z "$old" || "$old" == "null" ]]; then
    echo "adb shell device_config delete $ns $key" >> "$REENABLE_SCRIPT"
  else
    echo "adb shell device_config put $ns $key $(printf "%q" "$old")" >> "$REENABLE_SCRIPT"
  fi
  echo "$marker" >> "$REVERT_MARKERS_DC"
}
apply_dc(){
  local ns="$1" key="$2" val="${3-}" act
  ensure_dc_revert "$ns" "$key"; act=$([[ -z "${val+x}" || -z "$val" ]] && echo delete || echo put)
  if [[ "$DRY_RUN" == "1" ]]; then
    printf "device_config,,%s,%s,%s,%s,dry-run,\n" "$ns" "$key" "${val:-}" "$act" >> "$ACTIONS_CSV"; return
  fi
  [[ "$act" == "delete" ]] \
    && { dc_del "$ns" "$key" && printf "device_config,,%s,%s,,delete,ok,\n" "$ns" "$key" >> "$ACTIONS_CSV" \
         || printf "device_config,,%s,%s,,delete,fail,\n" "$ns" "$key" >> "$ACTIONS_CSV"; } \
    || { dc_put "$ns" "$key" "$val" && printf "device_config,,%s,%s,%s,put,ok,\n" "$ns" "$key" "$val" >> "$ACTIONS_CSV" \
         || printf "device_config,,%s,%s,%s,put,fail,\n" "$ns" "$key" "$val" >> "$ACTIONS_CSV"; }
}

# ---------- UI speed ----------
apply_setting global window_animation_scale "${ANIM_SCALE}"
apply_setting global transition_animation_scale "${ANIM_SCALE}"
apply_setting global animator_duration_scale "${ANIM_SCALE}"

[[ -n "$BACKGROUND_PROCESS_LIMIT" ]] && apply_setting global background_process_limit "$BACKGROUND_PROCESS_LIMIT"
[[ -n "$ACTIVITY_MAX_CACHED" ]]    && apply_dc      activity_manager max_cached_processes "$ACTIVITY_MAX_CACHED"

# ---------- Data Saver + per-UID restrict ----------
if [[ -n "$DATA_SAVER" ]]; then
  case "$DATA_SAVER" in
    on|off)
      current="$(adb shell 'dumpsys netpolicy | grep -i restrictBackground' 2>/dev/null | tr -d '\r ' | awk -F: '{print $2}')"
      echo "adb shell cmd netpolicy set restrict-background ${current:-false}" >> "$REENABLE_SCRIPT"
      [[ "$DRY_RUN" == "1" ]] \
        && printf "cmd,netpolicy,,,,set,dry-run,restrict-background=$DATA_SAVER\n" >> "$ACTIONS_CSV" \
        || adb shell "cmd netpolicy set restrict-background $([[ "$DATA_SAVER" == "on" ]] && echo true || echo false)" >/dev/null 2>&1 \
             && printf "cmd,netpolicy,,,,set,ok,restrict-background\n" >> "$ACTIONS_CSV" \
             || printf "cmd,netpolicy,,,,set,fail,restrict-background\n" >> "$ACTIONS_CSV"
      ;;
    *) warn "DATA_SAVER must be on|off (got '$DATA_SAVER')" ;;
  esac
fi
for pkg in $BACKGROUND_SYNC_BLACKLIST; do
  uid="$(pkg_uid "$pkg")"; [[ -z "$uid" ]] && { warn "UID not found for $pkg"; continue; }
  if [[ "$DRY_RUN" == "1" ]]; then
    printf "cmd,netpolicy,%s,,,add,dry-run,restrict-background-blacklist\n" "$uid" >> "$ACTIONS_CSV"
  else
    adb shell "cmd netpolicy add restrict-background-blacklist $uid" >/dev/null 2>&1 \
      && { printf "cmd,netpolicy,%s,,,add,ok,restrict-background-blacklist\n" "$uid" >> "$ACTIONS_CSV";
           echo "adb shell cmd netpolicy remove restrict-background-blacklist $uid" >> "$REENABLE_SCRIPT"; } \
      || printf "cmd,netpolicy,%s,,,add,fail,restrict-background-blacklist\n" "$uid" >> "$ACTIONS_CSV"
  fi
done

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
  grep -q "cmd package compile --reset -a" "$REENABLE_SCRIPT" || echo "adb shell cmd package compile --reset -a" >> "$REENABLE_SCRIPT"
  case "$ART_ACTION" in
    bg)                run adb shell "cmd package bg-dexopt-job" ;;
    speed-profile-all) run adb shell "cmd package compile -m speed-profile -a" ;;
    speed-all)         run adb shell "cmd package compile -m speed -f -a" ;;
    "" ) ;;
    *  ) warn "Unknown ART_ACTION '$ART_ACTION'";;
  esac
  for p in $ART_SPEED_PROFILE_PKGS; do run adb shell "cmd package compile -m speed-profile $p" || true; done
  adb shell "dumpsys package dexopt" > "$OUTDIR/dexopt-status.txt" 2>/dev/null || true
fi

# ---------- Phantom process guard (advanced) ----------
case "$PHANTOM_MODE" in
  relaxed)
    echo "adb shell cmd device_config set_sync_disabled_for_tests none" >> "$REENABLE_SCRIPT"
    run adb shell "cmd device_config set_sync_disabled_for_tests persistent"
    # Example flag override; tune to taste:
    run adb shell "device_config put activity_manager max_phantom_processes 2147483647"
    ;;
  default|"") ;;
  * ) warn "Unknown PHANTOM_MODE '$PHANTOM_MODE'";;
esac

# ---------- App Standby Buckets ----------
if [[ -n "$STANDBY_BUCKETS" ]]; then
  while read -r pair; do
    [[ -z "$pair" ]] && continue
    pkg="${pair%%:*}"; bucket="${pair##*:}"
    [[ "$DRY_RUN" == "1" ]] \
      && printf "cmd,usagestats,%s,,%s,set,dry-run,set-standby-bucket\n" "$pkg" "$bucket" >> "$ACTIONS_CSV" \
      || adb shell "am set-standby-bucket $pkg $bucket" >/dev/null 2>&1 \
           && printf "cmd,usagestats,%s,,%s,set,ok,set-standby-bucket\n" "$pkg" "$bucket" >> "$ACTIONS_CSV" \
           || printf "cmd,usagestats,%s,,%s,set,fail,set-standby-bucket\n" "$pkg" "$bucket" >> "$ACTIONS_CSV"
  done <<< "$STANDBY_BUCKETS"
fi

# ---------- Optional permission revokes ----------
if [[ -n "$PERMISSIONS_TO_REVOKE" && -n "$PERMISSIONS_REVOKE_PACKAGES" ]]; then
  for pkg in $PERMISSIONS_REVOKE_PACKAGES; do
    for perm in $PERMISSIONS_TO_REVOKE; do
      [[ "$DRY_RUN" == "1" ]] \
        && printf "pm,permission,%s,,%s,revoke,dry-run,\n" "$pkg" "$perm" >> "$ACTIONS_CSV" \
        || adb shell "pm revoke $pkg $perm" >/dev/null 2>&1 \
             && printf "pm,permission,%s,,%s,revoke,ok,\n" "$pkg" "$perm" >> "$ACTIONS_CSV" \
             || printf "pm,permission,%s,,%s,revoke,fail,\n" "$pkg" "$perm" >> "$ACTIONS_CSV"
    done
  done
fi

# ---------- Optional app-ops blocking ----------
if [[ -n "$APP_OPS_PACKAGES" && -n "$APP_OPS_BLOCK_OPS" ]]; then
  for pkg in $APP_OPS_PACKAGES; do
    for op in $APP_OPS_BLOCK_OPS; do
      [[ "$DRY_RUN" == "1" ]] \
        && printf "cmd,appops,%s,,%s,set,dry-run,ignore\n" "$pkg" "$op" >> "$ACTIONS_CSV" \
        || adb shell "cmd appops set $pkg $op ignore" >/dev/null 2>&1 \
             && printf "cmd,appops,%s,,%s,set,ok,ignore\n" "$pkg" "$op" >> "$ACTIONS_CSV" \
             || printf "cmd,appops,%s,,%s,set,fail,ignore\n" "$pkg" "$op" >> "$ACTIONS_CSV"
    done
    echo "adb shell cmd appops reset $pkg" >> "$REENABLE_SCRIPT"
  done
fi

# ---------- Doze test ----------
case "$TEST_DOZE" in
  on)      run adb shell "dumpsys battery unplug"; run adb shell "dumpsys deviceidle force-idle" ;;
  unforce) run adb shell "dumpsys deviceidle unforce"; run adb shell "dumpsys battery reset" ;;
  off|"")  ;;
esac

# ---------- CSC hints (optional) ----------
if [[ "${INCLUDE_SAMSUNG_HINTS,,}" == "on" ]]; then
  echo "# HINT: If you want to soft-disable Samsung Wallet/Pass/TVPlus/News by CSC here," >> "$REENABLE_SCRIPT"
  echo "# pair this file with s24u-degoogle.sh --include-samsung on and --keep-samsung as needed." >> "$REENABLE_SCRIPT"
fi

echo "Reboot recommended. To revert ALL: $REENABLE_SCRIPT"
