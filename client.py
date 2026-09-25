#!/usr/bin/env python3
"""Simple Stream client: makes this device's screen available on the LAN.

Idle it is just a sleeping process that sends a tiny "I'm here" UDP beacon every
2 s (multicast + broadcast, like LocalSend).  Screen capture only runs while the
server is connected to  http://<device>:47801/stream  (raw H.264).  /info returns
the beacon JSON.

Python 3.6+ (Jetson Nano / JetPack 4), standard library only.  Needs ffmpeg; on
Jetson it uses the hardware encoder through GStreamer and falls back to ffmpeg.
Settings come from environment variables (see /etc/simplestream.conf).
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
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn

GROUP, DISCOVERY_PORT = '224.0.0.177', 47800
PORT = int(os.environ.get('SS_PORT') or 47801)
NAME = os.environ.get('SS_NAME') or socket.gethostname()
FPS = int(os.environ.get('SS_FPS') or 30)
MAX_W, MAX_H = map(int, (os.environ.get('SS_MAX_SIZE') or '1920x1080').split('x'))
KBPS = int(os.environ.get('SS_KBPS') or 8000)
ENCODER = os.environ.get('SS_ENCODER') or 'auto'   # auto | jetson | x264
MAX_VIEWERS = 3
DEVNULL = subprocess.DEVNULL


def log(*args):
    print(*args, file=sys.stderr, flush=True)


def read(path):
    try:
        with open(path) as f:
            return f.read().strip('\0 \n')
    except OSError:
        return ''


def device_id():
    """Stable id: MAC of the first physical network card (survives reboots and renames)."""
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
    # never duplicate frames when the CPU can't keep up (that only makes it slower)
    cmd += FPS_MODE + ['-flush_packets', '1', '-f', 'h264', '-']
    return cmd


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


FPS_MODE = ffmpeg_fps_mode() if shutil.which('ffmpeg') else []
if ENCODER == 'jetson' or ENCODER == 'auto' and gst_has('ximagesrc', 'nvvidconv', 'nvv4l2h264enc'):
    ENCODERS = [jetson_cmd, ffmpeg_cmd]
else:
    ENCODERS = [ffmpeg_cmd]


def info():
    env = x_session()
    warn = ''
    if not env:
        warn = 'no desktop session (log in on the device)'
    elif env.get('XDG_SESSION_TYPE') == 'wayland' or env.get('WAYLAND_DISPLAY'):
        warn = 'Wayland desktop: log in with "Ubuntu on Xorg"'
    return {'app': 'simplestream', 'id': ID, 'name': NAME, 'host': HOST, 'model': MODEL, 'port': PORT,
            'encoder': 'jetson' if ENCODERS[0] is jetson_cmd else 'x264', 'viewers': viewers, 'warn': warn}


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
                return self.reply(500, 'Screen capture failed - check: journalctl -u simplestream')
            log('streaming to %s' % self.client_address[0])
            self.send_response(200)
            self.send_header('Content-Type', 'video/h264')
            self.end_headers()
            self.connection.settimeout(10)  # don't hang forever if the server vanishes
            while data:
                self.wfile.write(data)
                data = os.read(proc.stdout.fileno(), 1 << 16)
        except OSError:
            pass  # server disconnected
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


def main():
    if not shutil.which('ffmpeg'):
        log('warning: ffmpeg is not installed')
    threading.Thread(target=beacon, daemon=True).start()
    server = Server(('', PORT), Handler)
    log('Simple Stream client "%s" (%s) on port %d, encoder: %s' % (NAME, ID, PORT, info()['encoder']))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == '__main__':
    main()
