#!/usr/bin/env python3
"""Geofence panel helper.

Receives a walking route from the InsiderGeofence app's "Update geofence"
button, rewrites update_fake_route_here.gpx (start + end waypoints, real
timestamps, so Xcode's Debug > Simulate Location can still walk it), and
simulates the walk live: it interpolates positions at walking speed and
applies each one to the Simulator (and a physical iPhone when
pymobiledevice3 is installed). When the position first crosses into the
geofence zone — a circle of the given radius around the end location — it
logs the entry and exposes it on /status for the app to display.

Run it with:  python3 geofence_panel.py
Stop it with: Ctrl+C
"""

import functools
import importlib.util
import json
import math
import subprocess
import sys
import os
import threading
import time
from datetime import datetime, timezone, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

print = functools.partial(print, flush=True)

PORT = 8766
GPX_PATH = Path(__file__).resolve().parent / "update_fake_route_here.gpx"
DEVICE_GPX_PATH = Path(__file__).resolve().parent / "device_route.gpx"
DEVICE_PLAY_LOG = Path(__file__).resolve().parent / "device_play.log"
DEVELOPER_DIR = "/Applications/Xcode.app"
WALK_SPEED = 1.4      # m/s, normal walking pace
TICK_SECONDS = 1.0
HAS_PMD3 = importlib.util.find_spec("pymobiledevice3") is not None

GPX_TEMPLATE = """<?xml version="1.0"?>
<gpx version="1.1" creator="geofence_panel">
<wpt lat="{lat1}" lon="{lon1}">
    <time>{time1}</time>
</wpt>
<wpt lat="{lat2}" lon="{lon2}">
    <time>{time2}</time>
</wpt>
</gpx>
"""


def haversine_m(lat1, lon1, lat2, lon2):
    r = 6371000.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = math.radians(lat2 - lat1)
    dl = math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(a))


def write_gpx(lat1, lon1, lat2, lon2, duration_s):
    t0 = datetime.now(timezone.utc)
    t1 = t0 + timedelta(seconds=max(duration_s, 1))
    fmt = "%Y-%m-%dT%H:%M:%SZ"
    GPX_PATH.write_text(GPX_TEMPLATE.format(
        lat1=lat1, lon1=lon1, time1=t0.strftime(fmt),
        lat2=lat2, lon2=lon2, time2=t1.strftime(fmt),
    ))


def run(cmd, timeout=20, env=None):
    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout, env=env
        )
        return result.returncode, (result.stdout + result.stderr).strip()
    except FileNotFoundError:
        return 127, f"{cmd[0]} not found"
    except subprocess.TimeoutExpired:
        return 124, f"{cmd[0]} timed out"


BOOTED_CACHE = {"udids": [], "ts": 0.0}


def booted_udids():
    """UDIDs of all booted simulators ('booted' is ambiguous with several)."""
    now = time.time()
    if now - BOOTED_CACHE["ts"] > 10:
        env = dict(os.environ, DEVELOPER_DIR=DEVELOPER_DIR)
        code, out = run(["xcrun", "simctl", "list", "devices", "booted", "-j"],
                        env=env)
        udids = []
        if code == 0:
            try:
                for devs in json.loads(out).get("devices", {}).values():
                    udids += [d["udid"] for d in devs
                              if d.get("state") == "Booted"]
            except json.JSONDecodeError:
                pass
        BOOTED_CACHE.update(udids=udids, ts=now)
    return BOOTED_CACHE["udids"]


def apply_position(lat, lon, quiet=True):
    """Set the fake location on every booted Simulator."""
    env = dict(os.environ, DEVELOPER_DIR=DEVELOPER_DIR)
    ok = False
    for udid in booted_udids():
        code, output = run(
            ["xcrun", "simctl", "location", udid, "set", f"{lat},{lon}"], env=env
        )
        ok = ok or code == 0
        if not quiet and code != 0:
            print(f"  simctl {udid[:8]}: {output or 'failed'}")
    return ok


DEVICE_PLAY_PROC = None


