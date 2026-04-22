#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${HOME}/.local/bin"
CFG_DIR="${HOME}/.config/omarchy-prayer"
UNIT_DIR="${HOME}/.config/systemd/user"
LIB_DIR="${HOME}/.local/share/omarchy-prayer/lib"

msg()  { printf '\e[1;34m[omarchy-prayer]\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m[omarchy-prayer]\e[0m %s\n' "$*" >&2; }
err()  { printf '\e[1;31m[omarchy-prayer]\e[0m %s\n' "$*" >&2; exit 1; }

check_dep() {
  command -v "$1" >/dev/null 2>&1 || warn "missing: $1 — install with: $2"
}

msg "verifying runtime deps"
check_dep ruby        "pacman -S ruby"
check_dep notify-send "pacman -S libnotify"
check_dep makoctl     "pacman -S mako"
check_dep systemd-run "(part of systemd)"
check_dep waybar      "pacman -S waybar"
check_dep mpv         "pacman -S mpv"
check_dep curl        "pacman -S curl"

# Gem dependency
if ! ruby -e 'require "tomlrb"' 2>/dev/null; then
  msg "installing tomlrb gem"
  gem install --user-install tomlrb >/dev/null
fi

msg "installing lib → $LIB_DIR"
mkdir -p "$BIN_DIR" "$UNIT_DIR" "$LIB_DIR"
rm -rf "$LIB_DIR/omarchy_prayer"
cp -R "$PROJECT_DIR/lib/omarchy_prayer" "$LIB_DIR/"

msg "installing bin → $BIN_DIR"
for bin in omarchy-prayer omarchy-prayer-schedule omarchy-prayer-notify \
           omarchy-prayer-waybar omarchy-prayer-stop; do
  src="$PROJECT_DIR/bin/$bin"
  dst="$BIN_DIR/$bin"
  # Rewrite the LOAD_PATH unshift line so the installed script finds the installed lib.
  sed "s|\$LOAD_PATH.unshift File.expand_path('../lib', __dir__)|\$LOAD_PATH.unshift '${LIB_DIR}'|" \
      "$src" > "$dst"
  chmod +x "$dst"
done

msg "installing systemd units → $UNIT_DIR"
cp "$PROJECT_DIR/share/systemd/"*.service "$UNIT_DIR/"
cp "$PROJECT_DIR/share/systemd/"*.timer   "$UNIT_DIR/"

msg "reloading systemd user daemon"
systemctl --user daemon-reload
systemctl --user enable --now omarchy-prayer-schedule.timer
systemctl --user enable omarchy-prayer-resume.service || warn "resume service enable failed (non-critical)"

msg "seeding config dir"
mkdir -p "$CFG_DIR"
for f in adhan.mp3 adhan-fajr.mp3; do
  if [ ! -f "$CFG_DIR/$f" ]; then
    warn "no $f at $CFG_DIR/$f — drop one in, or adhan will only log a warning"
  fi
done

msg "running initial schedule"
if ! "$BIN_DIR/omarchy-prayer-schedule"; then
  warn "initial schedule failed — fix issues above and run 'omarchy-prayer refresh' after"
fi

cat <<EOF

next steps:

  1. add to ~/.config/waybar/config:

     "custom/prayer": {
       "exec": "omarchy-prayer-waybar",
       "interval": 30,
       "return-type": "json",
       "on-click": "alacritty -e omarchy-prayer tui",
       "tooltip": true
     }

     and add "custom/prayer" to your modules-right array.

  2. (optional) add to ~/.config/hypr/bindings.conf:

     bind = SUPER CTRL, M, exec, omarchy-prayer-stop

  3. drop your adhan MP3s at $CFG_DIR/adhan.mp3 and adhan-fajr.mp3

  4. inspect today's schedule:  systemctl --user list-timers | grep op-

EOF
