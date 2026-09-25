"""Finds Simple Stream clients on the LAN, LocalSend style.

1. Listen for the clients' UDP beacons (multicast + broadcast) on every interface.
2. Fallback for networks that block those: probe http://<ip>:47801/info across
   the local subnets, then keep polling whatever answered (and manually added IPs).
"""
import fcntl
import ipaddress
import json
import socket
import struct
import threading
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor

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
