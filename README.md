# Geofence Test

An iOS panel plus a Mac helper for testing geofence campaigns end to end: pick
a zone that is actually configured in the Insider panel, walk the device in and
back out, and watch whether enter and exit fire.

Testing a campaign used to mean hand-editing a GPX in Xcode one coordinate at a
time, with no way to confirm the fence had fired. This does it in a couple of
taps, on the simulator or on real hardware.

---

## How it fits together

```
iOS app  ──HTTP over Wi-Fi──▶  geofence_panel.py  ──▶  simctl        (simulator)
                                                  └──▶  pymobiledevice3
                                                          └──▶ tunneld ──▶ iPhone
```

**The phone does not spoof its own location.** iOS gives an app no way to set
the device's position for other apps. The app is a remote control: it sends a
route to the Mac, and the Mac pushes each position back down to the device. If
that second leg is missing, the app will happily report "Walking… 494 m to
destination" while the phone has not moved a centimetre.

---

## Simulator

One terminal:

```bash
python3 geofence_panel.py
```

Copy the token it prints into the app's **Token** field (gear icon). The host
is already `localhost`. That is the whole setup.

---

## Real device

Needs two terminals, both left running.

### 1. The tunnel

```bash
sudo ./.venv/bin/python -m pymobiledevice3 remote tunneld
```

Must be the **3.13 venv**, not the system Python. iOS 18.2+ removed QUIC, so
the tunnel needs pymobiledevice3's TCP path, which requires Python 3.13+. The
Xcode-bundled 3.9 fails with `QuicProtocolNotSupportedError`.

If the venv is missing:

```bash
brew install python@3.13
/opt/homebrew/bin/python3.13 -m venv .venv
./.venv/bin/pip install pymobiledevice3
```

Homebrew's Python is externally managed (PEP 668) and will refuse a direct
`pip install` — hence the venv.

### 2. Check the tunnel before touching the app

```bash
./.venv/bin/python -m pymobiledevice3 developer dvt simulate-location set \
  --udid <YOUR-UDID> -- "-23.643614" "-46.7204767"
```

Should return within a few seconds printing nothing, and the phone should jump
to São Paulo in Maps. If it hangs past ~15 seconds the tunnel is stale —
restart `tunneld` and try again. Do not move on until this works; everything
above it is easier to debug once this is known good.

Find the UDID with `./.venv/bin/python -m pymobiledevice3 usbmux list`.

### 3. The helper

```bash
python3 geofence_panel.py --lan --insecure
```

`--lan` is required for a phone; the helper is loopback-only by default. It also
speaks plain HTTP with no TLS, so on the LAN the `X-Geofence-Token` — not just
the coordinates — travels in cleartext, and anyone on-path can sniff it and
replay it to drive every endpoint (including `POST /reset-app`). Because of
that, `--lan` refuses to bind a routable interface unless you add `--insecure`
to acknowledge the exposure. Use it only on a trusted network, prefer tunnelling
device traffic over USB/SSH when you can, and rotate the token afterwards
(delete `.geofence_token` or set a new `GEOFENCE_TOKEN`). Check the banner reads
`Device: …/.venv/bin/python (Python 3.13)` with no warning.

### 4. The app

Build onto the device from Xcode, allow the **Local Network** prompt, then set
in the gear:

| Field | Value |
| --- | --- |
| Mac helper | your Mac's LAN IP — `ipconfig getifaddr en0` |
| Token | printed by the helper at startup, also in `.geofence_token` |

### Prerequisites on the phone

USB **data** cable (charge-only cables leave the phone invisible and look
identical to "not plugged in"), device unlocked and trusting the Mac, and
Developer Mode on under Settings ▸ Privacy & Security.

---

## Running a test

Tap **Choose a geofence**, pick a zone, tap **Walk**. The route builds itself:
it starts outside the boundary, walks to the centre and returns, so both an
enter and an exit occur.

Type a different **panel** name in the picker to load another partner's zones.
Zones come back nearest-first, measured from where the device currently is.

---

## When it breaks

**"Cannot reach the helper"** — the Mac's LAN IP has almost certainly changed.
Check `ipconfig getifaddr en0` and update the app. This is by far the most
common failure.

**`401` in the helper log** — the token does not match. Copy it from
`.geofence_token`, and watch for a trailing space if you paste it.

**Helper logs `200` but the phone does not move** — the device leg is down. See
`device_play.log`, and re-run step 2 above.

**`Choose device: interactive selection requires a terminal`** — more than one
iPhone is reachable. The helper picks the USB-connected one; set
`GEOFENCE_UDID` if several are plugged in.

**Enter fires but exit never does** — iOS confirms an exit only well beyond the
boundary, measured at ~2x the radius. The app already starts far enough out for
this; if you are testing by hand, go further than you think.

**A newly added zone never fires** — iOS monitors at most **20 regions per
app** and keeps them across launches. An SDK that re-registers without
releasing the old set leaves that quota full, and every zone added afterwards
is silently refused. Use **Reset its geofence registrations** in the gear,
which reinstalls the partner app from its own binary. This wipes that app's
local data.

**Use Walk, not Run, for a real trigger.** `locationd` samples a fence roughly
every 10 seconds; at 10 m/s you cover 100 m between samples and a small zone
can be crossed entirely between two of them.

---

## Environment overrides

| Variable | Purpose |
| --- | --- |
| `GEOFENCE_TOKEN` | Use a fixed token instead of the generated one |
| `GEOFENCE_PYTHON` | Interpreter for pymobiledevice3, if auto-detection picks wrong |
| `GEOFENCE_UDID` | Which iPhone to drive, when more than one is attached |

## Helper endpoints

All require the `X-Geofence-Token` header. `POST /update` starts a route,
`GET /status` reports position and enter/exit, `POST /pause` and `/resume`
hold and continue it, `POST /stop` clears the simulated location, and
`POST /reset-app` reinstalls a partner app to clear its region registrations.

## A note on `update_fake_route_here.gpx`

It is a tracked file that the helper **rewrites on every run**, so it picks up
whatever coordinates were last used — including a real position if you use
"Go to original location". Check it before committing.
