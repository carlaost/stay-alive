#!/usr/bin/env bash
#
# stay-alive installer
# ---------------------
# Adds two terminal commands to your shell:
#   stay alive  -> closing the lid keeps everything running, but LOCKS the screen
#   go sleep    -> Apple default (closing the lid sleeps + locks)
#   stay status -> show current mode
#
# Rename the commands with flags (each must be exactly TWO words):
#   ./install.sh --on "keep awake" --off "now rest"
#
# Other flags:
#   --rc <path>     shell rc file to edit            (default: ~/.zshrc)
#   --no-lock       skip setting screen-lock=immediate (not recommended)
#   --uninstall     remove everything this added
#   -h | --help     show this help
#
set -euo pipefail

ON_CMD="stay alive"
OFF_CMD="go sleep"
RC_FILE="$HOME/.zshrc"
SET_LOCK=1
UNINSTALL=0

SA_DIR="$HOME/.config/stayalive"
WATCHER="$SA_DIR/lidwatch.sh"
START_MARK="# >>> stay-alive (managed by install.sh — delete this block to remove) >>>"
END_MARK="# <<< stay-alive <<<"

usage() { sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; s/^#//'; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --on)        ON_CMD="${2:-}"; shift 2 ;;
    --off)       OFF_CMD="${2:-}"; shift 2 ;;
    --rc)        RC_FILE="${2:-}"; shift 2 ;;
    --no-lock)   SET_LOCK=0; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help)   usage ;;
    *) echo "unknown flag: $1 (try --help)"; exit 1 ;;
  esac
done

[[ "$(uname)" == "Darwin" ]] || { echo "error: macOS only (this uses pmset / ioreg)."; exit 1; }

# --- remove the managed block from the rc file (used by install + uninstall) ---
strip_block() {
  [[ -f "$RC_FILE" ]] || return 0
  grep -qF "$START_MARK" "$RC_FILE" || return 0
  awk -v s="$START_MARK" -v e="$END_MARK" '
    index($0,s){skip=1} !skip{print} index($0,e){skip=0}
  ' "$RC_FILE" > "$RC_FILE.satmp" && mv "$RC_FILE.satmp" "$RC_FILE"
}

if [[ $UNINSTALL -eq 1 ]]; then
  strip_block
  [[ -f "$SA_DIR/lidwatch.pid" ]] && kill "$(cat "$SA_DIR/lidwatch.pid")" 2>/dev/null || true
  rm -rf "$SA_DIR"
  sudo pmset -a disablesleep 0 || true
  echo "✅ Uninstalled. Open a new terminal (or 'source $RC_FILE') to drop the commands."
  exit 0
fi

# --- validate command names are exactly two words ---
check_two_words() {
  local label="$1" val="$2"
  val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"  # trim
  if [[ "$val" != *" "* || "${val#* }" == *" "* ]]; then
    echo "error: --$label must be exactly two words (e.g. 'stay alive'); got: '$2'"; exit 1
  fi
}
check_two_words on "$ON_CMD"
check_two_words off "$OFF_CMD"

ON_VERB="${ON_CMD%% *}";  ON_KEY="${ON_CMD#* }"
OFF_VERB="${OFF_CMD%% *}"; OFF_KEY="${OFF_CMD#* }"

# --- write the lid watcher ---
mkdir -p "$SA_DIR"
cat > "$WATCHER" <<'WATCHEOF'
#!/bin/bash
# Lid watcher for awake-on-close mode.
# While the Mac is kept awake (disablesleep=1), macOS won't auto-lock on lid
# close because there is no sleep event to trigger it. This watcher fills the
# gap: when the lid shuts it forces a display-sleep, which — with screen lock
# set to "immediate" — locks the screen while everything keeps running.
# It never sleeps the Mac; it only locks.
prev="open"
while true; do
  state=$(ioreg -r -k AppleClamshellState -d 4 | awk -F'= ' '/AppleClamshellState/{print $2; exit}')
  if [[ "$state" == "Yes" && "$prev" == "open" ]]; then
    pmset displaysleepnow   # lid just closed -> arm the immediate lock, stay awake
    prev="closed"
  elif [[ "$state" == "No" ]]; then
    prev="open"
  fi
  sleep 1
done
WATCHEOF
chmod +x "$WATCHER"

# --- build the shell block ---
gen_block() {
  cat <<EOF
$START_MARK
_SA_DIR="\$HOME/.config/stayalive"
_SA_PID="\$_SA_DIR/lidwatch.pid"
_sa_stop() { [[ -f "\$_SA_PID" ]] && kill "\$(cat "\$_SA_PID")" 2>/dev/null; rm -f "\$_SA_PID"; }
_sa_on() {
  sudo pmset -a disablesleep 1 || return 1
  _sa_stop
  nohup bash "\$_SA_DIR/lidwatch.sh" >/dev/null 2>&1 &
  echo \$! > "\$_SA_PID"; disown 2>/dev/null
  echo "☕️  ${ON_CMD} — lid close keeps everything running, locks the screen."
}
_sa_off() { _sa_stop; sudo pmset -a disablesleep 0 && echo "😴  ${OFF_CMD} — Apple default restored (lid close = sleep + lock)."; }
_sa_status() {
  if [[ "\$(pmset -g | awk '/SleepDisabled/{print \$2}')" == "1" ]]; then
    echo "☕️  awake-on-close ON — lid watcher: \$([[ -f \$_SA_PID ]] && kill -0 "\$(cat \$_SA_PID)" 2>/dev/null && echo running || echo STOPPED)"
  else
    echo "😴  default mode (lid close = sleep + lock)."
  fi
}
EOF
  if [[ "$ON_VERB" == "$OFF_VERB" ]]; then
    cat <<EOF
${ON_VERB}() {
  case "\$1" in
    ${ON_KEY}) _sa_on ;;
    ${OFF_KEY}) _sa_off ;;
    status|"") _sa_status ;;
    *) echo "usage: ${ON_VERB} [${ON_KEY}|${OFF_KEY}|status]" ;;
  esac
}
EOF
  else
    cat <<EOF
${ON_VERB}() {
  case "\$1" in
    ${ON_KEY}) _sa_on ;;
    status|"") _sa_status ;;
    *) echo "usage: ${ON_VERB} [${ON_KEY}|status]   (use '${OFF_CMD}' to restore default)" ;;
  esac
}
${OFF_VERB}() {
  case "\$1" in
    ${OFF_KEY}) _sa_off ;;
    *) echo "usage: ${OFF_CMD}" ;;
  esac
}
EOF
  fi
  echo "$END_MARK"
}

# --- splice block into rc (replace any previous one) ---
strip_block
printf '\n%s\n' "$(gen_block)" >> "$RC_FILE"

# --- set screen lock to immediate (needs your login password) ---
if [[ $SET_LOCK -eq 1 ]]; then
  if [[ "$(sysadminctl -screenLock status 2>&1)" != *"immediate"* ]]; then
    echo "→ Setting screen lock to 'immediate' (enter your LOGIN password when asked):"
    sysadminctl -screenLock immediate -password - || echo "  ⚠️  couldn't set it — do it in System Settings > Lock Screen, or rerun."
  fi
fi

echo
echo "✅ Installed to $RC_FILE"
echo "   ${ON_CMD}    -> stay awake on lid close + lock screen"
echo "   ${OFF_CMD}    -> Apple default (sleep + lock on lid close)"
echo "   ${ON_VERB} status -> show current mode"
echo
echo "Run this now (or open a new terminal):  source $RC_FILE"
