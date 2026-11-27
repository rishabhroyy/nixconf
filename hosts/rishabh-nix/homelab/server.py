#!/usr/bin/env python3
"""Homelab dashboard: machine stats + Windows/power controls.

Real mode (on rishabh-nix, see homelab.nix) reads /proc, /sys, systemd and
/run/homelab/state.json, and acts through `systemctl` (polkit allows exactly
the units it uses). Demo mode fakes all of it, for previewing the design:

    python3 hosts/rishabh-nix/homelab/server.py --demo --port 8080
    python3 hosts/rishabh-nix/homelab/server.py --demo --demo-fail   # start fails
"""
import argparse
import glob
import json
import math
import os
import random
import re
import socket
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
STATE_FILE = "/run/homelab/state.json"
ACTIONS = {
    "windows-start": ["systemctl", "start", "--no-block", "win11.service"],
    "windows-stop": ["systemctl", "stop", "--no-block", "win11.service"],
    "reboot": ["systemctl", "start", "--no-block", "reboot.target"],
    "poweroff": ["systemctl", "start", "--no-block", "poweroff.target"],
    "baremetal": ["systemctl", "start", "--no-block", "homelab-baremetal.service"],
    "display-next": None,  # handled here: picks the kiosk's monitor
}


def next_output(outputs, current):
    """The monitor after `current`; the kiosk defaults to the first."""
    if not outputs:
        return None
    if current not in outputs:
        current = outputs[0]
    return outputs[(outputs.index(current) + 1) % len(outputs)]


def read(path, default=None):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return default


def stack_state(states):
    if any(s == "failed" for s in states):
        return "failed"
    active = sum(s == "active" for s in states)
    if active == len(states):
        return "running"
    return "stopped" if active == 0 else "partial"


def parse_systemctl_show(text):
    """`systemctl show -p Id -p ActiveState a b` -> {unit: state}."""
    out = {}
    for block in text.strip().split("\n\n"):
        fields = dict(line.split("=", 1) for line in block.splitlines() if "=" in line)
        if "Id" in fields:
            out[fields["Id"]] = fields.get("ActiveState", "unknown")
    return out


