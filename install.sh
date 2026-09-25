#!/usr/bin/env bash
# Simple Stream installer
#
#   Edge device (client):   curl -fsSL https://raw.githubusercontent.com/haneeshbyreddy/simple_stream/main/install.sh | bash
#     with a display name:  curl -fsSL .../install.sh | bash -s -- client --name "Face detection"
#   Presenting laptop:      curl -fsSL .../install.sh | bash -s -- server
#   Remove it again:        curl -fsSL .../install.sh | bash -s -- uninstall
set -euo pipefail

RAW="${SS_RAW:-https://raw.githubusercontent.com/haneeshbyreddy/simple_stream/main}"
ROLE=client
NAME=""

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m ✔\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m ! %s\033[0m\n' "$*"; }
die() { printf '\033[1;31m ✘ %s\033[0m\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    client|server|uninstall) ROLE="$1" ;;
    --name) NAME="${2:-}"; shift ;;
    --name=*) NAME="${1#--name=}" ;;
    *) die "unknown option '$1' (use: client [--name NAME] | server | uninstall)" ;;
  esac
  shift
done

[ "$(uname -s)" = Linux ] || die "Simple Stream only supports Linux"
SUDO=""
[ "$(id -u)" -eq 0 ] || SUDO="sudo"

# Running from a git checkout? Then install the local files instead of downloading.
HERE=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "$(dirname "${BASH_SOURCE[0]}")/client.py" ]; then
  HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

fetch() {  # fetch <path in repo> <destination>
  if [ -n "$HERE" ]; then cp "$HERE/$1" "$2"; else curl -fsSL "$RAW/$1" -o "$2" || die "download failed: $RAW/$1"; fi
}

