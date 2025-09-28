#!/usr/bin/env bash
# AirStatus Runner — setup + doctor + pretty runtime

set -Eeuo pipefail
shopt -s lastpipe || true

# ===================== TTY / Colors / UI =====================
is_tty() { [[ -t 1 ]]; }
support_utf8() { locale charmap 2>/dev/null | grep -qi 'utf-8'; }

if command -v tput >/dev/null 2>&1 && is_tty; then
  BOLD=$(tput bold); DIM=$(tput dim); RESET=$(tput sgr0)
  RED=$(tput setaf 1); GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3)
  BLUE=$(tput setaf 4); MAGENTA=$(tput setaf 5); CYAN=$(tput setaf 6)
else
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
  BLUE=$'\033[34m'; MAGENTA=$'\033[35m'; CYAN=$'\033[36m'
fi

COLUMNS=${COLUMNS:-$( (tput cols 2>/dev/null) || echo 80 )}

hr() { printf "%s\n" "$(printf '─%.0s' $(seq 1 "$COLUMNS"))"; }
center() { local s="$*"; local n=${#s}; local pad=$(( (COLUMNS - n)/2 )); (( pad<0 ))&&pad=0; printf "%*s%s\n" "$pad" "" "$s"; }
hide_cursor() { is_tty && printf '\033[?25l'; }
show_cursor() { is_tty && printf '\033[?25h'; }
cleanup() { show_cursor; printf "\n${DIM}bye 👋${RESET}\n" || true; }
trap cleanup EXIT
trap 'exit 130' INT TERM

banner() {
  if support_utf8; then
    center "${CYAN}${BOLD}┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓${RESET}"
    center "${CYAN}${BOLD}┃${RESET}            ${BOLD}A I R S T A T U S   S C A N N E R${RESET}            ${CYAN}${BOLD}┃${RESET}"
    center "${CYAN}${BOLD}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛${RESET}"
    echo
    center "${DIM}Auto-setup • BlueZ doctor • Pretty live output${RESET}"
  else
    center "${BOLD}==============================================${RESET}"
    center "${BOLD}        AIRSTATUS SCANNER (ASCII MODE)        ${RESET}"
    center "${BOLD}==============================================${RESET}"
  fi
  echo
}

spinner_start() {
  hide_cursor
  if support_utf8; then SPIN_FRAMES=(⣾ ⣷ ⣯ ⣟ ⡿ ⢿ ⣻ ⣽); else SPIN_FRAMES=(- \\ \| /); fi
  (
    i=0
    while :; do
      f=${SPIN_FRAMES[$(( i % ${#SPIN_FRAMES[@]} ))]}
      printf "\r${DIM}%s${RESET} %s" "$f" "$*"
      i=$((i+1))
      sleep 0.12
    done
  ) &
  SPIN_PID=$!
}
spinner_stop() {
  if [[ -n "${SPIN_PID-}" ]]; then
    kill "$SPIN_PID" 2>/dev/null || true
    wait "$SPIN_PID" 2>/dev/null || true
    printf "\r\033[K"
    unset SPIN_PID
  fi
  show_cursor
}

badge() { local color="$1"; shift; printf "${color}[%s]${RESET}" "$*"; }
tick() { printf "${GREEN}✓${RESET}"; }
cross() { printf "${RED}✗${RESET}"; }

# ===================== Config (env overridable) =====================
: "${AIRSTATUS_MIN_RSSI:=-100}"
: "${AIRSTATUS_DEBUG:=1}"
: "${FORCE_VENV:=0}"         # set 1 to recreate .venv
: "${SETUP_ONLY:=0}"         # set 1 to only setup deps, no run

PY_REQS=("bleak>=0.22" "dbus-fast>=2.6")  # dbus-fast boosts Linux D-Bus perf

# ===================== Python / venv helpers =====================
need_cmd() { command -v "$1" >/dev/null 2>&1; }
py_ok() { "$PYBIN" - <<'PY' >/dev/null 2>&1 || exit 1
import sys; print(sys.version.split()[0])
PY
}
py_has() { local mod="$1"; "$PYBIN" - <<PY >/dev/null 2>&1
import importlib, sys; sys.exit(0 if importlib.util.find_spec("$mod") else 1)
PY
}

ensure_python() {
  if [[ -n "${VIRTUAL_ENV-}" ]]; then
    PYBIN="python3"
  elif [[ -x ".venv/bin/python" ]]; then
    PYBIN=".venv/bin/python"
  else
    PYBIN="python3"
  fi
  if ! need_cmd "$PYBIN"; then
    echo -e "$(cross) ${BOLD}Python3 not found.${RESET} Please install python3."
    exit 1
  fi
}

ensure_venv() {
  if [[ "$FORCE_VENV" == "1" && -d ".venv" ]]; then rm -rf .venv; fi
  if [[ ! -d ".venv" ]]; then
    echo -e "${DIM}Creating .venv…${RESET}"
    "$PYBIN" -m venv .venv
  fi
  # shellcheck disable=SC1091
  source ".venv/bin/activate"
  PYBIN="python"
  pip -q --version >/dev/null || true
  echo -e "${DIM}Upgrading pip/setuptools/wheel…${RESET}"
  python -m pip -q install --upgrade pip setuptools wheel || python -m pip install --upgrade pip setuptools wheel
}

ensure_py_deps() {
  local missing=()
  for req in "${PY_REQS[@]}"; do
    local mod="${req%%=*}"         # rough module guess
    [[ "$mod" == "dbus-fast" ]] && mod="dbus_fast"
    if ! py_has "$mod"; then missing+=("$req"); fi
  done
  if ((${#missing[@]})); then
    echo -e "${DIM}Installing Python deps: ${missing[*]}…${RESET}"
    spinner_start "Installing Python deps…"
    if ! python -m pip install -q "${missing[@]}"; then
      spinner_stop
      echo -e "$(cross) pip install (quiet) failed, retrying verbose…"
      python -m pip install "${missing[@]}"
    fi
    spinner_stop
  fi
  # Show versions
  echo -n " $(tick) Python deps: "
  "$PYBIN" - <<'PY'
import importlib, pkgutil
def v(p):
    try:
        m=importlib.import_module(p)
        return getattr(m,'__version__','?')
    except: return '?'
print(f"bleak={v('bleak')} dbus-fast={v('dbus_fast')}")
PY
}

# ===================== System Doctor (BlueZ) =====================
doctor() {
  echo
  hr
  center "${BOLD}System Doctor${RESET}"
  hr

  # bluetooth service
  if need_cmd systemctl; then
    if systemctl is-active --quiet bluetooth; then
      echo " $(tick) bluetooth service active"
    else
      echo " $(cross) bluetooth service inactive — try: ${BOLD}sudo systemctl start bluetooth${RESET}"
    fi
  fi

  # tools
  for tool in bluetoothctl btmgmt rfkill stdbuf; do
    if need_cmd "$tool"; then echo " $(tick) tool: $tool"; else echo " $(YELLOW)!${RESET} missing tool: $tool (optional)"; fi
  done

  # rfkill soft-block?
  if need_cmd rfkill; then
    if rfkill list bluetooth 2>/dev/null | grep -q "Soft blocked: yes"; then
      echo " $(cross) bluetooth is rfkill-blocked — run: ${BOLD}sudo rfkill unblock bluetooth${RESET}"
    fi
  fi

  # basic adapter info
  if need_cmd btmgmt; then
    if btmgmt info | grep -qi "current settings"; then
      echo " $(tick) btmgmt sees adapter"
    else
      echo " $(YELLOW)!${RESET} btmgmt couldn't read adapter — driver/permissions?"
    fi
  fi
  echo
}

# ===================== Pretty Output (from main.py) =====================
pct_color() { local v="${1:-0}"; if (( v>=60 )); then printf "%s" "$GREEN"; elif (( v>=30 )); then printf "%s" "$YELLOW"; else printf "%s" "$RED"; fi; }
fmt_pct() { local v="${1:--1}"; (( v<0 )) && { printf "—"; return; }; printf "%d%%" "$v"; }
fmt_tick() { [[ "$1" == "true" ]] && printf "${GREEN}✓${RESET}" || printf "${DIM}·${RESET}"; }

run_pretty() {
  local first=1
  local RUN=(env AIRSTATUS_MIN_RSSI="$AIRSTATUS_MIN_RSSI" AIRSTATUS_DEBUG="$AIRSTATUS_DEBUG" python -u main.py "$@")
  command -v stdbuf >/dev/null 2>&1 && RUN=(env AIRSTATUS_MIN_RSSI="$AIRSTATUS_MIN_RSSI" AIRSTATUS_DEBUG="$AIRSTATUS_DEBUG" stdbuf -oL -eL "${RUN[@]}")

  spinner_start "Starting LE scan…"
  while IFS= read -r line; do
    if (( first )); then
      spinner_stop
      echo "${DIM}Live data (Ctrl+C to exit)…${RESET}"
      echo
      first=0
    fi
    if [[ "$line" != *'"status"'* ]]; then
      printf "${DIM}%s${RESET}\n" "$line"
      continue
    fi

    # parse minimally (sed/grep)
    local status_ok=false
    [[ "$line" == *'"status": 1'* ]] && status_ok=true
    local model date_s left right casep
    model=$(sed -n 's/.*"model":"\([^"]*\)".*/\1/p' <<<"$line")
    date_s=$(sed -n 's/.*"date":"\([^"]*\)".*/\1/p' <<<"$line")
    left=$(sed -n 's/.*"left":\([0-9-]*\).*/\1/p' <<<"$line")
    right=$(sed -n 's/.*"right":\([0-9-]*\).*/\1/p' <<<"$line")
    casep=$(sed -n 's/.*"case":\([0-9-]*\).*/\1/p' <<<"$line")
    local ch_l ch_r ch_c
    ch_l=$(grep -q '"charging_left":true' <<<"$line" && echo true || echo false)
    ch_r=$(grep -q '"charging_right":true' <<<"$line" && echo true || echo false)
    ch_c=$(grep -q '"charging_case":true' <<<"$line" && echo true || echo false)

    local status_tag; $status_ok && status_tag="$(badge "$GREEN" "ONLINE")" || status_tag="$(badge "$RED" "OFFLINE")"

    local cL cR cC; cL=$(pct_color "${left:-0}"); cR=$(pct_color "${right:-0}"); cC=$(pct_color "${casep:-0}")

    printf "%s  %s  ${BOLD}${CYAN}%s${RESET}\n" \
      "${DIM}${date_s:-$(date +'%F %T')}${RESET}" \
      "$status_tag" \
      "${model:-unknown}"

    printf "   L:%s%s${RESET} %s   R:%s%s${RESET} %s   Case:%s%s${RESET} %s\n" \
      "$cL" "$(fmt_pct "$left")" "$(fmt_tick "$ch_l")" \
      "$cR" "$(fmt_pct "$right")" "$(fmt_tick "$ch_r")" \
      "$cC" "$(fmt_pct "$casep")" "$(fmt_tick "$ch_c")"

    if [[ "${AIRSTATUS_DEBUG}" == "1" ]]; then
      raw=$(sed -n 's/.*"raw":"\([^"]*\)".*/\1/p' <<<"$line" | head -c 64)
      [[ -n "$raw" ]] && printf "   ${DIM}raw:${RESET} %s…\n" "$raw"
    fi
    echo
  done < <("${RUN[@]}")
}

# ===================== Main =====================
clear
banner

echo " ${BOLD}Config${RESET}  $(badge "$BLUE" "RSSI ≥ ${AIRSTATUS_MIN_RSSI}")  $(badge "$MAGENTA" "DEBUG=${AIRSTATUS_DEBUG}")  $(badge "$CYAN" "Python: $(python3 -V 2>/dev/null || echo '?')")"
hr

ensure_python
ensure_venv
ensure_py_deps
doctor

if [[ "$SETUP_ONLY" == "1" ]]; then
  echo -e "\n$(tick) Setup complete. Run ${BOLD}./run.sh${RESET} to start scanning."
  exit 0
fi

run_pretty "$@"
