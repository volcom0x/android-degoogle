#!/usr/bin/env bash
# adb-list-packages.sh — Write enabled & disabled package lists to ./adb-packages.txt
# Usage:
#   ./adb-list-packages.sh                       # user 0 → ./adb-packages.txt
#   ./adb-list-packages.sh --user 10             # specific user ID
#   ./adb-list-packages.sh --output out.txt
#   ANDROID_SERIAL=R5C... ./adb-list-packages.sh # pin device explicitly
#   ADB_BIN=/custom/path/adb ./adb-list-packages.sh  # force a specific adb
#
# Notes:
# - Prefers `adbx` (wrapper bound to a serial), then `adb`. You can override with $ADB_BIN.
# - Uses `pm list packages -e/-d --user N` to enumerate enabled/disabled packages.

set -Eeuo pipefail
umask 077
IFS=$'\n\t'

# ---- Defaults ----
DEFAULT_USER_ID="0"
DEFAULT_OUT_FILE="./adb-packages.txt"

# ---- CLI ----
USER_ID="$DEFAULT_USER_ID"
OUT_FILE="$DEFAULT_OUT_FILE"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)   USER_ID="${2:-}"; shift 2;;
    --output) OUT_FILE="${2:-}"; shift 2;;
    -h|--help)
      cat <<USAGE
Usage: $0 [--user ID] [--output FILE]
Lists enabled and disabled packages (per Android user) and writes them to FILE.
Defaults: --user ${DEFAULT_USER_ID} --output ${DEFAULT_OUT_FILE}

Environment:
  ANDROID_SERIAL  Target device serial (overrides auto-pick)
  ADB_BIN         Path to adb/adbx binary (overrides auto-detect)
USAGE
      exit 0;;
    *) printf "[ERROR] Unknown argument: %s\n" "$1" >&2; exit 1;;
  esac
done

# ---- Logging helpers ----
die(){ printf "[ERROR] %s\n" "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"; }

# ---- ADB shim (prefer adbx, then adb; allow ADB_BIN override) ----
ADB="${ADB_BIN:-}"
if [[ -n "${ADB}" && -x "${ADB}" ]]; then
  : # use provided absolute path
elif command -v adbx >/dev/null 2>&1; then
  ADB="adbx"
elif command -v adb >/dev/null 2>&1; then
  ADB="adb"
else
  die "adb/adbx not found in PATH. Install platform-tools."
fi
ADB_PATH="$(command -v "$ADB")"

# Start server if needed
"$ADB" start-server >/dev/null 2>&1 || true

# ---- Device selection (honor ANDROID_SERIAL; else adbx-bound; else auto-pick) ----
pick_device() {
  local serial state
  if [[ -n "${ANDROID_SERIAL:-}" ]]; then
    serial="$ANDROID_SERIAL"
  else
    # If using adbx wrapper, try its bound serial first
    if [[ "$(basename "$ADB_PATH")" == "adbx" ]]; then
      serial="$("$ADB" get-serialno 2>/dev/null || true)"
      [[ "$serial" == "unknown" || -z "$serial" ]] && serial=""
    fi
    # Otherwise, pick first authorized device
    if [[ -z "$serial" ]]; then
      mapfile -t devs < <("$ADB" devices -l | awk 'NR>1 && $2=="device"{print $1}')
      ((${#devs[@]}==0)) && die "No authorized devices. Enable USB debugging and accept RSA on the phone."
      ((${#devs[@]}==1)) || die "Multiple devices detected: ${devs[*]} — set ANDROID_SERIAL to choose."
      serial="${devs[0]}"
    fi
  fi

  # Validate device state
  state="$("$ADB" -s "$serial" get-state 2>/dev/null || true)"
  case "$state" in
    device) export ANDROID_SERIAL="$serial" ;;
    unauthorized) die "Device '$serial' is UNAUTHORIZED. Revoke & re-accept USB debugging RSA." ;;
    offline|'')  die "Device '$serial' is OFFLINE/unreachable. Replug USB or fix udev/permissions." ;;
    *)           die "Unexpected device state for '$serial': $state" ;;
  esac
}
pick_device

# ---- Device info (header metadata) ----
MODEL="$("$ADB" -s "$ANDROID_SERIAL" shell getprop ro.product.model | tr -d '\r')"
DEVICE="$("$ADB" -s "$ANDROID_SERIAL" shell getprop ro.product.device | tr -d '\r')"
ANDROID_VER="$("$ADB" -s "$ANDROID_SERIAL" shell getprop ro.build.version.release | tr -d '\r')"
ONEUI="$("$ADB" -s "$ANDROID_SERIAL" shell getprop ro.build.version.oneui 2>/dev/null | tr -d '\r' || true)"

# ---- Retrieve package lists (per-user) ----
# -e = enabled, -d = disabled; --user N to scope to a specific Android user
readarray -t ENABLED < <("$ADB" -s "$ANDROID_SERIAL" shell "pm list packages -e --user ${USER_ID}" \
  | tr -d '\r' | sed 's/^package://g' | LC_ALL=C sort -u)
readarray -t DISABLED < <("$ADB" -s "$ANDROID_SERIAL" shell "pm list packages -d --user ${USER_ID}" \
  | tr -d '\r' | sed 's/^package://g' | LC_ALL=C sort -u)

# ---- Write result file ----
{
  printf "# ADB Package Inventory\n"
  printf "# Device: %s (%s) | Android %s | One UI %s | Serial %s\n" \
    "${MODEL}" "${DEVICE}" "${ANDROID_VER}" "${ONEUI:-unknown}" "${ANDROID_SERIAL}"
  printf "# User: %s | Generated: %s | ADB: %s\n\n" \
    "${USER_ID}" "$(date -u +'%Y-%m-%d %H:%M:%S UTC')" "${ADB_PATH}"

  printf "## Enabled packages (%d)\n" "${#ENABLED[@]}"
  ((${#ENABLED[@]})) && printf "%s\n" "${ENABLED[@]}"
  printf "\n"

  printf "## Disabled packages (%d)\n" "${#DISABLED[@]}"
  ((${#DISABLED[@]})) && printf "%s\n" "${DISABLED[@]}"
  printf "\n"

  printf "# Commands used\n"
  printf "#   - Enabled:  pm list packages -e --user %s\n"  "${USER_ID}"
  printf "#   - Disabled: pm list packages -d --user %s\n"  "${USER_ID}"
} > "${OUT_FILE}"

printf "[OK] Wrote %s (enabled: %d, disabled: %d) using %s (serial=%s)\n" \
  "${OUT_FILE}" "${#ENABLED[@]}" "${#DISABLED[@]}" "${ADB_PATH}" "${ANDROID_SERIAL}"
