#!/usr/bin/env python3
"""Simple Stream: pick which edge device is on screen.

The terminal lists the devices found on the LAN; a separate viewer window (the
one you share in Google Meet / Zoom) shows whatever is "on stage".
"""
import json
import os
import subprocess
import sys
import threading
import time
from pathlib import Path

from rich.markup import escape
from rich.text import Text
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Vertical
from textual.screen import ModalScreen
from textual.widgets import DataTable, Footer, Header, Input, Label, RichLog, Static

from discovery import Discovery, interfaces

CONFIG = Path(os.environ.get('XDG_CONFIG_HOME') or Path.home() / '.config') / 'simplestream' / 'server.json'
VIEWER_LOG = Path(os.environ.get('XDG_CACHE_HOME') or Path.home() / '.cache') / 'simplestream' / 'viewer.log'
VIEWER = Path(__file__).with_name('viewer.py')
INSTALL = 'curl -fsSL https://raw.githubusercontent.com/haneeshbyreddy/simple_stream/main/install.sh | bash'


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
        self.config = {'names': {}, 'hosts': []}
        try:
            self.config.update(json.loads(CONFIG.read_text()))
        except (OSError, ValueError):
            pass
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
        self.viewer = subprocess.Popen([sys.executable, str(VIEWER)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
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


if __name__ == '__main__':
    SimpleStream().run()