packages() {  # install distro packages by generic name: python3 venv ffmpeg xrandr
  local apt=() dnf=() pac=()
  for p in "$@"; do
    case "$p" in
      python3) apt+=(python3); dnf+=(python3); pac+=(python) ;;
      venv)    apt+=(python3-venv) ;;
      ffmpeg)  apt+=(ffmpeg); dnf+=(ffmpeg); pac+=(ffmpeg) ;;
      xrandr)  apt+=(x11-xserver-utils); dnf+=(xrandr); pac+=(xorg-xrandr) ;;
    esac
  done
  say "Installing packages: $*"
  if command -v apt-get >/dev/null; then
    [ ${#apt[@]} -eq 0 ] && return
    $SUDO apt-get update -qq </dev/null || warn "apt-get update had errors, trying anyway"
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${apt[@]}" </dev/null >/dev/null
  elif command -v dnf >/dev/null; then
    [ ${#dnf[@]} -eq 0 ] || $SUDO dnf install -y -q "${dnf[@]}" </dev/null
  elif command -v pacman >/dev/null; then
    [ ${#pac[@]} -eq 0 ] || $SUDO pacman -S --needed --noconfirm "${pac[@]}" </dev/null
  else
    die "please install these yourself: $*"
  fi
}

open_port() {  # open_port 47801/tcp  (only if a firewall is actually running)
  if command -v ufw >/dev/null && $SUDO ufw status 2>/dev/null | grep -q 'Status: active'; then
    $SUDO ufw allow "$1" >/dev/null && ok "firewall (ufw): allowed $1"
  fi
  if command -v firewall-cmd >/dev/null && $SUDO firewall-cmd --state >/dev/null 2>&1; then
    $SUDO firewall-cmd -q --permanent --add-port="$1" && $SUDO firewall-cmd -q --reload && ok "firewall (firewalld): allowed $1"
  fi
}

install_client() {
  say "Installing the Simple Stream client"
  local missing=()
  command -v python3 >/dev/null || missing+=(python3)
  command -v ffmpeg >/dev/null || missing+=(ffmpeg)
  command -v xrandr >/dev/null || missing+=(xrandr)
  [ ${#missing[@]} -eq 0 ] || packages "${missing[@]}"
  ffmpeg -hide_banner -encoders </dev/null 2>/dev/null | grep libx264 >/dev/null || warn "this ffmpeg has no libx264 encoder; only the Jetson hardware encoder will work"

  # the service must run as the desktop user so it can see the screen
  local user="${SUDO_USER:-$(id -un)}"
  if [ "$user" = root ]; then user="$(id -nu 1000 2>/dev/null || echo root)"; fi

  local tmp; tmp="$(mktemp -d)"
  fetch client.py "$tmp/client.py"
  $SUDO install -Dm755 "$tmp/client.py" /opt/simplestream/client.py

  NAME="${NAME//\"/}"
  if [ ! -f /etc/simplestream.conf ]; then
    cat > "$tmp/conf" <<EOF
# Simple Stream client settings.  Apply changes with:  sudo systemctl restart simplestream
SS_NAME="${NAME:-$(hostname)}"
# Frames per second:
#SS_FPS=30
# Bigger screens are scaled down to fit this size:
#SS_MAX_SIZE=1920x1080
# Maximum bitrate in kbit/s:
#SS_KBPS=8000
# Encoder: auto (Jetson hardware encoder if available, else ffmpeg/x264), jetson or x264:
#SS_ENCODER=auto
EOF
    $SUDO install -m644 "$tmp/conf" /etc/simplestream.conf
  elif [ -n "$NAME" ]; then  # re-install: keep the settings, just change the name
    { grep -v '^SS_NAME=' /etc/simplestream.conf || true; echo "SS_NAME=\"$NAME\""; } > "$tmp/conf"
    $SUDO install -m644 "$tmp/conf" /etc/simplestream.conf
  fi

  if [ ! -d /run/systemd/system ]; then
    ok "installed. No systemd here, so start it yourself:  python3 /opt/simplestream/client.py"
    return
  fi
  cat > "$tmp/unit" <<EOF
[Unit]
Description=Simple Stream client (shares this screen on the LAN)
After=network-online.target
Wants=network-online.target

[Service]
User=$user
EnvironmentFile=-/etc/simplestream.conf
ExecStart=$(command -v python3) -u /opt/simplestream/client.py
Restart=always
RestartSec=3
Nice=5

[Install]
WantedBy=multi-user.target
EOF
  $SUDO install -m644 "$tmp/unit" /etc/systemd/system/simplestream.service
  rm -rf "$tmp"
  $SUDO systemctl daemon-reload
  $SUDO systemctl enable simplestream >/dev/null 2>&1
  $SUDO systemctl restart simplestream
  open_port 47801/tcp
  sleep 2
  if systemctl is-active --quiet simplestream; then
    ok "client running as '$(grep '^SS_NAME=' /etc/simplestream.conf | cut -d= -f2- | tr -d '"')' (user $user) on $(hostname -I 2>/dev/null | awk '{print $1}')"
    echo "   It starts on boot. Rename: sudo nano /etc/simplestream.conf  ·  Logs: journalctl -u simplestream -f"
  else
    $SUDO journalctl -u simplestream -n 20 --no-pager || true
    die "the client did not start, see the log above"
  fi
}

install_server() {
  [ "$(id -u)" -ne 0 ] || die "install the server as your normal user (no sudo); it asks for your password when needed"
  say "Installing the Simple Stream server"
  command -v python3 >/dev/null || packages python3
  python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))' ||
    die "needs Python 3.10 or newer (Ubuntu 22.04+), found $(python3 --version)"

  local app="$HOME/.local/share/simplestream"
  mkdir -p "$app/app" "$HOME/.local/bin" "$HOME/.local/share/applications"
  if [ ! -x "$app/venv/bin/python" ]; then
    if ! python3 -m venv "$app/venv" >/dev/null 2>&1; then
      rm -rf "$app/venv"
      packages venv
      python3 -m venv "$app/venv" || die "could not create a Python virtual environment"
    fi
  fi
  say "Installing Python packages (Textual, PyAV, pygame-ce), this can take a minute"
  "$app/venv/bin/python" -m pip install -q --disable-pip-version-check --upgrade \
    'textual>=1.0' 'av>=12' 'pygame-ce>=2.4' || die "pip install failed"
  for f in tui.py discovery.py viewer.py; do fetch "server/$f" "$app/app/$f"; done

  cat > "$HOME/.local/bin/simplestream" <<EOF
#!/bin/sh
exec "$app/venv/bin/python" "$app/app/tui.py" "\$@"
EOF
  chmod +x "$HOME/.local/bin/simplestream"
  cat > "$HOME/.local/share/applications/simplestream.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Simple Stream
Comment=Show your edge devices' screens
Exec=$HOME/.local/bin/simplestream
Icon=video-display
Terminal=true
Categories=AudioVideo;Network;
EOF
  if ! command -v simplestream >/dev/null; then  # ~/.local/bin not on PATH yet
    $SUDO ln -sf "$HOME/.local/bin/simplestream" /usr/local/bin/simplestream || true
  fi
  open_port 47800/udp
  ok "server installed. Run:  simplestream   (or find 'Simple Stream' in your app menu)"
}

uninstall() {
  say "Removing Simple Stream"
  if [ -f /etc/systemd/system/simplestream.service ]; then
    $SUDO systemctl disable --now simplestream >/dev/null 2>&1 || true
    $SUDO rm -f /etc/systemd/system/simplestream.service
    $SUDO systemctl daemon-reload
  fi
  if [ -e /opt/simplestream ] || [ -e /etc/simplestream.conf ]; then
    $SUDO rm -rf /opt/simplestream /etc/simplestream.conf
  fi
  [ ! -L /usr/local/bin/simplestream ] || $SUDO rm -f /usr/local/bin/simplestream
  rm -rf "$HOME/.local/share/simplestream" "$HOME/.local/bin/simplestream" \
         "$HOME/.local/share/applications/simplestream.desktop"
  ok "removed (your device names in ~/.config/simplestream were kept)"
}

case "$ROLE" in
  client) install_client ;;
  server) install_server ;;
  uninstall) uninstall ;;
esac
