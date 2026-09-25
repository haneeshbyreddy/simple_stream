#!/usr/bin/env python3
"""Simple Stream viewer: the window you share in the meeting.

Shows the devices that are "on stage" in a grid.  Click a tile to fill the
window with it; click again (or Esc / right click) to go back to the grid.
Keys: 1-9 fill tile N, 0/Esc grid, F11/F fullscreen, L labels.

Driven by the TUI: JSON lines on stdin ({"streams": [...], "focus": id}),
status JSON lines on stdout.
"""
import json
import math
import os
import socket
import sys
import threading
import time

os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import av  # noqa: E402
import pygame  # noqa: E402

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
    def __init__(self):
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


if __name__ == '__main__':
    viewer = Viewer()
    try:
        viewer.run()
    finally:
        for s in viewer.streams:
            s.stop()
        pygame.quit()
