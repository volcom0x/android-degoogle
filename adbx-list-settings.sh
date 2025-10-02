#!/usr/bin/env bash
# adbx-snapshot-settings.sh — Snapshot Android Settings (system/secure/global),
# DeviceConfig (all namespaces), and system properties (`getprop`).
#
# - Prefers `adbx` (device-bound wrapper), falls back to `adb` (override via ADB_BIN)
# - Honors ANDROID_SERIAL if multiple devices are attached
# - Works per-user for system/secure; global is device-wide
# - Robust output: one timestamped folder with per-section files
#
# Usage:
#   ./adbx-snapshot-settings.sh                   # user 0 → ./adb-snapshot-YYYYmmdd-HHMMSS
#   ./adbx-snapshot-settings.sh --user 10         # pick Android user ID
#   ./adbx-snapshot-settings.sh --out ./dump      # pick output directory
#   ANDROID_SERIAL=R5... ./adbx-snapshot-settings.sh
#   ADB_BIN=/custom/adb ./adbx-snapshot-settings.sh
#
# Security/robustness:
#   - set -Eeuo pipefail, umask 077
#   - single-shell calls per section (no per-key loops)
#   - graceful fallbacks for DeviceConfig enumeration

set -Eeuo pipefail
umask 077
IFS=$'\n\t'

# ---------- Defaults ----------
USER_ID="0"
OUTDIR="./adb-snapshot-$(date +%Y%m%d-%H%M%S)"

# ---------- CLI ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) USER_ID="${2:-}"; shift 2;;
    --out)  OUTDIR="${2:-}"; shift 2;;
    -h|--help)
      cat <<USAGE
Usage: $0 [--user ID] [--out DIR]
Snapshots:
  - Settings (system/secure/global)
  - DeviceConfig (all namespaces)
  - System properties (getprop)
Environment:
  ANDROID_SERIAL  Target device serial (overrides auto-pick)
  ADB_BIN         Path to adb/adbx binary (overrides auto-detect)
USAGE
      exit 0;;
    *) printf '[ERROR] Unknown arg: %s\n' "$1" >&2; exit 1;;
  esac
done

# ---------- ADB shim (prefer adbx) ----------
die(){ printf '[ERROR] %s\n' "$*" >&2; exit 1; }
ADB="${ADB_BIN:-}"
if [[ -n "${ADB}" && -x "${ADB}" ]]; then
  : # honor override
elif command -v adbx >/dev/null 2>&1; then
  ADB="adbx"
elif command -v adb >/dev/null 2>&1; then
  ADB="adb"
else
  die "adb/adbx not found in PATH."
fi
ADB_PATH="$(command -v "$ADB")"
"$ADB" start-server >/dev/null 2>&1 || true

