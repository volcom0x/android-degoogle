#!/usr/bin/env bash
# ==============================================================================
#  Galaxy S24 Ultra — De-Google (Reversible) via ADB — v6
#  - Non-root, per-user safe disable (pm disable-user --user N)
#  - 3 privacy profiles + granular keep flags
#  - CSC-aware carrier/Samsung toggles (THL/EUX/auto)
#  - microG preset (keeps GmsCore/Gsf/Store; warns if no signature spoofing)
#  - Dry-run, CSV logs, re-enable helper, role safety checks
#  - Constants & user-config are readonly after parsing
# ==============================================================================
set -Eeuo pipefail
shopt -s lastpipe
IFS=$'\n\t'; umask 077

# ------------------------- Defaults (frozen after parse) -----------------------
MODE="balanced"                  # strict|balanced|permissive
WITH_FLAGS=""                    # comma list: push,store,sync,rcs,auto,wear,ar,tts
CSC="auto"                       # auto|THL|EUX
INCLUDE_CARRIER="off"            # off|on  (add CSC carriers to targets)
INCLUDE_SAMSUNG="off"            # off|on  (add Samsung extras to targets)
KEEP_SAMSUNG=""                  # comma list to KEEP: wallet,pass,tvplus,free,game,smartthings,globalgoals
PRESET=""                        # microg|"" (microG keeps GmsCore/Gsf/Store)
DETECT_MICROG="on"               # on|off (auto-detect org.microg.* and protect)
SAFE_MODE=1                      # 1=target Google prefixes only unless allowed
ALLOW_NON_GOOGLE=0               # override SAFE_MODE guard
USER_ID=0                        # Android user
DRY_RUN=0
LIST_TARGETS=0
NO_PROMPT=0
OUTDIR=""
INCLUDE_FILE=""
EXCLUDE_FILE=""
ONLY_FILE=""

usage() {
  cat <<'USAGE'
Usage:
  s24u-degoogle.sh [--mode strict|balanced|permissive]
                   [--with push,store,sync,rcs,auto,wear,ar,tts]
                   [--preset microg] [--detect-microg on|off]
                   [--csc auto|THL|EUX] [--include-carrier on|off]
                   [--include-samsung on|off] [--keep-samsung flags]
                   [--include-file PATH] [--exclude-file PATH] [--only-file PATH]
                   [--allow-non-google] [--safe-mode 0|1] [--user-id N]
                   [--list-targets] [--dry-run] [--no-prompt] [--outdir DIR]

Profiles
  strict       : remove Google consumer apps + most Google/ads services (opt-in keeps via --with)
  balanced     : remove consumer apps; KEEP Play/GSF/Store/Sync by default
  permissive   : remove consumer apps only (maximum compatibility)

Freedom Controls
  --with FLAGS : KEEP services even in strict mode (comma list):
                 push (GMS), store (Play), sync (contacts/calendar),
                 rcs (Carrier Services), auto (Android Auto),
                 wear (Wear OS), ar (ARCore/VR), tts (Google TTS)

CSC-aware toggles
  --csc auto|THL|EUX          : detect via getprop or force region
  --include-carrier on|off    : if on, include regional carrier apps (safe; only if present)
  --include-samsung on|off    : if on, include Samsung extras (TV Plus, Free/News, Wallet, Pass, Game*)
  --keep-samsung flags        : comma KEEP list among wallet,pass,tvplus,free,game,smartthings,globalgoals

microG preset
  --preset microg             : protect com.google.android.gms/gsf/com.android.vending for microG
  --detect-microg on|off      : auto-protect when org.microg.* present

Safety & scope
  --only-file PATH            : disable ONLY packages from this file (overrides profiles)
  --include-file PATH         : add extra packages to targets (one per line)
  --exclude-file PATH         : NEVER disable listed packages (whitelist)
  --user-id N                 : target user (default 0)
  --safe-mode 0|1             : 1 (default) target only Google prefixes unless allowed
  --allow-non-google          : permit disabling non-Google when safe-mode=1

Ops
  --list-targets              : print final target list and exit
  --dry-run                   : simulate (log + reenable script, no changes)
  --no-prompt                 : skip confirmation prompt
  --outdir DIR                : output dir (default ./adb-degoogle-TS)
USAGE
}