def write_device_gpx(lat1, lon1, lat2, lon2):
    """Per-second track GPX for pymobiledevice3 `simulate-location play`."""
    total = haversine_m(lat1, lon1, lat2, lon2)
    steps = max(int(total / (WALK_SPEED * TICK_SECONDS)), 1)
    t0 = datetime.now(timezone.utc)
    fmt = "%Y-%m-%dT%H:%M:%SZ"
    points = []
    for i in range(steps + 1):
        f = i / steps
        lat = lat1 + (lat2 - lat1) * f
        lon = lon1 + (lon2 - lon1) * f
        t = (t0 + timedelta(seconds=i * TICK_SECONDS)).strftime(fmt)
        points.append(
            f'<trkpt lat="{lat}" lon="{lon}"><time>{t}</time></trkpt>'
        )
    DEVICE_GPX_PATH.write_text(
        '<?xml version="1.0"?>\n'
        '<gpx version="1.1" creator="geofence_panel">\n'
        '<trk><trkseg>\n' + "\n".join(points) + '\n</trkseg></trk>\n</gpx>\n'
    )


def start_device_play(lat1, lon1, lat2, lon2):
    """Replay the walk on a physical iPhone via pymobiledevice3 (iOS 17+).

    Needs the phone paired (USB at least once) and the tunnel daemon running:
        sudo python3 -m pymobiledevice3 remote tunneld
    """
    global DEVICE_PLAY_PROC
    if not HAS_PMD3:
        return "pymobiledevice3 not installed — device skipped"
    if DEVICE_PLAY_PROC and DEVICE_PLAY_PROC.poll() is None:
        DEVICE_PLAY_PROC.terminate()
    write_device_gpx(lat1, lon1, lat2, lon2)
    log = DEVICE_PLAY_LOG.open("w")
    DEVICE_PLAY_PROC = subprocess.Popen(
        [sys.executable, "-m", "pymobiledevice3", "developer", "dvt",
         "simulate-location", "play", str(DEVICE_GPX_PATH), "--tunnel", ""],
        stdout=log, stderr=log,
    )
    time.sleep(3)
    if DEVICE_PLAY_PROC.poll() is not None:
        hint = DEVICE_PLAY_LOG.read_text().strip().splitlines()
        hint = hint[-1] if hint else "unknown error"
        print("  device: play exited immediately — is the iPhone plugged in and "
              "is `sudo python3 -m pymobiledevice3 remote tunneld` running? "
              f"({hint})")
        return "device play failed (see device_play.log)"
    print("  device: replaying route on physical iPhone")
    return "replaying on physical iPhone"


class WalkState:
    def __init__(self):
        self.lock = threading.Lock()
        self.cancel = threading.Event()
        self.thread = None
        self.reset()

    def reset(self):
        self.walking = False
        self.entered = False
        self.lat = None
        self.lon = None
        self.remaining_m = None
        self.radius = None
        self.device = None

    def set_device(self, note):
        with self.lock:
            self.device = note

    def snapshot(self):
        with self.lock:
            return {
                "walking": self.walking,
                "entered": self.entered,
                "lat": self.lat,
                "lon": self.lon,
                "remaining_m": self.remaining_m,
                "radius": self.radius,
                "device": self.device,
            }


STATE = WalkState()


def walk(lat1, lon1, lat2, lon2, radius, cancel):
    total = haversine_m(lat1, lon1, lat2, lon2)
    steps = max(int(total / (WALK_SPEED * TICK_SECONDS)), 1)
    print(f"  Walk started: {total:.0f}m in ~{steps * TICK_SECONDS:.0f}s, "
          f"zone radius {radius:.0f}m around destination")

    for i in range(steps + 1):
        if cancel.is_set():
            print("  Walk cancelled (new route received).")
            return
        f = i / steps
        lat = lat1 + (lat2 - lat1) * f
        lon = lon1 + (lon2 - lon1) * f
        remaining = haversine_m(lat, lon, lat2, lon2)
        apply_position(lat, lon)
        with STATE.lock:
            STATE.lat, STATE.lon = lat, lon
            STATE.remaining_m = remaining
            if not STATE.entered and remaining <= radius:
                STATE.entered = True
                print(f"  >>> ENTERED GEOFENCE ZONE at {lat:.6f}, {lon:.6f} "
                      f"({remaining:.0f}m from destination) <<<")
        if i < steps:
            time.sleep(TICK_SECONDS)

    with STATE.lock:
        STATE.walking = False
    print(f"  Walk finished at {lat2}, {lon2}.")