# ---------- Device pick (authorized only) ----------
pick_device() {
  local serial state
  if [[ -n "${ANDROID_SERIAL:-}" ]]; then
    serial="$ANDROID_SERIAL"
  else
    if [[ "$(basename "$ADB_PATH")" == "adbx" ]]; then
      serial="$("$ADB" get-serialno 2>/dev/null || true)"
      [[ "$serial" == "unknown" || -z "$serial" ]] && serial=""
    fi
    if [[ -z "$serial" ]]; then
      mapfile -t devs < <("$ADB" devices -l | awk 'NR>1 && $2=="device"{print $1}')
      ((${#devs[@]}==0)) && die "No authorized devices. Enable USB debugging and accept RSA."
      ((${#devs[@]}==1)) || die "Multiple devices: ${devs[*]} — set ANDROID_SERIAL to choose."
      serial="${devs[0]}"
    fi
  fi
  state="$("$ADB" -s "$serial" get-state 2>/dev/null || true)"
  case "$state" in
    device) export ANDROID_SERIAL="$serial" ;;
    unauthorized) die "Device '$serial' unauthorized — accept RSA on the phone." ;;
    offline|'')  die "Device '$serial' offline/unreachable — replug cable or fix udev." ;;
    *)           die "Unexpected device state for '$serial': $state" ;;
  esac
}
pick_device

mkdir -p "$OUTDIR"

# ---------- Device info (header) ----------
MODEL="$("$ADB" -s "$ANDROID_SERIAL" shell getprop ro.product.model | tr -d '\r')"
DEVICE="$("$ADB" -s "$ANDROID_SERIAL" shell getprop ro.product.device | tr -d '\r')"
ANDROID_VER="$("$ADB" -s "$ANDROID_SERIAL" shell getprop ro.build.version.release | tr -d '\r')"
ONEUI="$("$ADB" -s "$ANDROID_SERIAL" shell getprop ro.build.version.oneui 2>/dev/null | tr -d '\r' || true)"

# ---------- Helpers ----------
snapshot_cmd() { # snapshot_cmd "desc" "cmd" "outfile"
  local desc="$1" cmd="$2" outfile="$3"
  printf '[*] %-40s → %s\n' "$desc" "$outfile"
  if ! output="$(eval "$cmd" 2>/dev/null | sed 's/\r$//' )"; then
    printf '[!] Failed: %s\n' "$desc" >&2
    return 1
  fi
  printf '%s\n' "$output" > "$outfile"
}

# ---------- Settings (system/secure/global) ----------
# Per-user: system, secure; device-wide: global
S_SYS="$OUTDIR/settings-system-user${USER_ID}.txt"
S_SEC="$OUTDIR/settings-secure-user${USER_ID}.txt"
S_GLO="$OUTDIR/settings-global.txt"

# Some vendor builds allow --user on global, but we'll call it without to be safe.
snapshot_cmd "settings list system (user $USER_ID)" \
  "$ADB -s \"$ANDROID_SERIAL\" shell settings --user $USER_ID list system" \
  "$S_SYS"
snapshot_cmd "settings list secure (user $USER_ID)" \
  "$ADB -s \"$ANDROID_SERIAL\" shell settings --user $USER_ID list secure" \
  "$S_SEC"
snapshot_cmd "settings list global" \
  "$ADB -s \"$ANDROID_SERIAL\" shell settings list global" \
  "$S_GLO"

# ---------- DeviceConfig (all namespaces if available) ----------
# Primary path: cmd device_config list-namespaces → list <ns>
# Fallback: dumpsys device_config (raw) if enumeration not supported.
DC_NS="$OUTDIR/device_config-namespaces.txt"
DC_ALL="$OUTDIR/device_config-all.txt"
DC_RAW="$OUTDIR/device_config-dumpsys.txt"

have_dc_ns=0
if "$ADB" -s "$ANDROID_SERIAL" shell 'cmd device_config list-namespaces' >/dev/null 2>&1; then
  "$ADB" -s "$ANDROID_SERIAL" shell 'cmd device_config list-namespaces' | tr -d '\r' | sort -u > "$DC_NS" || true
  if [[ -s "$DC_NS" ]]; then
    have_dc_ns=1
    : > "$DC_ALL"
    while IFS= read -r ns; do
      [[ -z "$ns" ]] && continue
      out_ns="$OUTDIR/device_config-${ns}.txt"
      snapshot_cmd "device_config list ${ns}" \
        "$ADB -s \"$ANDROID_SERIAL\" shell cmd device_config list \"$ns\"" \
        "$out_ns"
      # Append with namespace header to one combined file
      {
        printf '### %s\n' "$ns"
        cat "$out_ns"
        printf '\n'
      } >> "$DC_ALL"
    done < "$DC_NS"
  fi
fi

# Fallback/raw dump (always keep a copy for debugging)
"$ADB" -s "$ANDROID_SERIAL" shell dumpsys device_config 2>/dev/null | sed 's/\r$//' > "$DC_RAW" || true

# ---------- System properties (getprop) ----------
GP_RAW="$OUTDIR/getprop-raw.txt"
GP_PROP="$OUTDIR/getprop.properties"

snapshot_cmd "getprop (raw)" \
  "$ADB -s \"$ANDROID_SERIAL\" shell getprop" \
  "$GP_RAW"

# Convert "[key]: [val]" → "key=value"
awk '
  BEGIN{FS="]: \\["}
  /^\[/ {
    gsub(/^\\[/,"",$1); gsub(/\\]$/,"",$2);
    print $1"="$2
  }
' "$GP_RAW" | LC_ALL=C sort -u > "$GP_PROP" || true

# ---------- Terminal summary ----------
count_lines(){ [[ -f "$1" ]] && wc -l < "$1" | tr -d ' ' || echo 0; }
n_sys=$(count_lines "$S_SYS"); n_sec=$(count_lines "$S_SEC"); n_glo=$(count_lines "$S_GLO")
n_dc=0; [[ -f "$DC_ALL" ]] && n_dc=$(grep -Ev '^(#|$)' "$DC_ALL" | wc -l | tr -d ' ')
n_prop=$(count_lines "$GP_PROP")

echo "--------------------------------------------------------------------------------"
printf "Device: %s (%s) | Android %s | One UI %s | Serial %s | User %s | ADB %s\n" \
  "$MODEL" "$DEVICE" "$ANDROID_VER" "${ONEUI:-unknown}" "$ANDROID_SERIAL" "$USER_ID" "$ADB_PATH"
echo "Output dir: $OUTDIR"
printf "  settings system (user %s): %d entries  → %s\n" "$USER_ID" "$n_sys" "$S_SYS"
printf "  settings secure (user %s): %d entries  → %s\n" "$USER_ID" "$n_sec" "$S_SEC"
printf "  settings global          : %d entries  → %s\n" "$n_glo" "$S_GLO"
if [[ "$have_dc_ns" -eq 1 ]]; then
  ns_count=$(count_lines "$DC_NS")
  printf "  device_config namespaces : %d namespaces → %s\n" "$ns_count" "$DC_NS"
  printf "  device_config flags      : %d flags (combined) → %s\n" "$n_dc" "$DC_ALL"
else
  echo "  device_config namespaces : not enumerated (see raw dump) → $DC_RAW"
fi
printf "  getprop properties       : %d entries → %s\n" "$n_prop" "$GP_PROP"
echo "--------------------------------------------------------------------------------"
echo "[OK] Snapshot complete."
