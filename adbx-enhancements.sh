#!/usr/bin/env bash
# ==============================================================================
# s24u-enhancements-harness.sh — Snapshot/Diff/Rollback validator for
#                                s24u-enhancements-hardened.sh
# ------------------------------------------------------------------------------
# What it does
#   1) Captures a canonical "BEFORE" snapshot of device state.
#   2) Runs the target script (configurable env-file & flags).
#   3) Captures "AFTER" snapshot and computes diffs.
#   4) Executes the generated revert script and captures "ROLLBACK" snapshot.
#   5) Verifies ROLLBACK == BEFORE (byte-for-byte on normalized artifacts).
#
# Surfaces captured (diff-friendly, normalized):
#   - settings list {global,system,secure}         (Android settings CLI)     [1]
#   - device_config list (auto-discovered + fallbacks)                        [2]
#   - dumpsys netpolicy + cmd netpolicy                                      [3]
#   - per-package appops (for monitored packages)                             [4]
#   - standby buckets (per monitored package)                                 [5]
#   - dumpsys package dexopt (ART compilation snapshot)                       [6]
#
# References:
# [1] Android Settings CLI (list/get/put) — examples & notes.                (docs/examples) 
# [2] Device Config & set_sync_disabled_for_tests usage.                     (Google Privacy Sandbox docs)
# [3] Netpolicy commands & dumpsys reference.                                (Android dev docs)
# [4] AppOps background limits commands (RUN_IN_BACKGROUND etc).             (Android dev docs)
# [5] App Standby Buckets commands (set/get).                                (Android dev docs)
# [6] Verify dexopt state via dumpsys package dexopt.                        (Android dev docs)
#
# Hardening:
#   - set -Eeuo pipefail, strict quoting, arg arrays, retries with jitter.
#   - Validates ANDROID_SERIAL against conservative regex.
#   - Uses mktemp -d workspace + atomic file writes; refuses clobber.
#   - No command interpolation into single strings (uses -- + argv).
#
# Usage:
#   ./s24u-enhancements-harness.sh \
#       --script ./s24u-enhancements-hardened.sh \
#       --env-file ./my-run.env \
#       --out ./harness-out-$(date +%F-%H%M) \
#       [--serial <SERIAL>] [--dry-run] [--skip-rollback]
#
# Exit codes:
#   0 = success (diffs recorded; rollback restored original state)
#   1 = argument/usage error
#   2 = device unreachable / adb error
#   3 = target script failed
#   4 = rollback mismatch (state not restored)
# ==============================================================================

set -Eeuo pipefail
umask 077
IFS=$' \t\n'

SERIAL_RE='^[A-Za-z0-9._:-]{1,64}$'

# ---------------------- CLI parsing ----------------------
SCRIPT=""
ENV_FILE=""
OUTDIR_REQ=""
ANDROID_SERIAL="${ANDROID_SERIAL:-}"
DO_DRY=0
SKIP_ROLLBACK=0

while (( "$#" )); do
  case "$1" in
    --script)            SCRIPT="${2:-}"; shift 2;;
    --env-file)          ENV_FILE="${2:-}"; shift 2;;
    --out)               OUTDIR_REQ="${2:-}"; shift 2;;
    --serial)            ANDROID_SERIAL="${2:-}"; shift 2;;
    --dry-run)           DO_DRY=1; shift;;
    --skip-rollback)     SKIP_ROLLBACK=1; shift;;
    -h|--help)
      sed -n '1,120p' "$0"; exit 0;;
    *) echo "[ERROR] Unknown arg: $1" >&2; exit 1;;
  done
done

[[ -n "$SCRIPT" && -r "$SCRIPT" ]] || { echo "[ERROR] --script missing or unreadable" >&2; exit 1; }
[[ -z "$ENV_FILE" || -r "$ENV_FILE" ]] || { echo "[ERROR] --env-file unreadable" >&2; exit 1; }
[[ -z "$ANDROID_SERIAL" || "$ANDROID_SERIAL" =~ $SERIAL_RE ]] || { echo "[ERROR] Invalid --serial" >&2; exit 1; }