class Host:
    """Samples the real machine every 2 s in a background thread."""

    def __init__(self, config, state_dir):
        self.config = config
        self.display_file = Path(state_dir) / "display"
        self.snapshot = {}
        self.lock = threading.Lock()
        self.prev_cpu = None
        self.prev_net = None
        threading.Thread(target=self.loop, daemon=True).start()

    def loop(self):
        tick = 0
        stacks = []
        while True:
            try:
                if tick % 3 == 0:
                    stacks = self.stacks()
                snap = {
                    "host": {"name": socket.gethostname(), "uptime": float(read("/proc/uptime", "0").split()[0])},
                    "cpu": {"threads": self.cpu(), "temp": self.cpu_temp()},
                    "mem": self.mem(),
                    "gpu": self.gpu(),
                    "net": self.net(),
                    "disks": self.disks(),
                    "stacks": stacks,
                }
                with self.lock:
                    self.snapshot = snap
            except Exception as e:  # keep serving the last good sample
                print("sample failed:", e, flush=True)
            tick += 1
            time.sleep(2)

    def state(self):
        try:
            return json.loads(read(STATE_FILE, ""))
        except ValueError:
            return {"mode": "homelab", "message": "", "since": None}

    def status(self):
        with self.lock:
            return {**self.state(), **self.snapshot, "display": self.display()}

    def outputs(self):
        """Connected monitors on the GPU, named like wlroots names them (DP-1)."""
        names = []
        for status in glob.glob(f"/sys/bus/pci/devices/{self.config['gpu']}/drm/card*/card*-*/status"):
            if read(status) == "connected":
                names.append(Path(status).parent.name.split("-", 1)[1])
        return sorted(names)

    def display(self):
        outputs = self.outputs()
        current = read(self.display_file)
        return {"outputs": outputs, "current": current if current in outputs else (outputs or [None])[0]}

    def cpu(self):
        cur = {}
        for line in read("/proc/stat", "").splitlines():
            m = re.match(r"cpu(\d+)\s+(.*)", line)
            if m:
                v = list(map(int, m.group(2).split()))
                idle = v[3] + v[4]
                cur[int(m.group(1))] = (sum(v[:8]), idle)
        prev, self.prev_cpu = self.prev_cpu, cur
        if not prev:
            return [0] * len(cur)
        out = []
        for i in sorted(cur):
            total = cur[i][0] - prev.get(i, cur[i])[0]
            idle = cur[i][1] - prev.get(i, cur[i])[1]
            out.append(round(100 * (1 - idle / total), 1) if total > 0 else 0)
        return out

    def cpu_temp(self):
        for d in glob.glob("/sys/class/hwmon/hwmon*"):
            if read(f"{d}/name") == "k10temp":
                t = read(f"{d}/temp1_input")
                return round(int(t) / 1000) if t else None
        return None

    def mem(self):
        info = {}
        for line in read("/proc/meminfo", "").splitlines():
            k, v = line.split(":", 1)
            info[k] = int(v.split()[0]) * 1024  # kB -> bytes (counts get x1024 too)
        total = info.get("MemTotal", 0)
        huge = info.get("HugePages_Total", 0) // 1024 * info.get("Hugepagesize", 0)
        free = info.get("MemFree", 0)
        cache = info.get("Buffers", 0) + info.get("Cached", 0) + info.get("SReclaimable", 0)
        return {"total": total, "windows": huge, "cache": cache, "free": free,
                "used": max(0, total - free - cache - huge)}

    def gpu(self):
        dev = f"/sys/bus/pci/devices/{self.config['gpu']}"
        driver = os.path.basename(os.path.realpath(f"{dev}/driver")) if os.path.exists(f"{dev}/driver") else None
        if driver == "vfio-pci":
            return {"owner": "windows"}
        if driver != "amdgpu":
            return {"owner": "none"}
        g = {"owner": "linux"}
        for key, path in (("busy", "gpu_busy_percent"), ("vramUsed", "mem_info_vram_used"),
                          ("vramTotal", "mem_info_vram_total")):
            v = read(f"{dev}/{path}")
            g[key] = int(v) if v else None
        for h in glob.glob(f"{dev}/hwmon/hwmon*"):
            t = read(f"{h}/temp1_input")
            p = read(f"{h}/power1_average") or read(f"{h}/power1_input")
            g["temp"] = round(int(t) / 1000) if t else None
            g["power"] = round(int(p) / 1e6) if p else None
        return g

    def net(self):
        now = time.monotonic()
        cur = None
        for line in read("/proc/net/dev", "").splitlines():
            name, _, rest = line.partition(":")
            if name.strip() == "br0":
                v = rest.split()
                cur = (now, int(v[0]), int(v[8]))
        prev, self.prev_net = self.prev_net, cur
        if not (prev and cur) or cur[0] == prev[0]:
            return {"rx": 0, "tx": 0}
        dt = cur[0] - prev[0]
        return {"rx": (cur[1] - prev[1]) / dt, "tx": (cur[2] - prev[2]) / dt}

    def disks(self):
        out = []
        for mount in self.config["disks"]:
            try:
                st = os.statvfs(mount)
            except OSError:
                continue
            total = st.f_blocks * st.f_frsize
            out.append({"mount": mount, "total": total, "used": total - st.f_bfree * st.f_frsize})
        return out

    def stacks(self):
        stacks = self.config["stacks"]
        units = [u for us in stacks.values() for u in us]
        if not units:
            return []
        res = subprocess.run(["systemctl", "show", "-p", "Id", "-p", "ActiveState", *units],
                             capture_output=True, text=True, timeout=10)
        states = parse_systemctl_show(res.stdout)
        return [{"name": name, "state": stack_state([states.get(u, "unknown") for u in us])}
                for name, us in sorted(stacks.items())]

    def act(self, action):
        if action == "display-next":
            target = next_output(self.outputs(), read(self.display_file))
            if not target:
                return False, "no monitor connected"
            self.display_file.write_text(target + "\n")
            return True, ""
        res = subprocess.run(ACTIONS[action], capture_output=True, text=True, timeout=15)
        return res.returncode == 0, res.stderr.strip()


