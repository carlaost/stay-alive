#!/usr/bin/env bash
#
# stay-alive installer
# ---------------------
# Adds two terminal commands to your shell:
#   stay alive  -> closing the lid keeps everything running, but LOCKS the screen
#   go sleep    -> Apple default (closing the lid sleeps + locks)
#   stay status -> show current mode
#
# The lid watcher runs as a launchd agent, so macOS keeps it supervised and
# restarts it across crashes, logout, and reboot — it never silently dies.
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
AGENT_LABEL="com.stayalive.lidwatch"
PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
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

[[ "$(uname)" == "Darwin" ]] || { echo "error: macOS only (this uses pmset / ioreg / launchctl)."; exit 1; }

# --- remove the managed block from the rc file (used by install + uninstall) ---
strip_block() {
  [[ -f "$RC_FILE" ]] || return 0
  grep -qF "$START_MARK" "$RC_FILE" || return 0
  awk -v s="$START_MARK" -v e="$END_MARK" '
    index($0,s){skip=1} !skip{print} index($0,e){skip=0}
  ' "$RC_FILE" > "$RC_FILE.satmp" && mv "$RC_FILE.satmp" "$RC_FILE"
}

# --- stop + remove the launchd agent (used by install reload + uninstall) ---
unload_agent() {
  launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null || true
}

if [[ $UNINSTALL -eq 1 ]]; then
  strip_block
  unload_agent
  rm -f "$PLIST"
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
# Lid watcher for "stay alive" (awake-on-lid-close) mode.
#
# Runs as a launchd agent (always supervised + restarted by macOS). It only ACTS
# when sleep is disabled (i.e. the "awake" mode is on): on lid close it forces a
# display sleep, which — with the screen lock set to "immediate" — locks the
# screen while the Mac keeps running. In normal mode it does nothing and macOS
# handles lid close itself. It never sleeps the Mac; it only locks the display.
prev="open"
while true; do
  state=$(ioreg -r -k AppleClamshellState -d 4 | awk -F'= ' '/AppleClamshellState/{print $2; exit}')
  if [[ "$state" == "Yes" && "$prev" == "open" ]]; then
    prev="closed"
    # Only lock when awake-mode is active; otherwise let macOS sleep normally.
    if [[ "$(pmset -g | awk '/SleepDisabled/{print $2}')" == "1" ]]; then
      pmset displaysleepnow   # lid just closed -> immediate lock, stay awake
    fi
  elif [[ "$state" == "No" ]]; then
    prev="open"
  fi
  sleep 1
done
WATCHEOF
chmod +x "$WATCHER"

# --- write the launchd agent that supervises the watcher ---
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$AGENT_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$WATCHER</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Background</string>
    <key>StandardErrorPath</key>
    <string>$SA_DIR/lidwatch.err.log</string>
</dict>
</plist>
EOF

# --- build the shell block ---
gen_block() {
  cat <<EOF
$START_MARK
# The lid watcher runs as a launchd agent ($AGENT_LABEL), always supervised by
# macOS. It only acts while sleep is disabled, so these commands just flip that.
_SA_AGENT="$AGENT_LABEL"
_sa_on()  { sudo pmset -a disablesleep 1 && echo "☕️  ${ON_CMD} — lid close keeps everything running, locks the screen."; }
_sa_off() { sudo pmset -a disablesleep 0 && echo "😴  ${OFF_CMD} — Apple default restored (lid close = sleep + lock)."; }
_sa_status() {
  if [[ "\$(pmset -g | awk '/SleepDisabled/{print \$2}')" == "1" ]]; then
    echo "☕️  awake-on-close ON — watcher: \$(launchctl print "gui/\$(id -u)/\$_SA_AGENT" >/dev/null 2>&1 && echo running || echo NOT running)"
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

# --- (re)load the launchd agent so the watcher runs now and after every reboot ---
unload_agent
launchctl bootstrap "gui/$(id -u)" "$PLIST" || \
  echo "  ⚠️  couldn't load the launchd agent — try: launchctl bootstrap gui/\$(id -u) $PLIST"

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
echo "   watcher       -> launchd agent '$AGENT_LABEL' (auto-starts at login)"
echo
echo "Run this now (or open a new terminal):  source $RC_FILE"
