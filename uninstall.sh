#!/usr/bin/env bash
set -euo pipefail

# Mirror of install.sh: removes everything install.sh dropped on the system.
# Default behaviour matches the AUR package's uninstall hook — preserves
# config, cached times, and downloaded adhans. Pass --purge to wipe those too.

BIN_DIR="${HOME}/.local/bin"
CFG_DIR="${HOME}/.config/omarchy-prayer"
STATE_DIR="${HOME}/.local/state/omarchy-prayer"
SHARE_DIR="${HOME}/.local/share/omarchy-prayer"
LIB_DIR="${SHARE_DIR}/lib"
ADHAN_DIR="${SHARE_DIR}/adhans"
UNIT_DIR="${HOME}/.config/systemd/user"
WAYBAR_DIR="${HOME}/.config/waybar"
NM_DISPATCHER=/etc/NetworkManager/dispatcher.d/90-omarchy-prayer

PURGE=0
RESTORE_WAYBAR=0
for arg in "$@"; do
  case "$arg" in
    --purge) PURGE=1 ;;
    --restore-waybar) RESTORE_WAYBAR=1 ;;
    -h|--help)
      cat <<EOF
usage: uninstall.sh [--purge] [--restore-waybar]

Removes omarchy-prayer files installed by install.sh. By default,
preserves user data (config, cached times, downloaded adhans), matching
the AUR package's uninstall behaviour.

  --purge            Also remove ~/.config/omarchy-prayer,
                     ~/.local/state/omarchy-prayer, and the adhans dir
                     (full wipe — irreversible)
  --restore-waybar   Restore the original waybar config from the OLDEST
                     omarchy-prayer backup (the one taken before any patch)
EOF
      exit 0
      ;;
    *) printf 'unknown flag: %s (use --help)\n' "$arg" >&2; exit 1 ;;
  esac
done

msg()  { printf '\e[1;34m[omarchy-prayer]\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m[omarchy-prayer]\e[0m %s\n' "$*" >&2; }

# 1. Stop a currently-playing adhan if there's a tracked PID.
if [ -f "$STATE_DIR/current-adhan.pid" ]; then
  pid=$(cat "$STATE_DIR/current-adhan.pid" 2>/dev/null || true)
  if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
    msg "stopping currently-playing adhan (pid $pid)"
    kill "$pid" 2>/dev/null || true
  fi
fi

# 2. Stop + disable our user systemd units.
msg "stopping + disabling user systemd units"
for unit in omarchy-prayer-schedule.timer \
            omarchy-prayer-schedule.service \
            omarchy-prayer-resume.service; do
  systemctl --user stop "$unit" >/dev/null 2>&1 || true
done
systemctl --user disable omarchy-prayer-schedule.timer \
                         omarchy-prayer-resume.service >/dev/null 2>&1 || true

# 3. Stop transient per-prayer timers (op-*) created by systemd-run.
op_units=$(systemctl --user list-units --no-legend 'op-*.timer' 'op-*.service' 2>/dev/null \
            | awk '{print $1}' || true)
if [ -n "$op_units" ]; then
  msg "stopping transient prayer timers"
  echo "$op_units" | xargs -r systemctl --user stop >/dev/null 2>&1 || true
fi

# 4. Remove unit files.
for f in omarchy-prayer-schedule.service \
         omarchy-prayer-schedule.timer \
         omarchy-prayer-resume.service; do
  if [ -f "$UNIT_DIR/$f" ]; then
    msg "removing $UNIT_DIR/$f"
    rm -f "$UNIT_DIR/$f"
  fi
done
systemctl --user daemon-reload >/dev/null 2>&1 || true

# 5. Remove binaries from ~/.local/bin.
for bin in omarchy-prayer omarchy-prayer-schedule omarchy-prayer-notify \
           omarchy-prayer-waybar omarchy-prayer-stop; do
  if [ -f "$BIN_DIR/$bin" ] || [ -L "$BIN_DIR/$bin" ]; then
    msg "removing $BIN_DIR/$bin"
    rm -f "$BIN_DIR/$bin"
  fi
done

# 6. Remove the lib dir.
if [ -d "$LIB_DIR" ]; then
  msg "removing $LIB_DIR"
  rm -rf "$LIB_DIR"
fi

# 7. Remove the NM dispatcher (needs sudo).
if [ -f "$NM_DISPATCHER" ]; then
  msg "removing NetworkManager dispatcher (sudo) → $NM_DISPATCHER"
  if ! sudo rm -f "$NM_DISPATCHER"; then
    warn "could not remove NM dispatcher — remove manually: sudo rm $NM_DISPATCHER"
  fi
fi

# 8. Restore waybar (opt-in) or hint at the backup location.
restore_waybar() {
  local target="$1"
  [ -f "$target" ] || return
  # Pick the OLDEST backup (= original, before any omarchy-prayer patch).
  local oldest
  oldest=$(ls -1 "${target}".bak.omarchy-prayer-* 2>/dev/null | sort | head -n1 || true)
  if [ -n "$oldest" ]; then
    msg "restoring $target ← $oldest"
    cp "$oldest" "$target"
    pkill -SIGUSR2 waybar >/dev/null 2>&1 || true
  fi
}

if [ "$RESTORE_WAYBAR" -eq 1 ]; then
  for cfg in config.jsonc config; do
    restore_waybar "$WAYBAR_DIR/$cfg"
  done
elif compgen -G "$WAYBAR_DIR/config*.bak.omarchy-prayer-*" >/dev/null; then
  warn "waybar backup(s) found — the custom/prayer widget is still in your waybar config"
  warn "  restore the original automatically: ./uninstall.sh --restore-waybar"
  warn "  or pick a backup manually:"
  for f in "$WAYBAR_DIR"/config*.bak.omarchy-prayer-*; do
    warn "    $f"
  done
fi

# 9. Optional purge of user data.
if [ "$PURGE" -eq 1 ]; then
  for d in "$CFG_DIR" "$STATE_DIR" "$ADHAN_DIR"; do
    if [ -d "$d" ]; then
      msg "purging $d"
      rm -rf "$d"
    fi
  done
fi

# 10. Clean up empty parent dirs we own.
if [ -d "$SHARE_DIR" ] && [ -z "$(ls -A "$SHARE_DIR")" ]; then
  rmdir "$SHARE_DIR"
fi

# 11. Final summary.
if [ "$PURGE" -eq 1 ]; then
  msg "uninstall complete (full wipe)"
else
  msg "uninstall complete; user data preserved at:"
  for d in "$CFG_DIR" "$STATE_DIR" "$ADHAN_DIR"; do
    [ -d "$d" ] && echo "    $d"
  done
  cat <<EOF

ready to reinstall from AUR:
    yay -S omarchy-prayer        # or: paru -S omarchy-prayer

(your config + state + adhans will be picked up automatically)
EOF
fi
