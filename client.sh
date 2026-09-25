#!/usr/bin/env bash
# Simple Stream client: share this device's screen with the presenting laptop.
#
#   curl -fsSL https://raw.githubusercontent.com/haneeshbyreddy/simple_stream/main/client.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/haneeshbyreddy/simple_stream/main/client.sh | bash -s -- --name "Face detection"
#
# Installs the `simplestream-client` command and a service that starts on boot.
# Run `simplestream-client help` afterwards.
set -euo pipefail

NAME=""
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="${2:-}"; shift ;;
    --name=*) NAME="${1#--name=}" ;;
    *) echo "usage: client.sh [--name \"Display name\"]" >&2; exit 2 ;;
  esac
  shift
done

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m ✔\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m ! %s\033[0m\n' "$*"; }
die() { printf '\033[1;31m ✘ %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Linux ] || die "Simple Stream only supports Linux"
SUDO=""
[ "$(id -u)" -eq 0 ] || SUDO="sudo"
BIN=/usr/local/bin/simplestream-client
CONF=/etc/simplestream.conf

say "Installing the Simple Stream client"
missing=()
command -v python3 >/dev/null || missing+=(python3)
command -v ffmpeg >/dev/null || missing+=(ffmpeg)
command -v xrandr >/dev/null || missing+=(xrandr)
if [ ${#missing[@]} -gt 0 ]; then
  say "Installing packages: ${missing[*]}"
  if command -v apt-get >/dev/null; then
    pkgs=("${missing[@]/xrandr/x11-xserver-utils}")
    $SUDO apt-get update -qq </dev/null || warn "apt-get update had errors, trying anyway"
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}" </dev/null >/dev/null
  elif command -v dnf >/dev/null; then
    $SUDO dnf install -y -q "${missing[@]}" </dev/null
  elif command -v pacman >/dev/null; then
    pkgs=("${missing[@]/xrandr/xorg-xrandr}")
    $SUDO pacman -S --needed --noconfirm "${pkgs[@]/python3/python}" </dev/null
  else
    die "please install these yourself: ${missing[*]}"
  fi
fi
ffmpeg -hide_banner -encoders </dev/null 2>/dev/null | grep libx264 >/dev/null ||
  warn "this ffmpeg has no libx264 encoder; only the Jetson hardware encoder will work"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# ---------------------------------------------------------------------------------------
# The program itself (Python 3.6+, standard library only)
# ---------------------------------------------------------------------------------------
cat > "$tmp/simplestream-client" <<'PYTHON'
#!/usr/bin/env python3
"""Simple Stream client: makes this device's screen available on the LAN.

Idle it only sends a tiny "I'm here" UDP beacon every 2 s (multicast + broadcast,
like LocalSend).  Screen capture runs only while the presenter is connected to
http://<device>:47801/stream (raw H.264).  /info returns the beacon JSON.
"""
import fcntl
import glob
import json
import os
import re
import select
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn

USAGE = """Simple Stream client - shares this screen with the presenting laptop.

usage: simplestream-client [command]

  status            show name, address and state (default)
  name "NEW NAME"   change the name the audience sees
  start|stop|restart  control the background service
  logs              follow the log
  run               run in the foreground (what the service does)
  uninstall         remove Simple Stream from this device

Settings live in /etc/simplestream.conf (SS_NAME, SS_FPS, SS_MAX_SIZE, SS_KBPS, SS_ENCODER)."""

CONF_FILE = '/etc/simplestream.conf'
SERVICE = 'simplestream'
GROUP, DISCOVERY_PORT = '224.0.0.177', 47800
DEVNULL = subprocess.DEVNULL


def read(path):
    try:
        with open(path) as f:
            return f.read().strip('\0 \n')
    except OSError:
        return ''


def load_conf():
    conf = {}
    for line in read(CONF_FILE).splitlines():
        if '=' in line and not line.lstrip().startswith('#'):
            key, value = line.split('=', 1)
            conf[key.strip()] = value.strip().strip('"\'')
    return conf


CONF = load_conf()


def setting(key, default):
    return os.environ.get(key) or CONF.get(key) or default


PORT = int(setting('SS_PORT', 47801))
NAME = setting('SS_NAME', socket.gethostname())
FPS = int(setting('SS_FPS', 30))
MAX_W, MAX_H = map(int, setting('SS_MAX_SIZE', '1920x1080').split('x'))
KBPS = int(setting('SS_KBPS', 8000))
ENCODER = setting('SS_ENCODER', 'auto')  # auto | jetson | x264
MAX_VIEWERS = 3
ENCODERS, FPS_MODE = [], []  # filled in by serve()


def log(*args):
    print(*args, file=sys.stderr, flush=True)


def device_id():
    """Stable id: MAC of the first physical network card."""
    for nic in sorted(glob.glob('/sys/class/net/*/device')):
        mac = read(os.path.dirname(nic) + '/address').replace(':', '')
        if mac.strip('0'):
            return mac
    return read('/etc/machine-id')[:12] or '%012x' % uuid.getnode()


ID = device_id() + ('' if PORT == 47801 else '-%d' % PORT)  # a 2nd client on another port is another device
HOST = socket.gethostname()
MODEL = read('/proc/device-tree/model') or read('/sys/class/dmi/id/product_name')
lock = threading.Lock()
viewers = 0


def interfaces():
    """[(ip, broadcast)] of every IPv4 interface that is up, loopback excluded."""
    out, s = [], socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    for _, name in socket.if_nameindex():
        req = struct.pack('256s', name[:15].encode())
        try:
            flags = struct.unpack('H', fcntl.ioctl(s, 0x8913, req)[16:18])[0]  # SIOCGIFFLAGS
            ip = fcntl.ioctl(s, 0x8915, req)[20:24]                           # SIOCGIFADDR
            mask = fcntl.ioctl(s, 0x891b, req)[20:24]                         # SIOCGIFNETMASK
        except OSError:
            continue
        if flags & 1 and not flags & 8:  # IFF_UP and not IFF_LOOPBACK
            bcast = bytes(a | (~m & 255) for a, m in zip(ip, mask))
            out.append((socket.inet_ntoa(ip), socket.inet_ntoa(bcast)))
    s.close()
    return out


_session = [0, None]


def x_session():
    """Environment for talking to this user's X desktop, or None if nobody is logged in.

    As a service we have no DISPLAY, so borrow DISPLAY/XAUTHORITY from one of our
    own processes that runs inside the desktop session (cached for 5 s).
    """
    if os.environ.get('DISPLAY'):
        return dict(os.environ)
    if time.time() - _session[0] < 5:
        return _session[1]
    found, uid = None, os.getuid()
    for path in glob.glob('/proc/[0-9]*/environ'):
        try:
            if uid and os.stat(path).st_uid != uid:  # (root may borrow anybody's session)
                continue
            with open(path, 'rb') as f:
                env = dict(v.split('=', 1) for v in f.read().decode('utf-8', 'replace').split('\0') if '=' in v)
        except OSError:
            continue
        if env.get('DISPLAY', '').startswith(':'):
            found = env
            if env.get('XAUTHORITY'):
                break
    if found is None and os.path.exists('/tmp/.X11-unix/X0'):
        found = {'DISPLAY': ':0', 'XAUTHORITY': os.path.expanduser('~/.Xauthority')}
    result = None
    if found:
        result = dict(os.environ, DISPLAY=found['DISPLAY'])
        for key in ('XAUTHORITY', 'XDG_SESSION_TYPE', 'WAYLAND_DISPLAY'):
            if found.get(key):
                result[key] = found[key]
    _session[:] = [time.time(), result]
    return result


def screen_size(env):
    try:
        out = subprocess.check_output(['xrandr', '--current'], env=env, stderr=DEVNULL, timeout=5)
        m = re.search(r'current (\d+) x (\d+)', out.decode())
        return int(m.group(1)), int(m.group(2))
    except Exception:
        return None


def fit(size):
    """Scale down to at most MAX_W x MAX_H, keeping even dimensions for H.264."""
    w, h = size
    s = min(1.0, MAX_W / w, MAX_H / h)
    return int(w * s) // 2 * 2, int(h * s) // 2 * 2


def ffmpeg_cmd(env, size):
    cmd = ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-nostdin',
           '-f', 'x11grab', '-draw_mouse', '1', '-framerate', str(FPS)]
    if size:
        cmd += ['-video_size', '%dx%d' % size]
    cmd += ['-i', env['DISPLAY'], '-vf', 'scale=%d:%d' % fit(size) if size else 'scale=trunc(iw/2)*2:trunc(ih/2)*2',
            '-c:v', 'libx264', '-preset', 'ultrafast', '-tune', 'zerolatency', '-pix_fmt', 'yuv420p',
            '-g', str(FPS * 2), '-crf', '23', '-maxrate', '%dk' % KBPS, '-bufsize', '%dk' % (KBPS // 2)]
    # vfr: never duplicate frames when the CPU can't keep up (that only makes it slower)
    return cmd + FPS_MODE + ['-flush_packets', '1', '-f', 'h264', '-']


def jetson_cmd(env, size):
    caps = 'video/x-raw(memory:NVMM),format=NV12'
    if size:
        caps += ',width=%d,height=%d' % fit(size)
    return ['gst-launch-1.0', '-q', 'ximagesrc', 'use-damage=false', '!', 'video/x-raw,framerate=%d/1' % FPS,
            '!', 'nvvidconv', '!', caps, '!', 'nvv4l2h264enc', 'bitrate=%d' % (KBPS * 1000),
            'iframeinterval=%d' % (FPS * 2), 'insert-sps-pps=true', '!', 'h264parse', '!',
            'video/x-h264,stream-format=byte-stream', '!', 'fdsink', 'sync=false']


def gst_has(*elements):
    return shutil.which('gst-launch-1.0') and all(
        subprocess.call(['gst-inspect-1.0', e], stdout=DEVNULL, stderr=DEVNULL) == 0 for e in elements)


def ffmpeg_fps_mode():
    try:
        m = re.search(r'version n?(\d+)\.(\d+)', subprocess.check_output(['ffmpeg', '-version']).decode())
        old = m and (int(m.group(1)), int(m.group(2))) < (5, 1)
    except Exception:
        old = False
    return ['-vsync', 'vfr'] if old else ['-fps_mode', 'vfr']


def info():
    env = x_session()
    warn = ''
    if not env:
        warn = 'no desktop session (log in on the device)'
    elif env.get('XDG_SESSION_TYPE') == 'wayland' or env.get('WAYLAND_DISPLAY'):
        warn = 'Wayland desktop: log in with "Ubuntu on Xorg"'
    return {'app': 'simplestream', 'id': ID, 'name': NAME, 'host': HOST, 'model': MODEL, 'port': PORT,
            'encoder': 'jetson' if ENCODERS[:1] == [jetson_cmd] else 'x264', 'viewers': viewers, 'warn': warn}


def beacon():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 1)
    while True:
        msg = json.dumps(info()).encode()
        for ip, bcast in interfaces():  # every interface, so a laptop on eth + wifi still sees us
            try:
                sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(ip))
                sock.sendto(msg, (GROUP, DISCOVERY_PORT))
            except OSError:
                pass
            try:
                sock.sendto(msg, (bcast, DISCOVERY_PORT))
            except OSError:
                pass
        time.sleep(2)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, code, text, ctype='text/plain'):
        body = text.encode()
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.split('?')[0] == '/stream':
            self.stream()
        else:
            self.reply(200, json.dumps(info()), 'application/json')

    def start_encoder(self, env):
        """Start the first encoder that produces output; returns (process, first bytes)."""
        size = screen_size(env)
        for make_cmd in list(ENCODERS):
            try:
                proc = subprocess.Popen(make_cmd(env, size), stdout=subprocess.PIPE, stdin=DEVNULL, env=env)
            except OSError as e:
                log('%s: %s' % (make_cmd.__name__, e))
                continue
            first = b''
            if select.select([proc.stdout], [], [], 6)[0]:  # a working encoder outputs within a second
                first = os.read(proc.stdout.fileno(), 1 << 16)
            if first:
                return proc, first
            proc.kill()
            proc.wait()
            log('%s failed to start (exit code %s)' % (make_cmd.__name__, proc.returncode))
            if make_cmd is jetson_cmd and ENCODER == 'auto' and jetson_cmd in ENCODERS:
                ENCODERS.remove(jetson_cmd)  # e.g. no hardware encoder: use ffmpeg from now on
        return None, b''

    def stream(self):
        global viewers
        env = x_session()
        if not env:
            return self.reply(503, 'No desktop session on this device - log in first')
        with lock:
            if viewers >= MAX_VIEWERS:
                return self.reply(503, 'Device is busy (too many viewers)')
            viewers += 1
        proc = None
        try:
            proc, data = self.start_encoder(env)
            if not proc:
                return self.reply(500, 'Screen capture failed - run: simplestream-client logs')
            log('streaming to %s' % self.client_address[0])
            self.send_response(200)
            self.send_header('Content-Type', 'video/h264')
            self.end_headers()
            self.connection.settimeout(10)  # don't hang forever if the laptop vanishes
            while data:
                self.wfile.write(data)
                data = os.read(proc.stdout.fileno(), 1 << 16)
        except OSError:
            pass  # laptop disconnected
        finally:
            with lock:
                viewers -= 1
            if proc:
                proc.kill()
                proc.wait()
                log('stopped streaming to %s' % self.client_address[0])


class Server(ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def serve():
    if shutil.which('ffmpeg'):
        FPS_MODE[:] = ffmpeg_fps_mode()
    else:
        log('warning: ffmpeg is not installed')
    if ENCODER == 'jetson' or ENCODER == 'auto' and gst_has('ximagesrc', 'nvvidconv', 'nvv4l2h264enc'):
        ENCODERS[:] = [jetson_cmd, ffmpeg_cmd]
    else:
        ENCODERS[:] = [ffmpeg_cmd]
    threading.Thread(target=beacon, daemon=True).start()
    server = Server(('', PORT), Handler)
    log('Simple Stream client "%s" (%s) on port %d, encoder: %s' % (NAME, ID, PORT, info()['encoder']))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


# --- command line --------------------------------------------------------------------------
def root(cmd):
    """Run a command as root (through sudo unless we are root already)."""
    return subprocess.call(cmd if os.getuid() == 0 else ['sudo'] + cmd)


def service_state():
    try:
        return subprocess.check_output(['systemctl', 'is-active', SERVICE], stderr=DEVNULL).decode().strip()
    except (OSError, subprocess.CalledProcessError) as e:
        return getattr(e, 'output', b'').decode().strip() or 'unknown'


def status():
    try:
        with urllib.request.urlopen('http://127.0.0.1:%d/info' % PORT, timeout=2) as r:
            live = json.loads(r.read().decode())
    except (OSError, ValueError):
        live = None
    green, yellow, dim, off = '\033[32m', '\033[33m', '\033[2m', '\033[0m'
    if live:
        print('%s●%s Simple Stream client is running' % (green, off))
    else:
        print('%s○%s Simple Stream client is not running (service: %s)' % (yellow, off, service_state()))
        print('  start it with: simplestream-client start')
    print('  name     %s' % (live or {}).get('name', NAME))
    print('  address  %s' % (', '.join('%s:%d' % (ip, PORT) for ip, _ in interfaces()) or 'no network'))
    if live:
        print('  encoder  %s   viewers %d' % (live['encoder'], live['viewers']))
        if live['warn']:
            print('%s  ! %s%s' % (yellow, live['warn'], off))
    print('%s  rename: simplestream-client name "Face detection"   help: simplestream-client help%s' % (dim, off))


def set_name(name):
    if not name:
        return print(NAME)
    lines = [line for line in read(CONF_FILE).splitlines() if not line.startswith('SS_NAME=')]
    lines.insert(1 if lines else 0, 'SS_NAME="%s"' % name.replace('"', ''))
    with tempfile.NamedTemporaryFile('w', delete=False) as f:
        f.write('\n'.join(lines) + '\n')
    root(['install', '-m644', f.name, CONF_FILE])
    os.unlink(f.name)
    root(['systemctl', 'restart', SERVICE])
    print('renamed to "%s"' % name)


def uninstall():
    root(['systemctl', 'disable', '--now', SERVICE])
    root(['rm', '-f', '/etc/systemd/system/%s.service' % SERVICE, CONF_FILE, os.path.abspath(sys.argv[0])])
    root(['systemctl', 'daemon-reload'])
    print('Simple Stream client removed')


def main():
    cmd, args = (sys.argv[1], sys.argv[2:]) if len(sys.argv) > 1 else ('status', [])
    if cmd == 'run':
        serve()
    elif cmd == 'status':
        status()
    elif cmd == 'name':
        set_name(' '.join(args).strip())
    elif cmd in ('start', 'stop', 'restart'):
        sys.exit(root(['systemctl', cmd, SERVICE]))
    elif cmd == 'logs':
        os.execvp('journalctl', ['journalctl', '-u', SERVICE, '-n', '50', '-f'])
    elif cmd == 'uninstall':
        uninstall()
    elif cmd in ('help', '-h', '--help'):
        print(USAGE)
    else:
        print(USAGE, file=sys.stderr)
        sys.exit(2)


if __name__ == '__main__':
    main()
PYTHON
# ---------------------------------------------------------------------------------------

$SUDO install -m755 "$tmp/simplestream-client" "$BIN"

NAME="${NAME//\"/}"
if [ ! -f "$CONF" ]; then
  cat > "$tmp/conf" <<EOF
# Simple Stream client settings.  Apply changes with:  simplestream-client restart
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
  $SUDO install -m644 "$tmp/conf" "$CONF"
elif [ -n "$NAME" ]; then  # re-install: keep the settings, just change the name
  { grep -v '^SS_NAME=' "$CONF" || true; echo "SS_NAME=\"$NAME\""; } > "$tmp/conf"
  $SUDO install -m644 "$tmp/conf" "$CONF"
fi

if [ ! -d /run/systemd/system ]; then
  ok "installed. No systemd here, so start it yourself:  simplestream-client run"
  exit 0
fi

# the service must run as the desktop user so it can see the screen
user="${SUDO_USER:-$(id -un)}"
if [ "$user" = root ]; then user="$(id -nu 1000 2>/dev/null || echo root)"; fi
cat > "$tmp/unit" <<EOF
[Unit]
Description=Simple Stream client (shares this screen on the LAN)
After=network-online.target
Wants=network-online.target

[Service]
User=$user
ExecStart=$(command -v python3) -u $BIN run
Restart=always
RestartSec=3
Nice=5

[Install]
WantedBy=multi-user.target
EOF
$SUDO install -m644 "$tmp/unit" /etc/systemd/system/simplestream.service
$SUDO systemctl daemon-reload
$SUDO systemctl enable simplestream >/dev/null 2>&1
$SUDO systemctl restart simplestream

# open the stream port if a firewall is running
if command -v ufw >/dev/null && $SUDO ufw status 2>/dev/null | grep -q 'Status: active'; then
  $SUDO ufw allow 47801/tcp >/dev/null && ok "firewall (ufw): allowed 47801/tcp"
fi
if command -v firewall-cmd >/dev/null && $SUDO firewall-cmd --state >/dev/null 2>&1; then
  $SUDO firewall-cmd -q --permanent --add-port=47801/tcp && $SUDO firewall-cmd -q --reload
fi

sleep 2
if systemctl is-active --quiet simplestream; then
  ok "installed and running (starts on boot)"
  echo
  "$BIN" status
else
  $SUDO journalctl -u simplestream -n 20 --no-pager || true
  die "the client did not start, see the log above"
fi