class Demo:
    """Plausible fake machine; actions walk through the real state sequence."""

    STACKS = ["copyparty", "hokago", "immich", "portainer", "samechan"]

    def __init__(self, fail):
        self.fail = fail
        self.screen = "DP-1"
        self.state = {"mode": "homelab", "message": "", "since": time.time() - 3 * 3600}
        self.t0 = time.time()
        self.lock = threading.Lock()

    def set(self, mode, message=""):
        with self.lock:
            self.state = {"mode": mode, "message": message, "since": time.time()}

    def run(self, steps):
        def go():
            for delay, mode, msg in steps:
                time.sleep(delay)
                self.set(mode, msg)
        threading.Thread(target=go, daemon=True).start()

    def act(self, action):
        mode = self.state["mode"]
        if action == "display-next":
            self.screen = next_output(["DP-1", "HDMI-A-1"], self.screen)
        if action == "windows-start" and mode in ("homelab", "error"):
            steps = [(0, "starting", "Handing the GPU to Windows"), (1.6, "starting", "Reserving memory"),
                     (1.4, "starting", "Booting Windows")]
            steps.append((2, "error", "Only 11 of 16 GB free for Windows") if self.fail else (2, "windows", ""))
            self.run(steps)
        elif action == "windows-stop" and mode in ("windows", "crashed"):
            self.run([(0, "stopping", "Shutting down Windows"), (3.5, "homelab", "")])
        return True, ""

    def status(self):
        t = time.time() - self.t0
        mode = self.state["mode"]
        win = mode in ("windows", "stopping") or (mode == "starting" and self.state["message"] == "Booting Windows")
        threads = []
        for i in range(16):
            vm_core = (i % 8) >= 4
            base = 8 + 6 * math.sin(t / 7 + i)
            if win and vm_core:
                base = 35 + 25 * math.sin(t / 3 + i * 0.7)
            elif i in (1, 9):
                base += 30 + 20 * math.sin(t / 5)  # something busy on core 1
            threads.append(round(max(0, min(100, base + random.uniform(-4, 4))), 1))
        gib = 1024 ** 3
        windows = 16 * gib if win else 0
        used = (9.5 if not win else 7.2) * gib + 0.3 * gib * math.sin(t / 11)
        cache = (14 if not win else 3.1) * gib
        total = 31.3 * gib
        return {
            **self.state,
            "host": {"name": "rishabh-nix", "uptime": 3 * 86400 + 4 * 3600 + t},
            "cpu": {"threads": threads, "temp": round(48 + 6 * math.sin(t / 13) + (12 if win else 0))},
            "mem": {"total": total, "windows": windows, "used": used, "cache": cache,
                    "free": max(0, total - windows - used - cache)},
            "gpu": {"owner": "windows"} if win else {
                "owner": "linux", "busy": max(0, round(4 + 3 * math.sin(t / 4))),
                "vramUsed": int(0.42 * gib), "vramTotal": 12 * gib, "temp": 41, "power": 9},
            "net": {"rx": abs(1.8e6 * math.sin(t / 6)) + 2e4, "tx": abs(4e5 * math.sin(t / 9)) + 1e4},
            "disks": [{"mount": "/", "total": 931 * gib, "used": 402 * gib},
                      {"mount": "/mnt/data4", "total": 3726 * gib, "used": 3120 * gib}],
            "display": {"outputs": ["DP-1", "HDMI-A-1"], "current": self.screen},
            "stacks": [{"name": n, "state": "partial" if n == "hokago" and int(t / 20) % 3 == 2 else "running"}
                       for n in self.STACKS],
        }