# ------------------------------ Parse CLI -------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="${2:?}"; shift 2;;
    --with) WITH_FLAGS="${2:?}"; shift 2;;
    --preset) PRESET="${2:?}"; shift 2;;
    --detect-microg) DETECT_MICROG="${2:?}"; shift 2;;
    --csc) CSC="${2:?}"; shift 2;;
    --include-carrier) INCLUDE_CARRIER="${2:?}"; shift 2;;
    --include-samsung) INCLUDE_SAMSUNG="${2:?}"; shift 2;;
    --keep-samsung) KEEP_SAMSUNG="${2:?}"; shift 2;;
    --include-file) INCLUDE_FILE="${2:?}"; shift 2;;
    --exclude-file) EXCLUDE_FILE="${2:?}"; shift 2;;
    --only-file) ONLY_FILE="${2:?}"; shift 2;;
    --allow-non-google) ALLOW_NON_GOOGLE=1; shift;;
    --safe-mode) SAFE_MODE="${2:?}"; shift 2;;
    --user-id) USER_ID="${2:?}"; shift 2;;
    --list-targets) LIST_TARGETS=1; shift;;
    --dry-run) DRY_RUN=1; shift;;
    --no-prompt) NO_PROMPT=1; shift;;
    --outdir) OUTDIR="${2:?}"; shift 2;;
    --help|-h) usage; exit 0;;
    *) printf '[ERROR] Unknown arg: %s\n' "$1"; usage; exit 1;;
  esac
done

# --------------------------- Freeze config (readonly) --------------------------
readonly MODE WITH_FLAGS PRESET DETECT_MICROG CSC INCLUDE_CARRIER INCLUDE_SAMSUNG \
         KEEP_SAMSUNG SAFE_MODE ALLOW_NON_GOOGLE USER_ID DRY_RUN LIST_TARGETS \
         NO_PROMPT INCLUDE_FILE EXCLUDE_FILE ONLY_FILE
TS="$(date +%Y%m%d-%H%M%S)"; readonly TS
OUTDIR="${OUTDIR:-./adb-degoogle-$TS}"; readonly OUTDIR
mkdir -p "$OUTDIR"
ACTIONS_CSV="$OUTDIR/actions.csv"; readonly ACTIONS_CSV
REENABLE_SCRIPT="$OUTDIR/reenable.sh"; readonly REENABLE_SCRIPT
SESSION_LOG="$OUTDIR/session.log"; readonly SESSION_LOG

# --------------------------- Logging & helpers --------------------------------
exec > >(tee -a "$SESSION_LOG") 2>&1
info(){ printf "[*] %s\n" "$*"; }
warn(){ printf "[!] %s\n" "$*" >&2; }
die(){ printf "[ERROR] %s\n" "$*" >&2; exit 1; }

# ------------------------------ ADB sanity ------------------------------------
command -v adb >/dev/null 2>&1 || die "adb not found (install Android platform-tools)."
adb get-state >/dev/null 2>&1 || die "No device. Connect USB & enable USB debugging."
adb shell true >/dev/null 2>&1 || die "adb shell unreachable."
MODEL="$(adb shell getprop ro.product.model | tr -d '\r')"
ANDROID_VER="$(adb shell getprop ro.build.version.release | tr -d '\r')"
ONEUI="$(adb shell getprop ro.build.version.oneui | tr -d '\r' || true)"
printf "package,group,action,status,message\n" > "$ACTIONS_CSV"
printf "#!/usr/bin/env bash\nset -Eeuo pipefail\n" > "$REENABLE_SCRIPT"; chmod +x "$REENABLE_SCRIPT"

