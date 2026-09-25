#!/usr/bin/env bash
# Simple Stream server: pick which edge device is shown, then share that window in your meeting.
#
#   curl -fsSL https://raw.githubusercontent.com/haneeshbyreddy/simple_stream/main/server.sh | bash
#
# Installs the `simplestream` command (needs Python 3.10+). Run `simplestream help` afterwards.
set -euo pipefail

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m ✔\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m ✘ %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Linux ] || die "Simple Stream only supports Linux"
[ "$(id -u)" -ne 0 ] || die "run this as your normal user (no sudo); it asks for your password when needed"

install_packages() {
  if command -v apt-get >/dev/null; then
    sudo apt-get update -qq </dev/null || true
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" </dev/null >/dev/null
  elif command -v dnf >/dev/null; then
    sudo dnf install -y -q python3 </dev/null
  elif command -v pacman >/dev/null; then
    sudo pacman -S --needed --noconfirm python </dev/null
  fi
}

say "Installing the Simple Stream server"
command -v python3 >/dev/null || install_packages python3
python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))' ||
  die "needs Python 3.10 or newer (Ubuntu 22.04+), found $(python3 --version)"

APP="$HOME/.local/share/simplestream"
mkdir -p "$APP" "$HOME/.local/bin" "$HOME/.local/share/applications"
if [ ! -x "$APP/venv/bin/python" ]; then
  if ! python3 -m venv "$APP/venv" >/dev/null 2>&1; then
    rm -rf "$APP/venv"
    install_packages python3-venv
    python3 -m venv "$APP/venv" || die "could not create a Python virtual environment"
  fi
fi
say "Installing Python packages (Textual, PyAV, pygame-ce), this can take a minute"
"$APP/venv/bin/python" -m pip install -q --disable-pip-version-check --upgrade \
  'textual>=1.0' 'av>=12' 'pygame-ce>=2.4' || die "pip install failed"

# ---------------------------------------------------------------------------------------
# The program itself
# ---------------------------------------------------------------------------------------
cat > "$APP/simplestream.py" <<'PYTHON'
#!/usr/bin/env python3
"""Simple Stream: show your edge devices' screens on this laptop (then share that window in Meet).

Devices running simplestream-client are found automatically (UDP beacons like LocalSend,
plus a subnet scan fallback).  The terminal UI picks what is "on stage"; the viewer
window shows it as a grid, click a tile to fill the window.
"""
import fcntl
import ipaddress
import json
import math
import os
import shutil
import socket
import struct
import subprocess
import sys
import threading
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import av  # noqa: E402
import pygame  # noqa: E402
from rich.markup import escape  # noqa: E402
from rich.text import Text  # noqa: E402
from textual.app import App, ComposeResult  # noqa: E402
from textual.binding import Binding  # noqa: E402
from textual.containers import Vertical  # noqa: E402
from textual.screen import ModalScreen  # noqa: E402
from textual.widgets import DataTable, Footer, Header, Input, Label, RichLog, Static  # noqa: E402

USAGE = """Simple Stream - show your edge devices' screens, then share the window in your meeting.

usage: simplestream [command]

  (no command)        open the device picker and the viewer window
  list                list the devices on the network
  show DEVICE...      open only the viewer with these devices (name, hostname or IP)
  uninstall           remove Simple Stream from this laptop
  help                show this help

In the picker: 1-9 show device N, Enter show only, Space add/remove, f fill, g grid,
n rename, a add IP, r rescan, v reopen viewer, q quit.
In the viewer: click a tile to fill the window, click / Esc for the grid, F11 fullscreen."""

HOME = Path.home()
DATA = HOME / '.local' / 'share' / 'simplestream'
CONFIG = Path(os.environ.get('XDG_CONFIG_HOME') or HOME / '.config') / 'simplestream' / 'server.json'
VIEWER_LOG = Path(os.environ.get('XDG_CACHE_HOME') or HOME / '.cache') / 'simplestream' / 'viewer.log'
INSTALL = 'curl -fsSL https://raw.githubusercontent.com/haneeshbyreddy/simple_stream/main/client.sh | bash'


# === discovery ============================================================================
GROUP, DISCOVERY_PORT, STREAM_PORT = '224.0.0.177', 47800, 47801
OFFLINE_AFTER = 7  # seconds without hearing from a device


def interfaces():
    """[(name, IPv4Interface)] of every interface that is up, loopback excluded."""
    out, s = [], socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    for _, name in socket.if_nameindex():
        req = struct.pack('256s', name[:15].encode())
        try:
            flags = struct.unpack('H', fcntl.ioctl(s, 0x8913, req)[16:18])[0]  # SIOCGIFFLAGS
            ip = socket.inet_ntoa(fcntl.ioctl(s, 0x8915, req)[20:24])         # SIOCGIFADDR
            mask = socket.inet_ntoa(fcntl.ioctl(s, 0x891b, req)[20:24])       # SIOCGIFNETMASK
        except OSError:
            continue
        if flags & 1 and not flags & 8:  # IFF_UP and not IFF_LOOPBACK
            out.append((name, ipaddress.IPv4Interface(f'{ip}/{mask}')))
    s.close()
    return out


