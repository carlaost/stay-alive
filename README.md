# stay-alive

Two terminal commands for macOS that let you **close your laptop lid without sleeping it** — while still locking the screen like normal.

```
stay alive   # close the lid → everything keeps running, screen locks
go sleep     # back to Apple default → close the lid → sleep + lock
stay status  # show which mode you're in
```

Useful when you want to shut the lid and walk away but keep things running — long jobs, downloads, or SSH-ing back into the machine from your phone.

## Why this isn't just one setting

macOS ties the **screen lock** to the **sleep** event: closing the lid locks your Mac *because* it sleeps. If you only disable lid-close sleep (`pmset disablesleep 1`), your Mac stays awake — but it **never locks**, because nothing triggers the lock. That's a security hole.

`stay alive` fixes that: it disables lid-close sleep **and** runs a tiny background watcher that locks the screen the instant the lid shuts. So you get "awake but locked," which macOS has no built-in switch for. `go sleep` turns it back off. The watcher is a **launchd agent**, so macOS keeps it supervised and restarts it across crashes, logout, and reboot — it can't silently die and leave you exposed.

> Locking ≠ sleeping. Locking leaves every process running at full speed; only *sleep* freezes them. So `stay alive` truly keeps your work going.

## Requirements

- **macOS** (Apple Silicon or Intel) — confirmed working on Apple Silicon (M4)
- **zsh** (the macOS default) or bash
- One `sudo` prompt per `stay alive` / `go sleep` (toggling the sleep setting needs admin)

## Install

```bash
git clone <this-repo> stay-alive && cd stay-alive
chmod +x install.sh
./install.sh
source ~/.zshrc        # or just open a new terminal
```

The installer:
1. drops a lid watcher in `~/.config/stayalive/`,
2. installs a launchd agent (`~/Library/LaunchAgents/com.stayalive.lidwatch.plist`) that keeps the watcher running and restarts it after reboot/logout,
3. adds the `stay` / `go` functions to your `~/.zshrc`,
4. sets your screen lock to **immediate** (asks for your login password — required so the lock actually fires on lid close).

Re-running the installer is safe — it replaces its own block cleanly.

## Rename the commands

Don't like `stay alive` / `go sleep`? Pass your own. **Each must be exactly two words.**

```bash
./install.sh --on "keep awake" --off "now rest"
./install.sh --on "stay up"    --off "stay down"   # same first word is fine too
```

| Flag | Default | Meaning |
|------|---------|---------|
| `--on "<two words>"`  | `stay alive` | command that keeps the Mac awake + locks on lid close |
| `--off "<two words>"` | `go sleep`   | command that restores Apple default |
| `--rc <path>`         | `~/.zshrc`   | shell file to edit (use `~/.bashrc` for bash) |
| `--no-lock`           | off          | skip setting screen-lock=immediate |
| `--uninstall`         | —            | remove everything this added |
| `-h`, `--help`        | —            | show help |

> `stay status` follows your `--on` verb — e.g. with `--on "keep awake"` it becomes `keep status`.

## Test it

```bash
stay alive          # confirm with: stay status  (watcher should say "running")
# close the lid for a minute, then reopen
```

You should have to **type your password** on reopen, and anything running should still be going. To prove nothing got interrupted, run a heartbeat before closing:

```bash
while true; do date '+%H:%M:%S'; sleep 2; done | tee /tmp/beat.log
# close lid, reopen, Ctrl-C — the timestamps should step cleanly with no gap
```

## Uninstall

```bash
./install.sh --uninstall
source ~/.zshrc
```

Removes the watcher, the launchd agent, the shell functions, and restores normal sleep. (It does not change your screen-lock-timing back; set that in **System Settings → Lock Screen** if you want.)

## Troubleshooting

**Reopened without a password prompt.** The lock didn't fire. Two checks:
- Confirm immediate lock: `sysadminctl -screenLock status` → should say `immediate`. Set it: `sysadminctl -screenLock immediate -password -`.
- Confirm the watcher is running: `stay status`.

If it still won't lock on your macOS build, swap the lock line in `~/.config/stayalive/lidwatch.sh` from:
```bash
pmset displaysleepnow
```
to the screensaver method (more forceful):
```bash
open -a /System/Library/CoreServices/ScreenSaverEngine.app
```

**It still sleeps when I close the lid.** If the Mac is **plugged in with an external display**, that's separate clamshell behavior. On battery with no peripherals, `stay alive` keeps it awake.

**Network drops while closed.** Expected — `stay alive` keeps *processes* running, but Wi-Fi power management and dropped SSH sessions are a separate matter. Long-lived remote sessions may still disconnect.

## How it works (under the hood)

- `lidwatch.sh` runs as a launchd agent (`RunAtLoad` + `KeepAlive`), so it's always running and macOS respawns it if it ever dies. It polls `ioreg -r -k AppleClamshellState` once a second; when the lid closes **and** sleep is disabled, it runs `pmset displaysleepnow`, which — with screen lock set to immediate — locks the screen without sleeping. In normal mode it sees sleep is enabled and does nothing.
- `stay alive` → `sudo pmset -a disablesleep 1` (no lid-close sleep). That's the only thing it flips; the watcher is already up and starts acting on lid close.
- `go sleep` → `sudo pmset -a disablesleep 0` (normal sleep restored). The watcher stays running but goes idle.

All it touches: a folder at `~/.config/stayalive/`, a launchd agent in `~/Library/LaunchAgents/`, and one marked block in your shell rc file.