pkg_exists(){ adb shell "pm path $1" >/dev/null 2>&1; }
in_list(){ local x="$1"; shift; for y in "$@"; do [[ "$x" == "$y" ]] && return 0; done; return 1; }

# -------------------------- CSC detection (THL/EUX) ---------------------------
detect_csc() {
  # Prefer ro.csc.sales_code on Samsung; fallbacks if needed.
  local sc; sc="$(adb shell getprop ro.csc.sales_code | tr -d '\r')" || true
  [[ -z "$sc" || "$sc" == "null" ]] && sc="$(adb shell getprop ro.csc.country_code | tr -d '\r')" || true
  [[ -z "$sc" || "$sc" == "null" ]] && sc="$(adb shell getprop ro.boot.hwc | tr -d '\r')" || true
  echo "$sc"
}

if [[ "${CSC,,}" == "auto" ]]; then
  DETECTED_CSC="$(detect_csc)"
  [[ -n "$DETECTED_CSC" ]] && CSC="$DETECTED_CSC"
fi
# Normalize to high-level region family if it's multi-CSC like EUX/THL.
case "${CSC^^}" in
  THL*) CSC_FAMILY="THL";;
  EUX*|OXM*) CSC_FAMILY="EUX";;   # EUX usually inside OXM multi-CSC
  *) CSC_FAMILY="OTHER";;
esac
readonly CSC CSC_FAMILY
info "CSC: requested=${CSC} → family=${CSC_FAMILY}"

# ------------------------------ microG detect ---------------------------------
has_pkg(){ adb shell "pm path $1" >/dev/null 2>&1; }
detect_microg_env(){
  # Heuristic: presence of org.microg.* components
  has_pkg org.microg.gms.droidguard || has_pkg org.microg.nlp || has_pkg org.microg.nlp.backend.ichnaea
}
[[ "${DETECT_MICROG,,}" == "on" ]] && { detect_microg_env && MICROG_PRESENT="yes" || MICROG_PRESENT="no"; } || MICROG_PRESENT="skip"
readonly MICROG_PRESENT

# ------------------------------ Guards & policies -----------------------------
safe_mode_allows(){
  [[ "$SAFE_MODE" != "1" ]] && return 0
  [[ "$ALLOW_NON_GOOGLE" == "1" ]] && return 0
  [[ "$1" =~ ^com\.google\. ]] || [[ "$1" == "com.android.vending" ]] \
    || [[ "$1" == "com.google.android.gsf" ]] || [[ "$1" == "com.google.android.gsf.login" ]]
}

PROTECT_LIST=(
  # Do-not-touch: critical telephony/contacts stacks + WebView
  com.google.android.webview com.android.webview
  com.android.providers.contacts com.android.providers.telephony
  com.android.phone com.android.server.telecom
  com.samsung.android.dialer com.samsung.android.messaging
  com.samsung.android.contacts com.samsung.android.incallui
)

# microG preset extends PROTECT_LIST
if [[ "${PRESET,,}" == "microg" || "$MICROG_PRESENT" == "yes" ]]; then
  PROTECT_LIST+=(
    com.google.android.gms          # GmsCore (microG uses same package ID)
    com.google.android.gsf          # GsfProxy (same ID)
    com.android.vending             # (FakeStore or real Play Store)
  )
  warn "microG preset active — GMS/GSF/Store will be KEPT. Ensure your ROM supports signature spoofing." \
    && echo "# microG preset protected core" >> "$REENABLE_SCRIPT"
fi

