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

Run it with:  python3 geofence_panel.py          (loopback only)
              python3 geofence_panel.py --lan    (also reachable from the LAN,
                                                  needed for a physical iPhone)
Stop it with: Ctrl+C

Security model
--------------
* Binds loopback only (127.0.0.1 and ::1) unless --lan is passed. Simulator
  work never needs --lan.
* Every request must carry the shared token in the X-Geofence-Token header.
  The token lives in .geofence_token (gitignored, mode 600) and is printed at
  startup; type it into the app once. Requiring a *custom* header also forces
  a CORS preflight, so a random web page cannot drive this server.
* The Host header is validated, which blocks DNS-rebinding attacks.
* Request bodies, interpolation steps and radius are capped and sockets time
  out, so a single request cannot exhaust memory, threads or CPU. Distance
  itself is not limited — long routes are compressed, see route_steps().

Caveat: traffic is plain HTTP. With --lan, anyone sniffing that network can
read the coordinates you send — including your real position if you use the
"Go to original location" button. Avoid --lan on untrusted Wi-Fi.
"""

import functools
import hmac
import importlib.util
import ipaddress
import json
import math
import secrets
import socket
import subprocess
import sys
import os
import threading
import time
from datetime import datetime, timezone, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

print = functools.partial(print, flush=True)

HERE = Path(__file__).resolve().parent
PORT = 8766
GPX_PATH = HERE / "update_fake_route_here.gpx"
DEVICE_GPX_PATH = HERE / "device_route.gpx"
DEVICE_PLAY_LOG = HERE / "device_play.log"
TOKEN_PATH = HERE / ".geofence_token"
DEVELOPER_DIR = "/Applications/Xcode.app"
WALK_SPEED = 1.4          # m/s, normal walking pace
RUN_SPEED = 10.0          # m/s, the app's "Run" button
MAX_SPEED = 1000.0        # sanity bound on a client-supplied speed
TICK_SECONDS = 1.0
MAX_BODY_BYTES = 8 * 1024
MAX_STEPS = 600           # bounds memory/CPU per request; see route_steps()
MAX_RADIUS_M = 100_000
SOCKET_TIMEOUT = 10       # seconds; stops slow clients from pinning threads
LAN_MODE = "--lan" in sys.argv
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


def load_token():
    """Stable shared secret: env var if set, otherwise a file we create once."""
    env = os.environ.get("GEOFENCE_TOKEN", "").strip()
    if env:
        return env
    if TOKEN_PATH.exists():
        existing = TOKEN_PATH.read_text().strip()
        if existing:
            return existing
    token = secrets.token_urlsafe(18)
    TOKEN_PATH.write_text(token + "\n")
    TOKEN_PATH.chmod(0o600)
    return token


TOKEN = load_token()


def haversine_m(lat1, lon1, lat2, lon2):
    r = 6371000.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = math.radians(lat2 - lat1)
    dl = math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(a))


def route_steps(total_m, speed=WALK_SPEED):
    """How many one-second ticks to split a route into.

    Short routes keep the requested pace (1.4 m/s walking, 10 running).
    Longer ones are compressed into MAX_STEPS ticks (bigger jumps per tick) rather than being refused:
    that keeps intercontinental routes usable while still bounding what one
    request can cost us, since memory and subprocess count scale with steps,
    not with distance. For an instant jump, set the start equal to the end.
    """
    natural = max(int(total_m / (speed * TICK_SECONDS)), 1)
    return min(natural, MAX_STEPS)


def route_points(lat1, lon1, lat2, lon2, speed, return_to_start=False):
    """The full list of per-tick positions for a route.

    A round trip walks out to the destination and back to the start, which is
    what produces both an enter and an exit event for a real geofence.
    """
    def leg(a, b):
        steps = route_steps(haversine_m(a[0], a[1], b[0], b[1]), speed)
        return [(a[0] + (b[0] - a[0]) * i / steps,
                 a[1] + (b[1] - a[1]) * i / steps) for i in range(steps + 1)]

    start, end = (lat1, lon1), (lat2, lon2)
    points = leg(start, end)
    if return_to_start:
        points += leg(end, start)[1:]   # skip the duplicated turnaround point
    return points


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
DEVICE_LOCK = threading.Lock()


def write_device_gpx(lat1, lon1, lat2, lon2, speed=WALK_SPEED, return_to_start=False):
    """Per-second track GPX for pymobiledevice3 `simulate-location play`."""
    t0 = datetime.now(timezone.utc)
    fmt = "%Y-%m-%dT%H:%M:%SZ"
    points = []
    for i, (lat, lon) in enumerate(
            route_points(lat1, lon1, lat2, lon2, speed, return_to_start)):
        t = (t0 + timedelta(seconds=i * TICK_SECONDS)).strftime(fmt)
        points.append(
            f'<trkpt lat="{lat}" lon="{lon}"><time>{t}</time></trkpt>'
        )
    DEVICE_GPX_PATH.write_text(
        '<?xml version="1.0"?>\n'
        '<gpx version="1.1" creator="geofence_panel">\n'
        '<trk><trkseg>\n' + "\n".join(points) + '\n</trkseg></trk>\n</gpx>\n'
    )


def start_device_play(lat1, lon1, lat2, lon2, speed=WALK_SPEED,
                      return_to_start=False):
    """Replay the walk on a physical iPhone via pymobiledevice3 (iOS 17+).

    Needs the phone paired (USB at least once) and the tunnel daemon running:
        sudo python3 -m pymobiledevice3 remote tunneld
    """
    global DEVICE_PLAY_PROC
    if not HAS_PMD3:
        return "pymobiledevice3 not installed — device skipped"
    write_device_gpx(lat1, lon1, lat2, lon2, speed, return_to_start)
    with DEVICE_LOCK:
        if DEVICE_PLAY_PROC and DEVICE_PLAY_PROC.poll() is None:
            DEVICE_PLAY_PROC.terminate()
        # `play` takes a few seconds to spin up, which would leave the phone
        # at its previous position; set the start coordinate first so it
        # jumps there immediately and `play` walks on from there.
        run([sys.executable, "-m", "pymobiledevice3", "developer", "dvt",
             "simulate-location", "set", "--tunnel", "", "--",
             str(lat1), str(lon1)], timeout=25)
        with DEVICE_PLAY_LOG.open("w") as log:
            DEVICE_PLAY_PROC = subprocess.Popen(
                [sys.executable, "-m", "pymobiledevice3", "developer", "dvt",
                 "simulate-location", "play", str(DEVICE_GPX_PATH),
                 "--tunnel", ""],
                stdout=log, stderr=log,
            )
        proc = DEVICE_PLAY_PROC
    time.sleep(3)
    if proc.poll() is not None:
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
        self.end = None        # (lat, lon) so resume knows where to continue
        self.speed = None
        self.exited = False
        self.leg = None

    def set_device(self, note):
        with self.lock:
            self.device = note

    def snapshot(self):
        with self.lock:
            return {
                "walking": self.walking,
                "entered": self.entered,
                "exited": self.exited,
                "leg": self.leg,
                "lat": self.lat,
                "lon": self.lon,
                "remaining_m": self.remaining_m,
                "radius": self.radius,
                "device": self.device,
                "paused": PAUSE.is_set(),
                "end": self.end,
                "speed": self.speed,
            }


STATE = WalkState()
PAUSE = threading.Event()


def walk(lat1, lon1, lat2, lon2, radius, speed, return_to_start, cancel):
    """Move along the route, reporting entry into and exit from the zone.

    The zone is the circle of `radius` around the destination, so distance is
    always measured to (lat2, lon2) even on the way back.
    """
    points = route_points(lat1, lon1, lat2, lon2, speed, return_to_start)
    total = haversine_m(lat1, lon1, lat2, lon2)
    mode = "Run" if speed > WALK_SPEED else "Walk"
    effective = total / max(route_steps(total, speed) * TICK_SECONDS, 1)
    pace = (f"{effective:.1f} m/s (compressed from {speed:.1f})"
            if effective > speed * 1.05 else f"{speed:.1f} m/s")
    print(f"  {mode} started: {total:.0f}m at {pace}, zone radius {radius:.0f}m"
          + (" (out and back)" if return_to_start else ""))

    turnaround = len(route_points(lat1, lon1, lat2, lon2, speed)) - 1
    for i, (lat, lon) in enumerate(points):
        if cancel.is_set():
            print("  Walk cancelled (new route received).")
            return
        while PAUSE.is_set():
            if cancel.is_set():
                return
            time.sleep(0.2)

        remaining = haversine_m(lat, lon, lat2, lon2)
        apply_position(lat, lon)
        with STATE.lock:
            STATE.lat, STATE.lon = lat, lon
            STATE.remaining_m = remaining
            STATE.leg = "back" if i > turnaround else "out"
            if not STATE.entered and remaining <= radius:
                STATE.entered = True
                print(f"  >>> ENTERED ZONE at {lat:.6f}, {lon:.6f} "
                      f"({remaining:.0f}m from centre) <<<")
            elif STATE.entered and not STATE.exited and remaining > radius:
                STATE.exited = True
                print(f"  <<< EXITED ZONE at {lat:.6f}, {lon:.6f} "
                      f"({remaining:.0f}m from centre) >>>")
        if i < len(points) - 1:
            time.sleep(TICK_SECONDS)

    with STATE.lock:
        STATE.walking = False
    print(f"  {mode} finished.")


def start_walk(lat1, lon1, lat2, lon2, radius, speed, return_to_start=False):
    STATE.cancel.set()
    if STATE.thread and STATE.thread.is_alive():
        STATE.thread.join(timeout=TICK_SECONDS + 5)
    STATE.cancel = threading.Event()
    # Land on the start coordinate synchronously, before this call returns, so
    # the device is already there by the time the app sees its response. The
    # walk then continues from that point instead of easing into it.
    PAUSE.clear()
    apply_position(lat1, lon1)
    with STATE.lock:
        STATE.reset()
        STATE.walking = True
        STATE.end = (lat2, lon2)
        STATE.speed = speed
        STATE.radius = radius
        STATE.lat, STATE.lon = lat1, lon1
        STATE.entered = radius >= haversine_m(lat1, lon1, lat2, lon2)
    STATE.thread = threading.Thread(
        target=walk,
        args=(lat1, lon1, lat2, lon2, radius, speed, return_to_start, STATE.cancel),
        daemon=True,
    )
    STATE.thread.start()


def stop_all():
    """Cancel the walk and clear the fake location everywhere."""
    global DEVICE_PLAY_PROC
    STATE.cancel.set()
    if STATE.thread and STATE.thread.is_alive():
        STATE.thread.join(timeout=TICK_SECONDS + 5)
    with DEVICE_LOCK:
        if DEVICE_PLAY_PROC and DEVICE_PLAY_PROC.poll() is None:
            DEVICE_PLAY_PROC.terminate()
            DEVICE_PLAY_PROC = None
    env = dict(os.environ, DEVELOPER_DIR=DEVELOPER_DIR)
    for udid in booted_udids():
        code, _ = run(["xcrun", "simctl", "location", udid, "clear"], env=env)
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


def toggle_pause(paused):
    """Freeze or continue the route without clearing the fake location.

    The simulator side just stops advancing. The device side is a separate
    `simulate-location play` process that cannot be paused, so we kill it
    (leaving the phone at its last point) and, on resume, replay what is
    left of the route from wherever we currently are.
    """
    global DEVICE_PLAY_PROC
    snap = STATE.snapshot()
    if not snap["walking"]:
        return {"paused": False, "note": "no route is running"}
    if paused:
        PAUSE.set()
        with DEVICE_LOCK:
            if DEVICE_PLAY_PROC and DEVICE_PLAY_PROC.poll() is None:
                DEVICE_PLAY_PROC.terminate()
                DEVICE_PLAY_PROC = None
        print(f"  Paused at {snap['lat']:.6f}, {snap['lon']:.6f}.")
    else:
        PAUSE.clear()
        end, speed = snap.get("end"), snap.get("speed")
        if HAS_PMD3 and end and snap["lat"] is not None:
            threading.Thread(
                target=lambda: STATE.set_device(start_device_play(
                    snap["lat"], snap["lon"], end[0], end[1],
                    speed or WALK_SPEED)),
                daemon=True).start()
        print("  Resumed.")
    return {"paused": paused}


def host_allowed(header):
    """Anti-DNS-rebinding check.

    A rebinding attack keeps the attacker's own domain in the Host header, so
    accepting only localhost (plus private IP literals in --lan mode) means a
    rebound request is refused even though it reaches our socket.
    """
    if not header:
        return False
    host = header.rsplit(":", 1)[0].strip("[]").lower()
    if host in ("localhost", "127.0.0.1", "::1"):
        return True
    if not LAN_MODE:
        return False
    try:
        return ipaddress.ip_address(host).is_private
    except ValueError:
        return host.endswith(".local")


class Handler(BaseHTTPRequestHandler):
    timeout = SOCKET_TIMEOUT

    def log_message(self, fmt, *args):
        # The request line is attacker-controlled, so escape it before printing:
        # otherwise a crafted request can write raw terminal escape sequences
        # to the console and rewrite what you see.
        safe = (fmt % args).encode("unicode_escape").decode("ascii", "replace")
        if "/status" not in safe:
            print(f"[{datetime.now().strftime('%H:%M:%S')}] {safe}")

    def send_json(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)

    def gate(self):
        """Checks every request must pass. Returns True when allowed."""
        if not host_allowed(self.headers.get("Host", "")):
            self.send_json(403, {"ok": False, "error": "host not allowed"})
            return False
        supplied = self.headers.get("X-Geofence-Token", "")
        if not hmac.compare_digest(supplied, TOKEN):
            self.send_json(401, {
                "ok": False,
                "error": "unauthorized — copy the token geofence_panel.py "
                         "printed at startup into the app's Token field",
            })
            return False
        return True

    def do_GET(self):
        if not self.gate():
            return
        if self.path in ("/status", "/"):
            self.send_json(200, {"ok": True, **STATE.snapshot()})
            return
        self.send_json(404, {"ok": False, "error": "unknown endpoint"})

    def do_POST(self):
        if not self.gate():
            return
        if self.path in ("/pause", "/resume"):
            self.send_json(200, {"ok": True, **toggle_pause(self.path == "/pause")})
            return
        if self.path == "/stop":
            stop_all()
            self.send_json(200, {"ok": True, "stopped": True})
            return
        if self.path != "/update":
            self.send_json(404, {"ok": False, "error": "unknown endpoint"})
            return

        ctype = self.headers.get("Content-Type", "").split(";")[0].strip().lower()
        if ctype != "application/json":
            self.send_json(415, {"ok": False,
                                 "error": "Content-Type must be application/json"})
            return
        try:
            length = int(self.headers.get("Content-Length", ""))
        except ValueError:
            self.send_json(411, {"ok": False, "error": "Content-Length required"})
            return
        if length < 0 or length > MAX_BODY_BYTES:
            # Refuse before reading, so a huge claimed body costs us nothing.
            self.send_json(413, {"ok": False, "error": "request body too large"})
            return

        try:
            data = json.loads(self.rfile.read(length))
            lat1, lon1 = float(data["start_lat"]), float(data["start_lon"])
            lat2, lon2 = float(data["end_lat"]), float(data["end_lon"])
            radius = float(data["radius"])
            speed = float(data.get("speed", WALK_SPEED))
            return_to_start = bool(data.get("return_to_start", False))
            # isfinite matters: float("nan") parses fine, and every comparison
            # against NaN is False, which would silently disable zone entry.
            for value in (lat1, lon1, lat2, lon2, radius, speed):
                if not math.isfinite(value):
                    raise ValueError("values must be finite numbers")
            for lat, lon in ((lat1, lon1), (lat2, lon2)):
                if not (-90 <= lat <= 90 and -180 <= lon <= 180):
                    raise ValueError("coordinates out of range")
            if not 0 < radius <= MAX_RADIUS_M:
                raise ValueError(f"radius must be between 0 and {MAX_RADIUS_M} m")
            if not 0 < speed <= MAX_SPEED:
                raise ValueError(f"speed must be between 0 and {MAX_SPEED} m/s")
            total = haversine_m(lat1, lon1, lat2, lon2)
        except (ValueError, KeyError, TypeError, json.JSONDecodeError) as exc:
            self.send_json(400, {"ok": False, "error": f"bad request: {exc}"})
            return

        steps = route_steps(total, speed)
        duration = steps * TICK_SECONDS
        effective = total / duration if duration else 0.0
        mode = "running" if speed > WALK_SPEED else "walking"
        write_gpx(lat1, lon1, lat2, lon2, duration)
        print(f"  GPX updated: {lat1},{lon1} -> {lat2},{lon2} "
              f"({total:.0f}m, ~{duration:.0f}s {mode} at {effective:.1f} m/s, "
              f"zone {radius:.0f}m)")
        start_walk(lat1, lon1, lat2, lon2, radius, speed, return_to_start)
        threading.Thread(
            target=lambda: STATE.set_device(
                start_device_play(lat1, lon1, lat2, lon2, speed,
                                  return_to_start)),
            daemon=True,
        ).start()
        self.send_json(200, {
            "ok": True,
            "distance_m": round(total),
            "duration_s": round(duration * (2 if return_to_start else 1)),
            "return_to_start": return_to_start,
            "speed_mps": round(effective, 2),
            "applied": (f"{mode} {total / 1000:.0f}km, ~{duration:.0f}s "
                        f"at {effective:.0f} m/s (compressed)"
                        if effective > speed * 1.05 else
                        f"{mode} {total:.0f}m, ~{duration:.0f}s"),
        })


def make_server(addr):
    """One listener per address family.

    `localhost` resolves to ::1 before 127.0.0.1 on iOS, so an IPv4-only
    socket makes the app fail its first connection attempt (visible in Xcode
    as nw_endpoint_flow_failed_with_error on ::1). Binding both loopback
    addresses keeps that from happening without widening exposure.
    """
    family = socket.AF_INET6 if ":" in addr else socket.AF_INET
    server_class = type("GeofenceServer", (ThreadingHTTPServer,), {
        "address_family": family,
        "daemon_threads": True,
        "allow_reuse_address": True,
    })
    return server_class((addr, PORT), Handler)


def main():
    binds = ["0.0.0.0", "::"] if LAN_MODE else ["127.0.0.1", "::1"]
    print(f"Geofence panel helper on http://{binds[0]}:{PORT} "
          f"(also {binds[1]})")
    print(f"GPX file: {GPX_PATH}")
    print(f"Walk speed: {WALK_SPEED} m/s")
    print()
    print(f"  TOKEN: {TOKEN}")
    print("  Paste this into the app's Token field (saved in .geofence_token).")
    if LAN_MODE:
        print("  --lan: reachable from your local network. Traffic is plain "
              "HTTP, so avoid this on untrusted Wi-Fi.")
    else:
        print("  Loopback only. Pass --lan to test on a physical iPhone.")
    print()
    print("Waiting for 'Update geofence' from the app... (Ctrl+C to stop)")
    servers = []
    for addr in binds:
        try:
            servers.append(make_server(addr))
        except OSError as exc:
            print(f"  note: could not listen on {addr} ({exc})")
    if not servers:
        sys.exit("Could not bind any address.")
    for server in servers[1:]:
        threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        servers[0].serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")
        for server in servers:
            server.shutdown()


if __name__ == "__main__":
    main()