def start_walk(lat1, lon1, lat2, lon2, radius):
    STATE.cancel.set()
    if STATE.thread and STATE.thread.is_alive():
        STATE.thread.join(timeout=TICK_SECONDS + 5)
    STATE.cancel = threading.Event()
    with STATE.lock:
        STATE.reset()
        STATE.walking = True
        STATE.radius = radius
        STATE.lat, STATE.lon = lat1, lon1
        STATE.entered = radius >= haversine_m(lat1, lon1, lat2, lon2)
    STATE.thread = threading.Thread(
        target=walk, args=(lat1, lon1, lat2, lon2, radius, STATE.cancel),
        daemon=True,
    )
    STATE.thread.start()


def stop_all():
    """Cancel the walk and clear the fake location everywhere."""
    global DEVICE_PLAY_PROC
    STATE.cancel.set()
    if STATE.thread and STATE.thread.is_alive():
        STATE.thread.join(timeout=TICK_SECONDS + 5)
    if DEVICE_PLAY_PROC and DEVICE_PLAY_PROC.poll() is None:
        DEVICE_PLAY_PROC.terminate()
        DEVICE_PLAY_PROC = None
    env = dict(os.environ, DEVELOPER_DIR=DEVELOPER_DIR)
    for udid in booted_udids():
        code, output = run(["xcrun", "simctl", "location", udid, "clear"], env=env)
        if code == 0:
            print(f"  simulator {udid[:8]}: fake location cleared")
    if HAS_PMD3:
        def clear_device():
            code, _ = run(
                [sys.executable, "-m", "pymobiledevice3", "developer", "dvt",
                 "simulate-location", "clear", "--tunnel", ""],
                timeout=30,
            )
            note = ("fake location cleared" if code == 0
                    else "clear failed (phone connected and tunneld running?)")
            print(f"  device: {note}")
            STATE.set_device(note)
        threading.Thread(target=clear_device, daemon=True).start()
    with STATE.lock:
        walking = STATE.walking
        STATE.reset()
    print("  Fake location stopped." + (" (walk cancelled)" if walking else ""))


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        if "/status" not in (args[0] if args else ""):
            print(f"[{datetime.now().strftime('%H:%M:%S')}] {fmt % args}")

    def send_json(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/status":
            self.send_json(200, {"ok": True, **STATE.snapshot()})
            return
        gpx = GPX_PATH.read_text() if GPX_PATH.exists() else "(missing)"
        self.send_json(200, {"ok": True, "gpx_path": str(GPX_PATH), "gpx": gpx,
                             **STATE.snapshot()})

    def do_POST(self):
        if self.path == "/stop":
            stop_all()
            self.send_json(200, {"ok": True, "stopped": True})
            return
        if self.path != "/update":
            self.send_json(404, {"ok": False, "error": "unknown endpoint"})
            return
        try:
            length = int(self.headers.get("Content-Length", 0))
            data = json.loads(self.rfile.read(length))
            lat1, lon1 = float(data["start_lat"]), float(data["start_lon"])
            lat2, lon2 = float(data["end_lat"]), float(data["end_lon"])
            radius = float(data["radius"])
            for lat, lon in ((lat1, lon1), (lat2, lon2)):
                if not (-90 <= lat <= 90 and -180 <= lon <= 180):
                    raise ValueError("coordinates out of range")
            if radius <= 0:
                raise ValueError("radius must be positive")
        except (ValueError, KeyError, TypeError, json.JSONDecodeError) as exc:
            self.send_json(400, {"ok": False, "error": f"bad request: {exc}"})
            return

        total = haversine_m(lat1, lon1, lat2, lon2)
        duration = total / WALK_SPEED
        write_gpx(lat1, lon1, lat2, lon2, duration)
        print(f"  GPX updated: {lat1},{lon1} -> {lat2},{lon2} "
              f"({total:.0f}m, ~{duration:.0f}s walk, zone {radius:.0f}m)")
        start_walk(lat1, lon1, lat2, lon2, radius)
        threading.Thread(
            target=lambda: STATE.set_device(
                start_device_play(lat1, lon1, lat2, lon2)),
            daemon=True,
        ).start()
        self.send_json(200, {
            "ok": True,
            "distance_m": round(total),
            "duration_s": round(duration),
            "applied": f"walking {total:.0f}m, ~{duration:.0f}s",
        })


def main():
    print(f"Geofence panel helper on http://0.0.0.0:{PORT}")
    print(f"GPX file: {GPX_PATH}")
    print(f"Walk speed: {WALK_SPEED} m/s")
    print("Waiting for 'Update geofence' from the app... (Ctrl+C to stop)")
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")


if __name__ == "__main__":
    main()