def allowed_host(host):
    """Reject DNS-rebinding: only this machine's names and raw IPs."""
    name = (host or "").rsplit(":", 1)[0].strip("[]").lower()
    return (name in ("localhost", "rishabh-nix")
            or re.fullmatch(r"rishabh-nix\.[a-z0-9-]+\.ts\.net|[\d.]+|[0-9a-f]*:[0-9a-f:]*", name) is not None)


def handler(backend):
    page = (HERE / "index.html").read_bytes()

    class H(BaseHTTPRequestHandler):
        def send(self, code, body, ctype="application/json"):
            if isinstance(body, (dict, list)):
                body = json.dumps(body).encode()
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def guard(self):
            if not allowed_host(self.headers.get("Host")):
                self.send(403, {"error": "unknown host"})
                return False
            return True

        def do_GET(self):
            if not self.guard():
                return
            if self.path in ("/", "/index.html"):
                self.send(200, page, "text/html; charset=utf-8")
            elif self.path == "/api/status":
                self.send(200, backend.status())
            else:
                self.send(404, {"error": "not found"})

        def do_POST(self):
            # The custom header can't be sent cross-origin without a CORS
            # preflight, which this server never approves: blocks CSRF.
            if not self.guard() or self.path != "/api/action" or self.headers.get("X-Homelab") != "1":
                return self.send(403, {"error": "forbidden"})
            try:
                length = min(int(self.headers.get("Content-Length", 0)), 1024)
                action = json.loads(self.rfile.read(length) or b"{}").get("action")
            except (ValueError, AttributeError):
                action = None
            if action not in ACTIONS:
                return self.send(400, {"error": "unknown action"})
            ok, err = backend.act(action)
            self.send(200 if ok else 500, {"ok": ok, "error": err})

        def log_message(self, fmt, *args):
            if not self.path.startswith("/api/status"):
                super().log_message(fmt, *args)

    return H


def selftest():
    assert stack_state(["active", "active"]) == "running"
    assert stack_state(["active", "inactive"]) == "partial"
    assert stack_state(["inactive"]) == "stopped"
    assert stack_state(["active", "failed"]) == "failed"
    shown = parse_systemctl_show("Id=a.service\nActiveState=active\n\nId=b.service\nActiveState=failed\n")
    assert shown == {"a.service": "active", "b.service": "failed"}
    for ok in ("127.0.0.1", "localhost:8080", "rishabh-nix", "rishabh-nix.tail1234.ts.net", "[::1]:80", "100.64.0.3"):
        assert allowed_host(ok), ok
    for bad in ("evil.com", "rishabh-nix.evil.com", "rishabh-nix.x.ts.net.evil.com", "cafe", "", None):
        assert not allowed_host(bad), bad
    assert next_output(["DP-1", "HDMI-A-1"], None) == "HDMI-A-1"
    assert next_output(["DP-1", "HDMI-A-1"], "HDMI-A-1") == "DP-1"
    assert next_output(["DP-1"], "gone") == "DP-1"
    assert next_output([], None) is None
    print("selftest ok")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--config", help="JSON from homelab.nix (real mode)")
    ap.add_argument("--demo", action="store_true", help="fake machine, for previewing the design")
    ap.add_argument("--demo-fail", action="store_true", help="demo: make Start Windows fail")
    ap.add_argument("--state-dir", default=".", help="where the chosen monitor is remembered (real mode)")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    if args.selftest:
        return selftest()
    if args.demo:
        backend = Demo(args.demo_fail)
    else:
        backend = Host(json.loads(Path(args.config).read_text()), args.state_dir)
    server = ThreadingHTTPServer(("", args.port), handler(backend))
    print(f"homelab dashboard on http://localhost:{args.port}/", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
