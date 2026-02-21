#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Logging helpers
# IMPORTANT: log to stderr so $(...) captures only real return values (stdout).
# -----------------------------
say()  { printf "\n✅ %s\n" "$*" >&2; }
info() { printf "   ℹ️  %s\n" "$*" >&2; }
warn() { printf "\n⚠️  %s\n" "$*" >&2; }
die()  { printf "\n❌ %s\n\n" "$*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1; }

# Always ask questions via the real terminal, so prompts never "disappear"
tty_prompt() {
  local prompt="$1"
  local __varname="$2"
  local ans=""

  if [[ -r /dev/tty && -w /dev/tty ]]; then
    printf "%s" "$prompt" > /dev/tty
    IFS= read -r ans < /dev/tty || ans=""
  else
    printf "%s" "$prompt" >&2
    IFS= read -r ans || ans=""
  fi

  # shellcheck disable=SC2163
  printf -v "$__varname" "%s" "$ans"
}

# Strip CR/LF + trim leading/trailing whitespace
strip_ws() {
  local s="${1-}"
  s="${s//$'\r'/}"
  s="${s//$'\n'/}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf "%s" "$s"
}

# -----------------------------
# Settings
# -----------------------------
PORT="/dev/ttyACM0"
BASE_DIR="${HOME}/Code/meshtastic"
VENV_DIR="${BASE_DIR}/venv"
TARGET_FULL_VOLTAGE="4.2"

# -----------------------------
# Cleanup: deactivate venv if active
# -----------------------------
cleanup() {
  if declare -F deactivate >/dev/null 2>&1; then
    if [[ -n "${VIRTUAL_ENV:-}" ]]; then
      info "Cleaning up: deactivating venv..."
      deactivate || true
    fi
  fi
}
trap cleanup EXIT

ensure_interactive() {
  [[ -t 0 && -t 1 ]] || die "This script needs an interactive Terminal. Run: bash ./meshtastic_charge_level_fix.sh"
}

apt_install_python() {
  if ! need_cmd apt-get; then
    die "Auto-install supported only on Debian/Ubuntu (apt-get). Install: python3 python3-pip python3-venv"
  fi

  local need_install=0
  if ! need_cmd python3; then need_install=1; fi
  if ! need_cmd pip3; then need_install=1; fi

  if need_cmd python3; then
    if ! python3 - <<'PY' >/dev/null 2>&1
import venv
PY
    then
      need_install=1
    fi
  fi

  if [[ "$need_install" -eq 0 ]]; then
    info "python3, pip3, and venv support detected."
    return
  fi

  say "Installing python3 + python3-pip + python3-venv via apt..."
  if need_cmd sudo; then
    sudo apt-get update
    sudo apt-get install -y python3 python3-pip python3-venv
  else
    apt-get update
    apt-get install -y python3 python3-pip python3-venv
  fi

  need_cmd python3 || die "python3 still not found after install."
  need_cmd pip3    || die "pip3 still not found after install."
}

ensure_folder_and_venv() {
  say "Step 1) Ensuring folder exists: ${BASE_DIR}"
  mkdir -p "${BASE_DIR}"
  cd "${BASE_DIR}"

  say "Step 2) Ensuring venv exists: ${VENV_DIR}"
  if [[ ! -d "${VENV_DIR}" ]]; then
    info "Creating venv..."
    python3 -m venv "${VENV_DIR}"
  else
    info "Venv already exists."
  fi

  say "Step 3) Activating venv"
  # shellcheck disable=SC1090
  source "${VENV_DIR}/bin/activate"
  info "Using python: $(command -v python)"
  info "Using pip:    $(command -v pip)"

  info "Upgrading pip inside the venv..."
  python -m pip install --upgrade pip >/dev/null
}

wait_for_device() {
  say "Step 5) Checking for Meshtastic device at ${PORT}"

  while [[ ! -e "${PORT}" ]]; do
    warn "${PORT} not found."
    printf "🔌 Please connect your Meshtastic device so it appears as %s.\n" "${PORT}" >&2
    local ans=""
    tty_prompt "Press Enter to re-check, or type 'q' then Enter to quit: " ans
    ans="$(strip_ws "${ans}")"
    if [[ "${ans:-}" == "q" || "${ans:-}" == "Q" ]]; then
      die "Exiting — no device detected."
    fi
  done

  info "Found ${PORT}."

  if [[ ! -r "${PORT}" || ! -w "${PORT}" ]]; then
    warn "No read/write permission on ${PORT}."
    info "Try: sudo usermod -aG dialout \"$USER\"  (then log out/in), or run this script with sudo."
    info "Current perms:"
    ls -l "${PORT}" >&2 || true
    die "Fix permissions and rerun."
  fi
}

install_meshtastic() {
  say "Step 6) Installing Meshtastic into the active venv"
  pip install --upgrade meshtastic >&2

  say "Step 7) Connecting to the device (sanity check via --info)"
  if need_cmd timeout; then
    timeout 10s meshtastic --port "${PORT}" --info >/dev/null
  else
    meshtastic --port "${PORT}" --info >/dev/null
  fi
  info "Connected successfully."
}

ask_full_charge_and_voltage() {
  say "Step 8) Battery check (the script will pause for your answers)"

  local charged=""
  tty_prompt "Is the device currently charged to 100%? (y/N): " charged
  charged="$(strip_ws "${charged}")"

  if [[ "${charged}" != "y" && "${charged}" != "Y" ]]; then
    die "Charge it fully first, then rerun (calibration assumes full is ~${TARGET_FULL_VOLTAGE}V)."
  fi

  local displayed_v=""
  tty_prompt "Great. What voltage is the device currently DISPLAYING at 100%? (example: 4.05): " displayed_v
  displayed_v="$(strip_ws "${displayed_v}")"

  python3 - "${displayed_v}" <<'PY' >/dev/null 2>&1 || die "That voltage doesn't look valid. Please enter something like 4.05"
import sys
v=float(sys.argv[1])
assert 2.5 < v < 5.0
PY

  # Return value ONLY (stdout)
  printf "%s" "${displayed_v}"
}

get_current_multiplier() {
  say "Step 9) Reading current multiplier override"

  local out=""
  out="$(meshtastic --port "${PORT}" --get power.adc_multiplier_override 2>&1 || true)"

  info "CLI output:"
  printf "%s\n" "$out" | sed 's/^/   │ /' >&2

  local val=""
  val="$(printf "%s\n" "$out" | grep -Eo '[0-9]+(\.[0-9]+)?' | tail -n 1 || true)"
  val="$(strip_ws "${val}")"
  [[ -n "${val}" ]] || die "Couldn’t parse multiplier value from meshtastic output."

  python3 - "${val}" <<'PY' >/dev/null 2>&1 || die "Parsed multiplier is not numeric: ${val}"
import sys
x=float(sys.argv[1])
assert x >= 0.0
PY

  # If override is 0, firmware default is used; ask for baseline.
  if python3 - "${val}" <<'PY' >/dev/null 2>&1; then
import sys
x=float(sys.argv[1])
assert x != 0.0
PY
    printf "%s" "${val}"
    return
  fi

  warn "Override is 0 (firmware default in use)."
  info "To calibrate, I need the current EFFECTIVE multiplier you want to calibrate from."
  local manual=""
  tty_prompt "Please type the current effective multiplier (example: 3.20): " manual
  manual="$(strip_ws "${manual}")"

  python3 - "${manual}" <<'PY' >/dev/null 2>&1 || die "That multiplier doesn't look valid."
import sys
x=float(sys.argv[1])
assert x > 0.0
PY

  printf "%s" "${manual}"
}

calc_new_multiplier() {
  local current_mult displayed_v target_v
  current_mult="$(strip_ws "${1-}")"
  displayed_v="$(strip_ws "${2-}")"
  target_v="$(strip_ws "${3-}")"

  [[ -n "${current_mult}" ]] || die "Internal error: current_mult is empty."
  [[ -n "${displayed_v}"  ]] || die "Internal error: displayed_v is empty."
  [[ -n "${target_v}"     ]] || die "Internal error: target_v is empty."

  python3 - "${current_mult}" "${displayed_v}" "${target_v}" <<'PY'
import sys
current=float(sys.argv[1])
displayed=float(sys.argv[2])
target=float(sys.argv[3])
new = current * (target / displayed)
print(f"{new:.4f}")
PY
}

maybe_warn_range() {
  local new_mult
  new_mult="$(strip_ws "${1-}")"

  python3 - "${new_mult}" <<'PY' >/dev/null 2>&1 || die "Calculated multiplier is not numeric: ${new_mult}"
import sys
float(sys.argv[1])
PY

  if python3 - "${new_mult}" <<'PY' >/dev/null 2>&1; then
import sys
x=float(sys.argv[1])
assert 2.0 <= x <= 6.0
PY
    return
  fi

  warn "Calculated multiplier ${new_mult} is outside the recommended 2–6 range."
  local ok=""
  tty_prompt "Proceed anyway? (y/N): " ok
  ok="$(strip_ws "${ok}")"
  [[ "${ok}" == "y" || "${ok}" == "Y" ]] || die "Cancelled — not applying changes."
}

apply_and_reboot_then_deactivate() {
  local new_mult
  new_mult="$(strip_ws "${1-}")"

  say "Step 11) Setting new multiplier: ${new_mult}"
  meshtastic --port "${PORT}" --set power.adc_multiplier_override "${new_mult}" >/dev/null

  say "Step 12) Rebooting the node"
  meshtastic --port "${PORT}" --reboot >/dev/null

  # Deactivate venv immediately after reboot command is issued
  if declare -F deactivate >/dev/null 2>&1; then
    info "Deactivating venv right after issuing reboot (as requested)..."
    deactivate || true
  else
    warn "Couldn't find 'deactivate' function (venv may not be active?), skipping."
  fi

  say "Done!"
  info "After reboot, confirm full-charge voltage display is closer to ${TARGET_FULL_VOLTAGE}V."
}

main() {
  ensure_interactive

  say "Meshtastic ADC Multiplier Calibrator"
  info "Goal: at 100% charge, battery should read ~${TARGET_FULL_VOLTAGE}V."

  apt_install_python
  ensure_folder_and_venv
  wait_for_device
  install_meshtastic

  local displayed_v current_mult new_mult
  displayed_v="$(ask_full_charge_and_voltage)"
  current_mult="$(get_current_multiplier)"
  info "Using current multiplier baseline: ${current_mult}"

  say "Step 10) Calculating corrected multiplier"
  new_mult="$(calc_new_multiplier "${current_mult}" "${displayed_v}" "${TARGET_FULL_VOLTAGE}")"
  info "Formula: new = current × (${TARGET_FULL_VOLTAGE} / displayed_at_full)"
  info "Calculated new multiplier: ${new_mult}"

  maybe_warn_range "${new_mult}"
  apply_and_reboot_then_deactivate "${new_mult}"
}

main "$@"
