#!/usr/bin/env bash
# adb-list-packages.sh — Write enabled & disabled package lists to ./adb-packages.txt
# Usage:
#   ./adb-list-packages.sh                # user 0 → ./adb-packages.txt
#   ./adb-list-packages.sh --user 10      # specific user ID
#   ./adb-list-packages.sh --output out.txt

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

# ---- Defaults (readonly) ----
readonly DEFAULT_USER_ID="0"
readonly DEFAULT_OUT_FILE="./adb-packages.txt"

# ---- CLI ----
USER_ID="${DEFAULT_USER_ID}"
OUT_FILE="${DEFAULT_OUT_FILE}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)   USER_ID="${2:-}"; shift 2;;
    --output) OUT_FILE="${2:-}"; shift 2;;
    -h|--help)
      cat <<USAGE
Usage: $0 [--user ID] [--output FILE]
Lists enabled and disabled packages for the chosen Android user and writes them to FILE.
Defaults: --user ${DEFAULT_USER_ID} --output ${DEFAULT_OUT_FILE}
USAGE
      exit 0;;
    *) echo "[ERROR] Unknown argument: $1" >&2; exit 1;;
  esac
done
readonly USER_ID OUT_FILE

# ---- Helpers ----
die(){ printf "[ERROR] %s\n" "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"; }

need adb

# Select device (if multiple)
select_device() {
  mapfile -t lines < <(adb devices | awk 'NR>1 && NF{print $1" "$2}')
  local count="${#lines[@]}"
  (( count == 0 )) && die "No device. Connect over USB and enable USB debugging."
  if (( count == 1 )); then
    local serial status; read -r serial status <<<"${lines[0]}"
    [[ "$status" == "device" ]] || die "Device state is '$status' (authorize USB debugging)."
    export ANDROID_SERIAL="$serial"
    return
  fi
  echo "[*] Multiple devices detected:"
  local i=1; for l in "${lines[@]}"; do printf "  [%d] %s\n" "$i" "$l"; ((i++)); done
  read -r -p "Select device [1-$count]: " pick
  [[ "$pick" =~ ^[0-9]+$ ]] || die "Invalid selection."
  local idx=$((pick-1)) serial status; read -r serial status <<<"${lines[$idx]}"
  [[ "$status" == "device" ]] || die "Selected device state is '$status'."
  export ANDROID_SERIAL="$serial"
}

select_device
adb shell true >/dev/null 2>&1 || die "adb shell not reachable (cable/auth?)."

# Device info (nice to include in header)
MODEL="$(adb shell getprop ro.product.model | tr -d '\r')"
DEVICE="$(adb shell getprop ro.product.device | tr -d '\r')"
ANDROID_VER="$(adb shell getprop ro.build.version.release | tr -d '\r')"
ONEUI="$(adb shell getprop ro.build.version.oneui 2>/dev/null | tr -d '\r' || true)"
SERIAL="${ANDROID_SERIAL:-$(adb get-serialno 2>/dev/null || echo 'unknown')}"

# Grab lists (per-user); strip "package:" prefix; sort unique
readarray -t ENABLED < <(adb shell "pm list packages -e --user ${USER_ID}" \
  | tr -d '\r' | sed 's/^package://g' | LC_ALL=C sort -u)
readarray -t DISABLED < <(adb shell "pm list packages -d --user ${USER_ID}" \
  | tr -d '\r' | sed 's/^package://g' | LC_ALL=C sort -u)

readonly ENABLED DISABLED

# Write file
{
  printf "# ADB Package Inventory\n"
  printf "# Device: %s (%s) | Android %s | One UI %s | Serial %s\n" "${MODEL}" "${DEVICE}" "${ANDROID_VER}" "${ONEUI:-unknown}" "${SERIAL}"
  printf "# User: %s | Generated: %s\n\n" "${USER_ID}" "$(date -u +'%Y-%m-%d %H:%M:%S UTC')"

  printf "## Enabled packages (%d)\n" "${#ENABLED[@]}"
  if ((${#ENABLED[@]})); then printf "%s\n" "${ENABLED[@]}"; fi
  printf "\n"

  printf "## Disabled packages (%d)\n" "${#DISABLED[@]}"
  if ((${#DISABLED[@]})); then printf "%s\n" "${DISABLED[@]}"; fi
  printf "\n"

  printf "# Notes\n"
  printf "#   - Enabled list via:  adb shell pm list packages -e --user %s\n" "${USER_ID}"
  printf "#   - Disabled list via: adb shell pm list packages -d --user %s\n" "${USER_ID}"
} > "${OUT_FILE}"

printf "[OK] Wrote %s (enabled: %d, disabled: %d)\n" "${OUT_FILE}" "${#ENABLED[@]}" "${#DISABLED[@]}"