# Merge user whitelist
if [[ -n "$EXCLUDE_FILE" && -f "$EXCLUDE_FILE" ]]; then
  while IFS= read -r line; do [[ -n "$line" && ! "$line" =~ ^# ]] && PROTECT_LIST+=("$line"); done < "$EXCLUDE_FILE"
fi
readonly -a PROTECT_LIST

should_skip(){
  local p="$1"
  in_list "$p" "${PROTECT_LIST[@]}" && { printf "protected"; return 0; }
  safe_mode_allows "$p" || { printf "non-google (safe-mode)"; return 0; }
  return 1
}

disable_pkg(){
  local pkg="$1" group="$2" reason
  if reason="$(should_skip "$pkg")"; then printf "%s,%s,disable,skip,%s\n" "$pkg" "$group" "$reason" >> "$ACTIONS_CSV"; return; fi
  if ! pkg_exists "$pkg"; then printf "%s,%s,disable,skip,not-installed\n" "$pkg" "$group" >> "$ACTIONS_CSV"; return; fi
  if [[ "$DRY_RUN" == "1" ]]; then printf "%s,%s,disable,dry-run,\n" "$pkg" "$group" >> "$ACTIONS_CSV"; return; fi
  if adb shell "pm disable-user --user $USER_ID $pkg" >/dev/null 2>&1; then
    printf "%s,%s,disable,ok,\n" "$pkg" "$group" >> "$ACTIONS_CSV"
    echo "adb shell pm enable --user $USER_ID $pkg" >> "$REENABLE_SCRIPT"
  else
    printf "%s,%s,disable,fail,permission-or-policy\n" "$pkg" "$group" >> "$ACTIONS_CSV"
  fi
}

# ------------------------------ Google stacks ---------------------------------
CORE_PLAY_STACK=( com.android.vending com.google.android.gms com.google.android.gsf com.google.android.gsf.login )
SYNC_STACK=( com.google.android.syncadapters.contacts com.google.android.syncadapters.calendar )
RCS_STACK=( com.google.android.ims )
AUTO_STACK=( com.google.android.projection.gearhead )
WEAR_STACK=( com.google.android.wearable.app com.google.android.apps.wear.companion )
AR_STACK=( com.google.ar.core com.google.vr.vrcore )
TTS_STACK=( com.google.android.tts )
ADSERVICES_STACK=( com.google.android.adservices.api )

GOOGLE_APPS=(
  com.google.android.googlequicksearchbox com.google.android.youtube
  com.google.android.apps.youtube.music com.google.android.gm
  com.google.android.apps.maps com.google.android.apps.docs
  com.google.android.apps.photos com.google.android.apps.meetings
  com.google.android.apps.tachyon com.google.android.chrome
  com.google.android.calendar com.google.android.contacts
  com.google.android.apps.messaging com.google.android.play.games
  com.google.android.apps.podcasts com.google.android.keep
  com.google.android.videos com.google.android.apps.nbu.files
)
readonly -a CORE_PLAY_STACK SYNC_STACK RCS_STACK AUTO_STACK WEAR_STACK AR_STACK \
            TTS_STACK ADSERVICES_STACK GOOGLE_APPS

# --------------------------- Samsung + CSC bundles ----------------------------
# Samsung extras (disable if INCLUDE_SAMSUNG=on, unless kept)
SAMSUNG_EXTRAS_common=(
  com.samsung.android.app.spage      # Samsung Free/News panel
  com.samsung.android.tvplus         # Samsung TV Plus (phone/tablet)
  com.samsung.android.game.gamehome  # Game Launcher
  com.samsung.android.game.gos       # Game Optimizing Service
  com.samsung.sree                   # Global Goals
  com.samsung.android.oneconnect     # SmartThings
  com.samsung.android.app.tips       # Tips
)
# Wallet & Pass are split with keep flags because many users want them
SAMSUNG_WALLET=( com.samsung.android.spay )
SAMSUNG_PASS=( com.samsung.android.samsungpass )

# THL carriers (Thailand): AIS, dtac, True
THL_CARRIERS=( com.ais.mimo.eservice th.co.crie.tron2.android com.truelife.mobile.android.trueiservice )
# EUX common carrier self-care apps (examples; safe if not present)
EUX_CARRIERS=( com.myvodafoneapp uk.co.o2.android.myo2 de.telekom.android.customercenter com.orange.orangeetmoi )
readonly -a SAMSUNG_EXTRAS_common SAMSUNG_WALLET SAMSUNG_PASS THL_CARRIERS EUX_CARRIERS

# Parse keep-samsung flags
IFS=',' read -r -a KEEP_SAM_ARR <<<"${KEEP_SAMSUNG,,}"
keep_sam_flag(){ local f="${1,,}"; for x in "${KEEP_SAM_ARR[@]:-}"; do [[ "$x" == "$f" ]] && return 0; done; return 1; }

# ------------------------------- WITH flags -----------------------------------
IFS=',' read -r -a WITH <<<"${WITH_FLAGS,,}"; readonly -a WITH
want_flag(){ local f="${1,,}"; for x in "${WITH[@]:-}"; do [[ "$x" == "$f" ]] && return 0; done; return 1; }

# ----------------------------- Build TARGETS ----------------------------------
declare -a TARGETS=()
if [[ -n "$ONLY_FILE" ]]; then
  while IFS= read -r line; do [[ -n "$line" && ! "$line" =~ ^# ]] && TARGETS+=("$line"); done < "$ONLY_FILE"
else
  case "${MODE,,}" in
    strict)
      TARGETS+=( "${GOOGLE_APPS[@]}" "${ADSERVICES_STACK[@]}" )
      want_flag push  || TARGETS+=( "${CORE_PLAY_STACK[@]}" )
      want_flag store || TARGETS+=( com.android.vending )
      want_flag sync  || TARGETS+=( "${SYNC_STACK[@]}" )
      want_flag rcs   || TARGETS+=( "${RCS_STACK[@]}" )
      want_flag auto  || TARGETS+=( "${AUTO_STACK[@]}" )
      want_flag wear  || TARGETS+=( "${WEAR_STACK[@]}" )
      want_flag ar    || TARGETS+=( "${AR_STACK[@]}" )
      want_flag tts   || TARGETS+=( "${TTS_STACK[@]}" )
      ;;
    balanced|default)
      TARGETS+=( "${GOOGLE_APPS[@]}" "${ADSERVICES_STACK[@]}" )
      [[ "$(want_flag rcs; echo $?)" -ne 0 ]]  && TARGETS+=( "${RCS_STACK[@]}" )
      [[ "$(want_flag auto; echo $?)" -ne 0 ]] && TARGETS+=( "${AUTO_STACK[@]}" )
      [[ "$(want_flag wear; echo $?)" -ne 0 ]] && TARGETS+=( "${WEAR_STACK[@]}" )
      [[ "$(want_flag ar; echo $?)" -ne 0 ]]   && TARGETS+=( "${AR_STACK[@]}" )
      [[ "$(want_flag tts; echo $?)" -ne 0 ]]  && TARGETS+=( "${TTS_STACK[@]}" )
      ;;
    permissive)
      TARGETS+=( "${GOOGLE_APPS[@]}" )
      if ! want_flag push && ! want_flag store; then TARGETS+=( "${ADSERVICES_STACK[@]}" ); fi
      ;;
    *) die "Unknown --mode '$MODE'";;
  esac

  # Samsung extras if requested
  if [[ "${INCLUDE_SAMSUNG,,}" == "on" ]]; then
    # add common extras; then conditionally wallet/pass unless kept
    TARGETS+=( "${SAMSUNG_EXTRAS_common[@]}" )
    keep_sam_flag wallet || TARGETS+=( "${SAMSUNG_WALLET[@]}" )
    keep_sam_flag pass   || TARGETS+=( "${SAMSUNG_PASS[@]}" )
    keep_sam_flag tvplus && TARGETS=( "${TARGETS[@]/com.samsung.android.tvplus}" )
    keep_sam_flag free   && TARGETS=( "${TARGETS[@]/com.samsung.android.app.spage}" )
    keep_sam_flag game   && TARGETS=( "${TARGETS[@]/com.samsung.android.game.gamehome}" )
    keep_sam_flag smartthings && TARGETS=( "${TARGETS[@]/com.samsung.android.oneconnect}" )
    keep_sam_flag globalgoals && TARGETS=( "${TARGETS[@]/com.samsung.sree}" )
  fi

  # CSC carriers (safe; skip if not installed)
  if [[ "${INCLUDE_CARRIER,,}" == "on" ]]; then
    case "$CSC_FAMILY" in
      THL) TARGETS+=( "${THL_CARRIERS[@]}" );;
      EUX) TARGETS+=( "${EUX_CARRIERS[@]}" );;
    esac
  fi

  # include-file extras
  if [[ -n "$INCLUDE_FILE" && -f "$INCLUDE_FILE" ]]; then
    while IFS= read -r line; do [[ -n "$line" && ! "$line" =~ ^# ]] && TARGETS+=("$line"); done < "$INCLUDE_FILE"
  fi
fi

# microG preset: ensure we do NOT target GMS/GSF/Store
if [[ "${PRESET,,}" == "microg" || "$MICROG_PRESENT" == "yes" ]]; then
  # remove these from TARGETS if present
  TMP=()
  for p in "${TARGETS[@]}"; do
    case "$p" in
      com.google.android.gms|com.google.android.gsf|com.android.vending) continue;;
    esac
    TMP+=("$p")
  done
  TARGETS=("${TMP[@]}")
fi

mapfile -t TARGETS < <(printf "%s\n" "${TARGETS[@]}" | awk 'NF' | sort -u)
readonly -a TARGETS

# ------------------------------ Role guards -----------------------------------
role_holders(){ adb shell "cmd role holders $1" 2>/dev/null | tr -d '\r' || true; }
SMS_ROLE="android.app.role.SMS"; DIALER_ROLE="android.app.role.DIALER"; readonly SMS_ROLE DIALER_ROLE
if printf "%s\n" "${TARGETS[@]}" | grep -qx "com.google.android.apps.messaging"; then
  if role_holders "$SMS_ROLE" | grep -q "com.google.android.apps.messaging"; then
    warn "Google Messages holds the SMS role; change default SMS before disabling."
  fi
fi

# ----------------------------- Confirm / Execute ------------------------------
[[ "$LIST_TARGETS" == "1" ]] && { printf "%s\n" "${TARGETS[@]}"; exit 0; }

if [[ "$NO_PROMPT" != "1" ]]; then
  echo "=============================================================================="
  echo " Device: $MODEL  Android $ANDROID_VER  OneUI ${ONEUI:-unknown}"
  echo " Mode=$MODE  WITH=${WITH_FLAGS:-<none>}  USER=$USER_ID  SAFE_MODE=$SAFE_MODE  DRY_RUN=$DRY_RUN"
  echo " CSC=$CSC (family=$CSC_FAMILY)  microG_present=$MICROG_PRESENT  targets=${#TARGETS[@]}"
  read -r -p "Type 'I UNDERSTAND' to proceed: " ACK; [[ "$ACK" == "I UNDERSTAND" ]] || { echo "Aborted."; exit 1; }
fi

for p in "${TARGETS[@]}"; do disable_pkg "$p" "bundle"; done

# Bonus: common partner bloat (reversible; only if present)
for p in com.facebook.katana com.facebook.appmanager com.facebook.services com.facebook.system; do
  disable_pkg "$p" "partner"
done

DIS="$(awk -F, '$3=="disable"&&$4=="ok"{c++}END{print c+0}' "$ACTIONS_CSV")"
SK="$(awk -F, '$4=="skip"{c++}END{print c+0}' "$ACTIONS_CSV")"
FA="$(awk -F, '$4=="fail"{c++}END{print c+0}' "$ACTIONS_CSV")"
DR="$(awk -F, '$4=="dry-run"{c++}END{print c+0}' "$ACTIONS_CSV")"

echo "=============================================================================="
echo " Re-enable helper: $REENABLE_SCRIPT"
echo " Actions CSV     : $ACTIONS_CSV"
echo " Result: disabled=$DIS skipped=$SK failed=$FA dry-run=$DR"
echo " Re-enable: adb shell pm enable --user $USER_ID <package>"
echo "=============================================================================="