class Device:
    def __init__(self, info, ip):
        self.id = info['id']
        self.ip = ip
        self.seen = 0.0
        self.update(info, ip)

    def update(self, info, ip):
        now = time.time()
        # a device reachable over two networks answers from both: stick to one while it's alive
        if ip != self.ip and now - self.seen > 3:
            self.ip = ip
        self.seen = now
        self.name = str(info.get('name') or info.get('host') or ip)
        self.host = str(info.get('host', ''))
        self.model = str(info.get('model', ''))
        self.port = int(info.get('port') or STREAM_PORT)
        self.warn = str(info.get('warn', ''))
        self.encoder = str(info.get('encoder', ''))

    @property
    def online(self):
        return time.time() - self.seen < OFFLINE_AFTER

    @property
    def addr(self):
        return f'{self.ip}:{self.port}'


class Discovery:
    def __init__(self):
        self.devices = {}     # id -> Device
        self.unicast = set()  # "ip:port" polled directly (scan hits + manual adds)
        self.events = []      # messages for the UI log
        self.lock = threading.Lock()
        self.pool = ThreadPoolExecutor(64)

    def start(self, hosts=()):
        for addr in hosts:
            self.add(addr)
        threading.Thread(target=self._listen, daemon=True).start()
        threading.Thread(target=self._poll, daemon=True).start()
        self.scan(quiet=True)

    def snapshot(self):
        with self.lock:
            events, self.events = self.events, []
            return list(self.devices.values()), events

    def _seen(self, info, ip):
        if not isinstance(info, dict) or info.get('app') != 'simplestream' or not info.get('id'):
            return
        with self.lock:
            dev = self.devices.get(info['id'])
            if dev is None:
                dev = self.devices[info['id']] = Device(info, ip)
                name = dev.name.replace('[', r'\[')  # names are shown with rich markup
                self.events.append(f'[green]+[/] found [b]{name}[/] at {dev.addr}')
            else:
                dev.update(info, ip)

    def _listen(self):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            sock.bind(('', DISCOVERY_PORT))
        except OSError as e:
            with self.lock:
                self.events.append(f'[red]cannot listen on UDP {DISCOVERY_PORT} ({e}), relying on network scan')
            return
        sock.settimeout(2)
        joined, next_join = set(), 0.0
        while True:
            if time.time() > next_join:  # (re)join the group on new interfaces, e.g. after wifi reconnects
                next_join = time.time() + 10
                for _, iface in interfaces():
                    ip = str(iface.ip)
                    if ip not in joined:
                        try:
                            mreq = socket.inet_aton(GROUP) + socket.inet_aton(ip)
                            sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
                            joined.add(ip)
                        except OSError:
                            pass
            try:
                data, (ip, _) = sock.recvfrom(4096)
                self._seen(json.loads(data), ip)
            except socket.timeout:
                pass
            except ValueError:
                pass  # not our JSON

    def probe(self, addr, timeout=1.5):
        """GET /info from "ip:port"; True if a Simple Stream client answered."""
        try:
            with urllib.request.urlopen(f'http://{addr}/info', timeout=timeout) as r:
                info = json.loads(r.read(4096))
        except (OSError, ValueError):
            return False
        self._seen(info, addr.rsplit(':', 1)[0])
        return isinstance(info, dict) and info.get('app') == 'simplestream'

    def _poll(self):
        while True:
            time.sleep(2.5)
            for addr in list(self.unicast):
                self.pool.submit(self.probe, addr)

    def add(self, addr):
        if ':' not in addr:
            addr = f'{addr}:{STREAM_PORT}'
        self.unicast.add(addr)
        self.pool.submit(self.probe, addr)
        return addr

    def scan(self, quiet=False):
        """Probe every host on our local subnets (/22 or smaller) in the background."""
        def run():
            hosts = []
            for _, iface in interfaces():
                net = iface.network if iface.network.prefixlen >= 22 else ipaddress.ip_network(f'{iface.ip}/24', False)
                hosts += [f"{h}:{STREAM_PORT}" for h in net.hosts()]
            found = [a for a, ok in zip(hosts, self.pool.map(lambda a: self.probe(a, 0.8), hosts)) if ok]
            self.unicast.update(found)
            if not quiet:
                with self.lock:
                    self.events.append(f'scan finished: {len(found)} device(s) answered on {len(hosts)} addresses')
        threading.Thread(target=run, daemon=True).start()



# === viewer window ========================================================================
BG, TILE, TEXT, DIM = (11, 13, 19), (26, 29, 39), (236, 239, 244), (138, 145, 163)
ACCENT, BAD = (94, 170, 255), (255, 120, 110)
GAP = 10