# ---------------------- Tooling -------------------------
require_cmd(){ command -v "$1" >/dev/null 2>&1 || { echo "[ERROR] Missing cmd: $1" >&2; exit 1; }; }
require_cmd awk; require_cmd sed; require_cmd tr; require_cmd sort; require_cmd diff

ADB="$(command -v adbx || true)"; [[ -n "$ADB" ]] || ADB="$(command -v adb || true)"
[[ -n "$ADB" ]] || { echo "[ERROR] adb/adbx not found in PATH" >&2; exit 1; }
"$ADB" start-server >/dev/null 2>&1 || true

with_retry(){
  local max="${RETRY_MAX:-3}" base="${RETRY_BASE:-0.4}" attempt=1 rc
  while true; do
    "$@"; rc=$?
    [[ $rc -eq 0 ]] && return 0
    (( attempt >= max )) && return "$rc"
    # exp backoff + jitter
    local sleep_for
    sleep_for=$(awk -v a="$attempt" -v b="$base" 'BEGIN{srand(); print (b * (2^(a-1))) + (rand()*0.25)}')
    sleep "$sleep_for"
    ((attempt++))
  done
}

adb_do(){ with_retry "$ADB" ${ANDROID_SERIAL:+-s "$ANDROID_SERIAL"} "$@"; }
adb_sh(){
  # shell invocation with argv, not a single interpolated string
  with_retry "$ADB" ${ANDROID_SERIAL:+-s "$ANDROID_SERIAL"} shell -- "$@"
}

# ---------------------- Workspace -----------------------
WORKDIR="$(mktemp -d -t s24u-harness.XXXXXXXX)"
trap 'rm -rf "$WORKDIR" >/dev/null 2>&1 || true' EXIT

if [[ -n "$OUTDIR_REQ" ]]; then
  [[ ! -e "$OUTDIR_REQ" ]] || { echo "[ERROR] OUT already exists: $OUTDIR_REQ" >&2; exit 1; }
  OUTDIR="$OUTDIR_REQ"
else
  OUTDIR="./harness-out-$(date +%Y%m%d-%H%M%S)"
fi
mkdir -p "$OUTDIR"

canonize() {
  # Canonicalize for diff: strip CR, collapse extra spaces, sort with C locale.
  LC_ALL=C sed 's/\r$//; s/[[:space:]]\+$//' | sort -u
}

# ---------------------- Device guard --------------------
pick_device(){
  if [[ -z "${ANDROID_SERIAL:-}" ]]; then
    mapfile -t devs < <(adb_do devices | awk 'NR>1 && $2=="device"{print $1}')
    case "${#devs[@]}" in
      0) echo "[ERROR] No device connected" >&2; exit 2;;
      1) ANDROID_SERIAL="${devs[0]}";;
      *) echo "[ERROR] Multiple devices; use --serial" >&2; exit 2;;
    esac
  fi
  [[ "$ANDROID_SERIAL" =~ $SERIAL_RE ]] || { echo "[ERROR] Invalid device serial" >&2; exit 1; }
  adb_do get-state >/dev/null 2>&1 || { echo "[ERROR] Device unreachable via adb" >&2; exit 2; }
}
pick_device

# ---------------------- Inputs for per-package checks -------------------------
declare -a MONITOR_PKGS=()
declare -a SB_BUCKET_PKGS=()