def fit(w, h, box_w, box_h):
    s = min(box_w / w, box_h / h)
    return max(2, int(w * s)), max(2, int(h * s))


class Stream(threading.Thread):
    """Pulls one device's H.264 stream, decodes it and keeps the latest frame ready to draw."""

    def __init__(self, sid, name, addr):
        super().__init__(daemon=True)
        self.sid, self.name, self.addr = sid, name, addr
        self.state, self.msg = 'connecting', ''
        self.want = None     # (w, h) box the next frames should be scaled into; None = hidden
        self.image = None    # latest frame as an RGB av.VideoFrame, already scaled
        self.version = 0
        self.size, self.fps = None, 0.0
        self.alive, self.sock = True, None
        self.start()

    def stop(self):
        self.alive = False
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except (OSError, AttributeError):
            pass

    def run(self):
        delay = 0.5
        while self.alive:
            try:
                self.state = 'connecting'
                self._stream()
            except ConnectionRefusedError:
                self.msg = 'Simple Stream client is not running on the device'
            except (socket.timeout, TimeoutError):
                self.msg = 'device is not responding'
            except Exception as e:  # device went away, unreachable, decode error, ...
                self.msg = getattr(e, 'strerror', None) or str(e) or type(e).__name__
            finally:
                if self.sock:
                    self.sock.close()
            if self.state == 'live':
                delay = 0.5
            self.state, self.fps = 'error', 0.0
            time.sleep(delay)
            delay = min(delay * 2, 4)

    def _stream(self):
        host, port = self.addr.rsplit(':', 1)
        self.sock = sock = socket.create_connection((host, int(port)), timeout=4)
        sock.settimeout(15)  # the device may need a few seconds to fall back to another encoder
        sock.sendall(f'GET /stream HTTP/1.0\r\nHost: {host}\r\n\r\n'.encode())
        buf = b''
        while b'\r\n\r\n' not in buf:
            chunk = sock.recv(4096)
            if not chunk:
                raise ConnectionError('device closed the connection')
            buf += chunk
        head, data = buf.split(b'\r\n\r\n', 1)
        if b' 200 ' not in head.split(b'\r\n', 1)[0]:
            while len(data) < 2000 and (chunk := sock.recv(4096)):
                data += chunk
            raise ConnectionError(data.decode(errors='replace').strip() or head.split(b'\r\n', 1)[0].decode())
        sock.settimeout(8)  # the device sends frames continuously; silence means it's gone
        codec = av.CodecContext.create('h264', 'r')
        frames, t0 = 0, time.time()
        while self.alive:
            for packet in codec.parse(data):
                for frame in codec.decode(packet):
                    self._show(frame)
                    frames += 1
            if time.time() - t0 >= 1:
                self.fps, frames, t0 = frames / (time.time() - t0), 0, time.time()
            data = sock.recv(1 << 16)
            if not data:
                raise ConnectionError('stream ended')

    def _show(self, frame):
        self.size = frame.width, frame.height
        self.state, self.msg = 'live', ''
        if self.want:
            w, h = fit(frame.width, frame.height, *self.want)
            self.image = frame.reformat(w, h, 'rgb24', interpolation='AREA')
            self.version += 1