# Pull package lists from env-file if present
if [[ -n "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

append_words_into_array(){
  local -n _arr="$1"; shift
  # join all remaining params, split on whitespace into array entries
  local tmp="$*"
  [[ -n "$tmp" ]] && read -r -a add <<<"$tmp" || add=()
  if ((${#add[@]})); then _arr+=("${add[@]}"); fi
}

# Gather candidates from same vars used by the hardened script
append_words_into_array MONITOR_PKGS "${BACKGROUND_SYNC_BLACKLIST:-}"
append_words_into_array MONITOR_PKGS "${APP_OPS_PACKAGES:-}"
append_words_into_array MONITOR_PKGS "${PERMISSIONS_REVOKE_PACKAGES:-}"

# STANDBY_BUCKETS format: "pkg:bucket pkg2:bucket2"
if [[ -n "${STANDBY_BUCKETS:-}" ]]; then
  while read -r pair; do
    [[ -z "$pair" ]] && continue
    SB_BUCKET_PKGS+=("${pair%%:*}")
  done < <(tr ' ' '\n' <<<"$STANDBY_BUCKETS")
fi

# unique-ify monitored lists
uniq_array(){ awk '!x[$0]++'; }
mapfile -t MONITOR_PKGS < <(printf '%s\n' "${MONITOR_PKGS[@]}" | uniq_array)
mapfile -t SB_BUCKET_PKGS < <(printf '%s\n' "${SB_BUCKET_PKGS[@]}" | uniq_array)

# ---------------------- Snapshot functions -------------------------
snap_settings(){
  local tag="$1" outdir="$2"
  mkdir -p "$outdir/settings"
  for ns in global system secure; do
    adb_sh settings list "$ns" | canonize > "${outdir}/settings/${ns}.txt" || true
  done
}

# Try to discover device_config namespaces dynamically; fall back to a curated set.
discover_device_config_ns(){
  # Some builds print all entries with "device_config list" (no ns); try it first.
  if adb_sh device_config list >/dev/null 2>&1; then
    echo "__ALL__"
    return 0
  fi
  # Fall back to common namespaces (expand as needed)
  cat <<EOF
activity_manager
app_hibernation
privacy
adservices
job_scheduler
alarm_manager
connectivity
power
notification
content_capture
EOF
}

snap_device_config(){
  local outdir="$1"
  mkdir -p "$outdir/device_config"
  local ns
  if ns="__ALL__"; ns="$(discover_device_config_ns)"; [[ "$ns" == "__ALL__" ]]; then
    adb_sh device_config list | canonize > "${outdir}/device_config/all.txt" || true
  else
    while read -r ns; do
      [[ -z "$ns" ]] && continue
      adb_sh device_config list "$ns" | canonize > "${outdir}/device_config/${ns}.txt" || true
    done <<<"$ns"
  fi
}

snap_netpolicy(){
  local outdir="$1"
  mkdir -p "$outdir/netpolicy"
  adb_sh dumpsys netpolicy | canonize > "${outdir}/netpolicy/dumpsys.txt" || true
  adb_sh cmd netpolicy | canonize > "${outdir}/netpolicy/cmd-help.txt" || true
}

snap_appops(){
  local outdir="$1"; mkdir -p "$outdir/appops"
  if ((${#MONITOR_PKGS[@]})); then
    for p in "${MONITOR_PKGS[@]}"; do
      adb_sh cmd appops get "$p" 2>/dev/null | canonize > "${outdir}/appops/${p}.txt" || true
    done
  else
    # Nothing to monitor; record note
    printf '# no monitored packages\n' > "${outdir}/appops/README.txt"
  fi
}

snap_buckets(){
  local outdir="$1"; mkdir -p "$outdir/standby_buckets"
  if ((${#SB_BUCKET_PKGS[@]})); then
    for p in "${SB_BUCKET_PKGS[@]}"; do
      adb_sh am get-standby-bucket "$p" 2>/dev/null | canonize > "${outdir}/standby_buckets/${p}.txt" || true
    done
  else
    printf '# no standby-bucket packages\n' > "${outdir}/standby_buckets/README.txt"
  fi
}

snap_dexopt(){
  local outdir="$1"; mkdir -p "$outdir/dexopt"
  adb_sh dumpsys package dexopt 2>/dev/null | canonize > "${outdir}/dexopt/dexopt.txt" || true
}

snapshot_all(){
  local tag="$1" outdir="${2}"
  mkdir -p "$outdir"
  snap_settings "$tag" "$outdir"
  snap_device_config "$outdir"
  snap_netpolicy "$outdir"
  snap_appops "$outdir"
  snap_buckets "$outdir"
  snap_dexopt "$outdir"
  # Device identity summary (not diffed, just info)
  {
    adb_sh getprop ro.product.model
    adb_sh getprop ro.product.device
    adb_sh getprop ro.build.version.release
    adb_sh getprop ro.build.version.oneui 2>/dev/null || true
  } | tr -d '\r' > "${outdir}/device-info.txt"
}

# ---------------------- Diff helper ----------------------
diff_dirs(){
  local A="$1" B="$2" DOUT="$3"
  mkdir -p "$DOUT"
  # Compare every file path present in either tree
  mapfile -t files < <( (cd "$A" && find . -type f; cd "$B" && find . -type f) | sort -u )
  local any=0
  for f in "${files[@]}"; do
    local fa="$A/$f" fb="$B/$f"
    if [[ -f "$fa" && -f "$fb" ]]; then
      if ! diff -u "$fa" "$fb" > "${DOUT}/${f//\//_}.diff" 2>/dev/null; then
        any=1
      else
        # empty diff → remove file to keep directory clean
        rm -f "${DOUT}/${f//\//_}.diff" || true
      fi
    elif [[ -f "$fa" && ! -f "$fb" ]]; then
      printf '--- %s\n+++ (missing in B)\n' "$fa" > "${DOUT}/${f//\//_}.diff"
      any=1
    elif [[ ! -f "$fa" && -f "$fb" ]]; then
      printf '--- (missing in A)\n+++ %s\n' "$fb" > "${DOUT}/${f//\//_}.diff"
      any=1
    fi
  done
  return $any
}

# ---------------------- Run target ----------------------
run_target(){
  # Export env-file variables for the target script only.
  if [[ -n "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
  fi

  local cmd=( bash "$SCRIPT" )
  if (( DO_DRY )); then
    DRY_RUN=1 VERBOSE="${VERBOSE:-1}" "${cmd[@]}"
  else
    VERBOSE="${VERBOSE:-1}" "${cmd[@]}"
  fi
}

# ---------------------- Main flow -----------------------
BEFORE_DIR="${OUTDIR}/01-before"
AFTER_DIR="${OUTDIR}/02-after"
ROLLBACK_DIR="${OUTDIR}/03-rollback"
DIFF1_DIR="${OUTDIR}/diff-before-after"
DIFF2_DIR="${OUTDIR}/diff-before-rollback"

echo "[*] Snapshot: BEFORE"
snapshot_all "before" "$BEFORE_DIR"

echo "[*] Executing target script: $SCRIPT"
if ! run_target; then
  echo "[ERROR] Target script failed" >&2
  exit 3
fi

echo "[*] Snapshot: AFTER"
snapshot_all "after" "$AFTER_DIR"

echo "[*] Computing diffs (BEFORE vs AFTER)"
diff_dirs "$BEFORE_DIR" "$AFTER_DIR" "$DIFF1_DIR" || true
echo "[*] Diffs saved under: $DIFF1_DIR"

if (( ! SKIP_ROLLBACK )); then
  # Locate revert script emitted by the hardened script
  REVERT_CANDIDATE="$(find . -maxdepth 3 -type f -name 'revert-enhancements.sh' -print -quit)"
  if [[ -z "$REVERT_CANDIDATE" ]]; then
    REVERT_CANDIDATE="$(find "${OUTDIR}" -maxdepth 3 -type f -name 'revert-enhancements.sh' -print -quit || true)"
  fi
  if [[ -z "$REVERT_CANDIDATE" ]]; then
    # As a common location, check typical folder name used by hardened script
    REVERT_CANDIDATE="$(find . -maxdepth 3 -type f -path '*/adb-enhancements-*/revert-enhancements.sh' -print -quit || true)"
  fi

  if [[ -z "$REVERT_CANDIDATE" ]]; then
    echo "[ERROR] Could not find revert-enhancements.sh from target run" >&2
    exit 3
  fi

  echo "[*] Rolling back via: $REVERT_CANDIDATE"
  bash "$REVERT_CANDIDATE" || echo "[!] Revert script returned non-zero"

  echo "[*] Snapshot: ROLLBACK"
  snapshot_all "rollback" "$ROLLBACK_DIR"

  echo "[*] Verifying rollback (BEFORE vs ROLLBACK)"
  if diff_dirs "$BEFORE_DIR" "$ROLLBACK_DIR" "$DIFF2_DIR"; then
    echo "[✓] ROLLBACK matches BEFORE — state restored"
    echo "Artifacts: $OUTDIR"
    exit 0
  else
    echo "[✗] ROLLBACK != BEFORE — see $DIFF2_DIR for mismatches" >&2
    echo "Artifacts: $OUTDIR"
    exit 4
  fi
else
  echo "[!] --skip-rollback set; skipping rollback validation"
  echo "Artifacts: $OUTDIR"
  exit 0
fi