class Viewer:
    def __init__(self, controlled=True):
        self.controlled = controlled  # False: `simplestream show`, no TUI attached
        pygame.display.init()
        pygame.font.init()
        pygame.display.set_caption('Simple Stream')
        pygame.display.set_icon(self._icon())
        self.screen = pygame.display.set_mode((1280, 720), pygame.RESIZABLE)
        self.streams, self.focus = [], None
        self.labels = True
        self.inbox, self.inbox_lock = [], threading.Lock()
        self.surfaces = {}  # sid -> (version, Surface)
        self.last_mouse, self.focus_time, self.last_status = time.time(), 0.0, 0.0
        self.font = self._font(20)
        self.small = self._font(15)
        self.big = self._font(44, bold=True)
        if controlled:
            threading.Thread(target=self._read_stdin, daemon=True).start()

    @staticmethod
    def _font(size, bold=False):
        return pygame.font.SysFont('inter,ubuntu,cantarell,dejavusans,sans', size, bold=bold)

    @staticmethod
    def _icon():
        icon = pygame.Surface((64, 64), pygame.SRCALPHA)
        for i, (x, y) in enumerate([(4, 8), (34, 8), (4, 36), (34, 36)]):
            pygame.draw.rect(icon, ACCENT if i == 0 else (70, 78, 96), (x, y, 26, 20), border_radius=5)
        return icon

    # --- commands from the TUI -------------------------------------------------------
    def _read_stdin(self):
        for line in sys.stdin:
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            with self.inbox_lock:
                self.inbox.append(msg)
        pygame.event.post(pygame.event.Event(pygame.QUIT))  # TUI exited

    def _apply(self, msg):
        if 'streams' in msg:
            old = {s.sid: s for s in self.streams}
            new = []
            for item in msg['streams']:
                s = old.pop(item['id'], None)
                if s and s.addr != item['addr']:  # device got a new IP
                    s.stop()
                    self.surfaces.pop(s.sid, None)
                    s = None
                if s is None:
                    s = Stream(item['id'], item['name'], item['addr'])
                s.name = item['name']
                new.append(s)
            for s in old.values():
                s.stop()
                self.surfaces.pop(s.sid, None)
            self.streams = new
        if 'focus' in msg:
            self._set_focus(msg['focus'], report=False)

    def _set_focus(self, sid, report=True):
        if sid != self.focus:
            self.focus, self.focus_time = sid, time.time()
            if report:
                self._send({'focus': sid})

    def _send(self, msg):
        if not self.controlled:
            return
        try:
            print(json.dumps(msg), flush=True)
        except (BrokenPipeError, ValueError):
            pass

    # --- layout & drawing -------------------------------------------------------------
    def layout(self):
        """[(stream, Rect)] for what is visible right now."""
        W, H = self.screen.get_size()
        focused = [s for s in self.streams if s.sid == self.focus]
        shown = focused or self.streams
        n = len(shown)
        if n == 0:
            return []
        if n == 1:
            return [(shown[0], pygame.Rect(0, 0, W, H))]
        best = None
        for cols in range(1, n + 1):  # pick the grid that gives the biggest 16:9 tiles
            rows = math.ceil(n / cols)
            cw, ch = (W - GAP * (cols + 1)) / cols, (H - GAP * (rows + 1)) / rows
            tw = max(1, min(cw, ch * 16 / 9))
            if best is None or tw > best[0]:
                best = (tw, cols, rows)
        tw, cols, rows = best
        th = tw * 9 / 16
        out = []
        for i, s in enumerate(shown):
            r, c = divmod(i, cols)
            in_row = min(cols, n - r * cols)
            x0 = (W - in_row * tw - (in_row - 1) * GAP) / 2
            y0 = (H - rows * th - (rows - 1) * GAP) / 2
            out.append((s, pygame.Rect(round(x0 + c * (tw + GAP)), round(y0 + r * (th + GAP)), round(tw), round(th))))
        return out

    def surface(self, s):
        cached = self.surfaces.get(s.sid)
        if cached and cached[0] == s.version:
            return cached[1]
        img = s.image
        if img is None:
            return None
        plane = img.planes[0]
        surf = pygame.image.frombuffer(plane, (img.width, img.height), 'RGB', pitch=plane.line_size).convert()
        self.surfaces[s.sid] = (s.version, surf)
        return surf

    def text(self, font, text, color, center=None, **pos):
        surf = font.render(text, True, color)
        rect = surf.get_rect(center=center) if center else surf.get_rect(**pos)
        self.screen.blit(surf, rect)
        return rect

    def pill(self, text, **pos):
        surf = self.font.render(text, True, TEXT)
        rect = surf.get_rect(**pos).inflate(22, 10)
        bg = pygame.Surface(rect.size, pygame.SRCALPHA)
        pygame.draw.rect(bg, (0, 0, 0, 170), bg.get_rect(), border_radius=rect.height // 2)
        self.screen.blit(bg, rect)
        self.screen.blit(surf, surf.get_rect(center=rect.center))

    def draw(self):
        self.screen.fill(BG)
        tiles = self.layout()
        visible = {s.sid for s, _ in tiles}
        for s in self.streams:
            if s.sid not in visible:
                s.want = None
        if not tiles:
            return self.draw_idle()
        grid = len(tiles) > 1
        mouse = pygame.mouse.get_pos()
        for i, (s, rect) in enumerate(tiles):
            s.want = rect.size
            if grid:
                pygame.draw.rect(self.screen, TILE, rect, border_radius=12)
            surf = self.surface(s)
            if surf:
                self.screen.blit(surf, surf.get_rect(center=rect.center))
            if s.state != 'live' or not surf:
                if surf:  # stale picture from before the drop: dim it
                    shade = pygame.Surface(rect.size, pygame.SRCALPHA)
                    shade.fill((0, 0, 0, 150))
                    self.screen.blit(shade, rect)
                dots = '.' * (int(time.time() * 3) % 4)
                title = f'Connecting to {s.name}{dots}' if s.state == 'connecting' else f'{s.name} unavailable, retrying{dots}'
                self.text(self.font, title, TEXT, center=(rect.centerx, rect.centery - 12))
                if s.msg:
                    self.text(self.small, s.msg[:90], BAD, center=(rect.centerx, rect.centery + 16))
            if grid:
                if self.labels:
                    self.pill(f'{i + 1}   {s.name}', bottomleft=(rect.x + 16, rect.bottom - 14))
                if rect.collidepoint(mouse):
                    pygame.draw.rect(self.screen, ACCENT, rect.inflate(4, 4), width=3, border_radius=14)
        if self.focus and len(self.streams) > 1 and time.time() - self.focus_time < 2.5:
            self.pill(f'{tiles[0][0].name}  ·  click or Esc for grid', midtop=(self.screen.get_width() // 2, 18))

    def draw_idle(self):
        W, H = self.screen.get_size()
        logo = self._icon()
        self.screen.blit(logo, logo.get_rect(center=(W // 2, H // 2 - 90)))
        self.text(self.big, 'Simple Stream', TEXT, center=(W // 2, H // 2 - 10))
        self.text(self.font, 'Pick a device in the terminal:  Space to add  ·  1-9 to show one', DIM,
                  center=(W // 2, H // 2 + 40))

    # --- main loop -----------------------------------------------------------------------
    def handle(self, ev):
        if ev.type == pygame.MOUSEMOTION:
            self.last_mouse = time.time()
            pygame.mouse.set_visible(True)
        elif ev.type == pygame.MOUSEBUTTONUP and ev.button in (1, 3):
            if self.focus and len(self.streams) > 1:
                self._set_focus(None)  # any click on a filled stream goes back to the grid
            elif ev.button == 1 and len(self.streams) > 1:
                hit = [s.sid for s, rect in self.layout() if rect.collidepoint(ev.pos)]
                if hit:
                    self._set_focus(hit[0])
        elif ev.type == pygame.KEYDOWN:
            if ev.key in (pygame.K_F11, pygame.K_f):
                pygame.display.toggle_fullscreen()
            elif ev.key == pygame.K_ESCAPE and not self.focus and self.screen.get_flags() & pygame.FULLSCREEN:
                pygame.display.toggle_fullscreen()
            elif ev.key in (pygame.K_ESCAPE, pygame.K_0, pygame.K_g):
                self._set_focus(None)
            elif ev.key == pygame.K_l:
                self.labels = not self.labels
            elif pygame.K_1 <= ev.key <= pygame.K_9 and ev.key - pygame.K_1 < len(self.streams):
                self._set_focus(self.streams[ev.key - pygame.K_1].sid)

    def status(self):
        self._send({'status': {s.sid: {'state': s.state, 'fps': round(s.fps, 1), 'msg': s.msg,
                                       'size': '%dx%d' % s.size if s.size else ''} for s in self.streams},
                    'focus': self.focus})

    def run(self):
        clock = pygame.time.Clock()
        seen = None
        while True:
            dirty = False
            for ev in pygame.event.get():
                if ev.type == pygame.QUIT:
                    return
                self.handle(ev)
                dirty = True
            with self.inbox_lock:
                inbox, self.inbox = self.inbox, []
            for msg in inbox:
                self._apply(msg)
                dirty = True
            if self.focus and self.focus not in {s.sid for s in self.streams}:
                self.focus = None
            now = time.time()
            if self.focus and now - self.last_mouse > 2:
                pygame.mouse.set_visible(False)  # clean picture while presenting
            versions = [(s.sid, s.version, s.state) for s in self.streams]
            animating = any(s.state != 'live' for s in self.streams) or now - self.focus_time < 3
            if dirty or versions != seen or animating:
                seen = versions
                self.draw()
                pygame.display.flip()
            if now - self.last_status > 1:
                self.last_status = now
                self.status()
            clock.tick(60)




# === device picker (terminal UI) ==========================================================
class Prompt(ModalScreen):
    """A one-line text dialog; dismisses with the text, or None on Esc."""
    BINDINGS = [Binding('escape', 'cancel', 'Cancel')]

    def __init__(self, title, value='', placeholder=''):
        super().__init__()
        self.title_text, self.value, self.placeholder = title, value, placeholder

    def compose(self) -> ComposeResult:
        with Vertical(id='dialog'):
            yield Label(self.title_text, id='dialog-title')
            yield Input(self.value, placeholder=self.placeholder)
            yield Label('[dim]Enter to save · Esc to cancel[/]')

    def on_input_submitted(self, event):
        self.dismiss(event.value.strip())

    def action_cancel(self):
        self.dismiss(None)


class DeviceTable(DataTable):
    """Click a row to put it on/off stage, Enter to show only that device."""
    BINDINGS = [Binding('enter', 'select_cursor', 'Show only')]

    def on_click(self, event):
        row = event.style.meta.get('row', -1)
        if isinstance(row, int) and row >= 0:
            self.app.toggle_index(row)

    def action_select_cursor(self):
        self.app.action_solo()


class SimpleStream(App):
    TITLE = 'Simple Stream'
    CSS = """
    #devices { height: 1fr; border: round $primary 40%; border-title-color: $text; }
    #empty { height: 1fr; content-align: center middle; text-align: center; color: $text-muted; }
    #log { height: 8; border: round $primary 25%; border-title-color: $text-muted; padding: 0 1;
           scrollbar-size-vertical: 1; }
    Prompt { align: center middle; }
    #dialog { width: 64; height: auto; padding: 1 2; background: $surface; border: thick $accent; }
    #dialog Input { margin: 1 0; }
    """
    BINDINGS = [
        Binding('space', 'toggle', 'On/off stage'),
        Binding('f', 'fill', 'Fill'),
        Binding('g', 'grid', 'Grid'),
        Binding('c', 'clear', 'Clear'),
        Binding('n', 'rename', 'Rename'),
        Binding('a', 'add', 'Add IP'),
        Binding('r', 'rescan', 'Rescan'),
        Binding('v', 'viewer', 'Viewer'),
        Binding('q', 'quit', 'Quit'),
    ] + [Binding(str(i), f'solo_number({i})', show=False) for i in range(1, 10)]

    def __init__(self):
        super().__init__()
        self.config = load_config()
        self.discovery = Discovery()
        self.devices = []            # sorted, as shown in the table
        self.stage, self.focus = [], None
        self.viewer, self.vstatus, self.sent = None, {}, None
        self.online, self.row_ids = {}, None
        self.quitting = False

    # --- ui ------------------------------------------------------------------------------
    def compose(self) -> ComposeResult:
        yield Header()
        self.table = DeviceTable(id='devices', cursor_type='row', zebra_stripes=True)
        self.table.border_title = 'Devices'
        yield self.table
        self.empty = Static(f'[b]Looking for devices on your network…[/]\n\n'
                            f'Install the client on every edge device:\n\n[b cyan]{INSTALL}[/]', id='empty')
        yield self.empty
        self.log_view = RichLog(id='log', markup=True, wrap=True, max_lines=300)
        self.log_view.border_title = 'Activity'
        yield self.log_view
        yield Footer()

    def on_mount(self):
        for key, label in [('n', '#'), ('on', ''), ('name', 'Device'), ('addr', 'Address'),
                           ('model', 'Model'), ('status', 'Status')]:
            self.table.add_column(label, key=key)
        nets = ', '.join(f'{name} {iface}' for name, iface in interfaces()) or 'no network!'
        self.say(f'listening on {nets}')
        self.discovery.start(self.config['hosts'])
        self.action_viewer()
        self.set_interval(1, self.tick)
        self.tick()

    def say(self, msg):
        self.log_view.write(f'[dim]{time.strftime("%H:%M:%S")}[/]  {msg}')

    def name_of(self, dev):
        return self.config['names'].get(dev.id) or dev.name

    def label(self, dev):
        return f'[b]{escape(self.name_of(dev))}[/]'

    def save(self):
        CONFIG.parent.mkdir(parents=True, exist_ok=True)
        CONFIG.write_text(json.dumps(self.config, indent=2))

    def current(self):
        """The device under the cursor."""
        row = self.table.cursor_row
        return self.devices[row] if 0 <= row < len(self.devices) else None

    def tick(self):
        devices, events = self.discovery.snapshot()
        for e in events:
            self.say(e)
        for d in devices:
            if self.online.get(d.id, True) != d.online:
                self.say(f'{self.label(d)} is {"back online" if d.online else "[red]offline[/]"}')
            self.online[d.id] = d.online
        self.devices = sorted(devices, key=lambda d: (self.name_of(d).lower(), d.id))
        self.render_table()
        self.push_stage()
        viewer = 'viewer open' if self.viewer_running() else 'viewer closed (press v)'
        self.sub_title = f'{sum(d.online for d in devices)} online · {len(self.stage)} on stage · {viewer}'

    def status_cell(self, d):
        if d.id in self.stage:
            s = self.vstatus.get(d.id)
            if s and s['state'] == 'live':
                return Text(f'● live {s["fps"]:.0f} fps {s["size"]}', 'bold green')
            if s and s['state'] == 'error':
                return Text(f'✕ {s["msg"][:48]}', 'red')
            return Text('◌ connecting…', 'yellow')
        if not d.online:
            return Text('offline', 'dim red')
        if d.warn:
            return Text(f'⚠ {d.warn[:48]}', 'yellow')
        return Text(f'online · {d.encoder}', 'green')

    def render_table(self):
        table = self.table
        self.empty.display = not self.devices
        table.display = bool(self.devices)
        rows = []
        for i, d in enumerate(self.devices):
            on = d.id in self.stage
            mark = Text('◉', 'bold #5eaaff') if d.id == self.focus else Text('●' if on else '○', 'bold green' if on else 'dim')
            name = Text(self.name_of(d), 'bold' if d.online else 'dim')
            if d.host and d.host != self.name_of(d):
                name.append(f'  {d.host}', 'dim')
            model = d.model.replace('NVIDIA ', '').replace(' Developer Kit', '')
            rows.append((d.id, [Text(str(i + 1) if i < 9 else '', 'dim'), mark, name, Text(d.addr, 'dim'),
                                Text(model[:24], 'dim'), self.status_cell(d)]))
        ids = [r[0] for r in rows]
        if ids != self.row_ids:  # devices added/removed/reordered: rebuild, keep the cursor on the same device
            row = table.cursor_row
            keep = self.row_ids[row] if self.row_ids and 0 <= row < len(self.row_ids) else None
            table.clear()
            for key, cells in rows:
                table.add_row(*cells, key=key)
            self.row_ids = ids
            if keep in ids:
                table.move_cursor(row=ids.index(keep), animate=False)
        else:
            for key, cells in rows:
                for col, cell in zip(('n', 'on', 'name', 'addr', 'model', 'status'), cells):
                    table.update_cell(key, col, cell, update_width=True)

    # --- stage / viewer ------------------------------------------------------------------
    def push_stage(self):
        if not self.viewer_running():
            return
        by_id = {d.id: d for d in self.devices}
        msg = {'streams': [{'id': i, 'name': self.name_of(by_id[i]), 'addr': by_id[i].addr}
                           for i in self.stage if i in by_id],
               'focus': self.focus}
        if msg != self.sent:
            try:
                self.viewer.stdin.write(json.dumps(msg) + '\n')
                self.viewer.stdin.flush()
                self.sent = msg
            except (OSError, ValueError):
                pass

    def changed(self):
        self.render_table()
        self.push_stage()

    def viewer_running(self):
        return self.viewer is not None and self.viewer.poll() is None

    def action_viewer(self):
        if self.viewer_running():
            return self.say('viewer window is already open')
        VIEWER_LOG.parent.mkdir(parents=True, exist_ok=True)
        env = dict(os.environ, PYGAME_HIDE_SUPPORT_PROMPT='1')
        self.viewer = subprocess.Popen([sys.executable, os.path.abspath(__file__), 'viewer'], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=open(VIEWER_LOG, 'w'), text=True, bufsize=1, env=env,
                                       start_new_session=True)
        self.sent = None
        threading.Thread(target=self._read_viewer, args=(self.viewer,), daemon=True).start()
        self.say('viewer window opened: share the [b]"Simple Stream"[/] window in your meeting')
        self.push_stage()

    def _read_viewer(self, proc):
        for line in proc.stdout:
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            if 'status' in msg:
                self.vstatus = msg['status']
            if 'focus' in msg:  # someone clicked a tile in the viewer
                self.call_from_thread(self.viewer_focus, msg['focus'])
        proc.wait()
        self.vstatus = {}
        if self.quitting:
            return
        if proc.returncode:
            self.call_from_thread(self.say, f'[red]viewer stopped (exit {proc.returncode}), see {VIEWER_LOG}')
        else:
            self.call_from_thread(self.say, 'viewer window closed, press [b]v[/] to reopen')

    def viewer_focus(self, sid):
        self.focus = sid
        if self.sent:
            self.sent['focus'] = sid  # the viewer already knows
        self.render_table()

    def toggle_index(self, row):
        if 0 <= row < len(self.devices):
            self.table.move_cursor(row=row, animate=False)
            self.toggle(self.devices[row])

    def toggle(self, dev):
        if dev.id in self.stage:
            self.stage.remove(dev.id)
            if self.focus == dev.id:
                self.focus = None
            self.say(f'{self.label(dev)} left the stage')
        else:
            self.stage.append(dev.id)
            self.say(f'{self.label(dev)} is on stage')
        self.changed()

    def solo(self, dev):
        self.stage, self.focus = [dev.id], None
        self.say(f'showing only {self.label(dev)}')
        self.changed()

    def action_toggle(self):
        if dev := self.current():
            self.toggle(dev)

    def action_solo(self):
        if dev := self.current():
            self.solo(dev)

    def action_solo_number(self, n):
        if n <= len(self.devices):
            self.table.move_cursor(row=n - 1, animate=False)
            self.solo(self.devices[n - 1])

    def action_fill(self):
        if dev := self.current():
            if dev.id not in self.stage:
                self.stage.append(dev.id)
            self.focus = dev.id
            self.changed()

    def action_grid(self):
        self.focus = None
        self.changed()

    def action_clear(self):
        self.stage, self.focus = [], None
        self.say('stage cleared')
        self.changed()

    # --- dialogs -------------------------------------------------------------------------
    def action_rename(self):
        dev = self.current()
        if not dev:
            return

        def done(name):
            if name is None:
                return
            if name and name != dev.name:
                self.config['names'][dev.id] = name
            else:
                self.config['names'].pop(dev.id, None)
            self.save()
            self.row_ids = None  # re-sort
            self.tick()

        self.push_screen(Prompt(f'Name for {dev.host or dev.addr} (empty = device default)',
                                self.name_of(dev), 'e.g. Face detection'), done)

    def action_add(self):
        def done(addr):
            if addr:
                addr = self.discovery.add(addr)
                if addr not in self.config['hosts']:
                    self.config['hosts'].append(addr)
                    self.save()
                self.say(f'added {addr}, it will show up as soon as it answers')

        self.push_screen(Prompt('Device IP address (only needed if it is not found automatically)', '',
                                '192.168.1.50'), done)

    def action_rescan(self):
        self.say('scanning the local network…')
        self.discovery.scan()

    def action_quit(self):
        self.quitting = True
        if self.viewer_running():
            self.viewer.stdin.close()
        self.exit()



# === command line =========================================================================
def load_config():
    config = {'names': {}, 'hosts': []}
    try:
        config.update(json.loads(CONFIG.read_text()))
    except (OSError, ValueError):
        pass
    return config


def discover(seconds):
    config = load_config()
    d = Discovery()
    d.start(config['hosts'])
    time.sleep(seconds)
    devices, _ = d.snapshot()
    names = config['names']
    return sorted(devices, key=lambda x: (names.get(x.id) or x.name).lower()), names


def cmd_list():
    print('looking for devices…', file=sys.stderr)
    devices, names = discover(4)
    if not devices:
        print('no devices found. Install the client on each device:\n  ' + INSTALL)
        return 1
    rows = [('#', 'DEVICE', 'HOST', 'ADDRESS', 'MODEL', 'STATUS')]
    for i, d in enumerate(devices, 1):
        rows.append((str(i), names.get(d.id) or d.name, d.host, d.addr,
                     d.model.replace('NVIDIA ', '').replace(' Developer Kit', '')[:24], d.warn or 'online'))
    widths = [max(len(r[c]) for r in rows) for c in range(len(rows[0]))]
    for r in rows:
        print('  '.join(v.ljust(w) for v, w in zip(r, widths)).rstrip())
    return 0


def cmd_show(targets):
    if not targets:
        print('usage: simplestream show DEVICE...   (name, hostname or IP; see: simplestream list)')
        return 2
    devices, names = discover(3)
    streams = []
    for t in targets:
        low = t.lower()
        match = [d for d in devices if low in ((names.get(d.id) or d.name).lower(), d.host.lower(), d.ip, d.addr)]
        match = match or [d for d in devices if low in (names.get(d.id) or d.name).lower()]
        if match:
            d = match[0]
            streams.append({'id': d.id, 'name': names.get(d.id) or d.name, 'addr': d.addr})
        elif t[:1].isdigit():  # an IP nobody announced: try it directly
            addr = t if ':' in t else f'{t}:{STREAM_PORT}'
            streams.append({'id': addr, 'name': t, 'addr': addr})
        else:
            print(f'device "{t}" not found (see: simplestream list)')
            return 1
    print('showing ' + ', '.join(s['name'] for s in streams) + '  (close the window to stop)')
    run_viewer(controlled=False, streams=streams)
    return 0


def run_viewer(controlled=True, streams=None):
    viewer = Viewer(controlled)
    if streams:
        viewer._apply({'streams': streams})
    try:
        viewer.run()
    finally:
        for s in viewer.streams:
            s.stop()
        pygame.quit()


def cmd_uninstall():
    shutil.rmtree(DATA, ignore_errors=True)
    for p in (HOME / '.local' / 'bin' / 'simplestream', HOME / '.local' / 'share' / 'applications' / 'simplestream.desktop'):
        if p.exists() or p.is_symlink():
            p.unlink()
    link = Path('/usr/local/bin/simplestream')
    if link.is_symlink():
        subprocess.call(['sudo', 'rm', '-f', str(link)])
    print('Simple Stream removed (device names in ~/.config/simplestream were kept)')
    return 0


def main():
    cmd, args = (sys.argv[1], sys.argv[2:]) if len(sys.argv) > 1 else ('', [])
    if cmd == '':
        SimpleStream().run()
    elif cmd == 'viewer':  # started by the picker
        run_viewer()
    elif cmd == 'list':
        sys.exit(cmd_list())
    elif cmd == 'show':
        sys.exit(cmd_show(args))
    elif cmd == 'uninstall':
        sys.exit(cmd_uninstall())
    elif cmd in ('help', '-h', '--help'):
        print(USAGE)
    else:
        print(USAGE, file=sys.stderr)
        sys.exit(2)


if __name__ == '__main__':
    main()
PYTHON
# ---------------------------------------------------------------------------------------

cat > "$HOME/.local/bin/simplestream" <<EOF
#!/bin/sh
exec "$APP/venv/bin/python" "$APP/simplestream.py" "\$@"
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
if ! command -v simplestream >/dev/null; then  # ~/.local/bin is not on PATH yet
  sudo ln -sf "$HOME/.local/bin/simplestream" /usr/local/bin/simplestream || true
fi

# let the devices' beacons in if a firewall is running
if command -v ufw >/dev/null && sudo ufw status 2>/dev/null | grep -q 'Status: active'; then
  sudo ufw allow 47800/udp >/dev/null && ok "firewall (ufw): allowed 47800/udp"
fi
if command -v firewall-cmd >/dev/null && sudo firewall-cmd --state >/dev/null 2>&1; then
  sudo firewall-cmd -q --permanent --add-port=47800/udp && sudo firewall-cmd -q --reload
fi

ok "installed"
echo
"$APP/venv/bin/python" "$APP/simplestream.py" help
