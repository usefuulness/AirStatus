import os, asyncio, shutil, subprocess
from time import time_ns
from binascii import hexlify
from json import dumps
from sys import argv
from datetime import datetime

from bleak import BleakScanner, discover
from bleak.exc import BleakDBusError

# ---- Config (env overrides allowed) ----
UPDATE_DURATION = float(os.getenv("AIRSTATUS_UPDATE_SEC", "1"))
MIN_RSSI = int(os.getenv("AIRSTATUS_MIN_RSSI", "-90"))
AIRPODS_MANUFACTURER = 0x004C  # Apple
AIRPODS_DATA_HEX_LEN = int(os.getenv("AIRSTATUS_HEX_LEN", "54"))
NAME_HINTS = tuple(s.strip() for s in os.getenv(
    "AIRSTATUS_NAME_HINTS",
    "AirPods,AirPods Pro,AirPods Pro 2,AirPods3,AirPods Max"
).split(","))
DEBUG = os.getenv("AIRSTATUS_DEBUG", "0") == "1"
RECENT_BEACONS_MAX_T_NS = 10_000_000_000  # 10s

recent = []  # [{time, device, mfg_hex, name}]

def dbg(msg):
    if DEBUG:
        print(f"[DBG] {msg}")

def keep_best(device, mfg_hex, name):
    recent.append({"time": time_ns(), "device": device, "mfg_hex": mfg_hex, "name": name})
    now = time_ns()
    i = 0
    strongest = None
    while i < len(recent):
        if now - recent[i]["time"] > RECENT_BEACONS_MAX_T_NS:
            recent.pop(i)
            continue
        if strongest is None or (recent[i]["device"].rssi or -999) > (strongest["device"].rssi or -999):
            strongest = recent[i]
        i += 1
    if strongest and strongest["device"].address == device.address:
        strongest = {"time": now, "device": device, "mfg_hex": mfg_hex, "name": name}
    return strongest

def is_flipped(raw_hex: bytes) -> bool:
    return (int(chr(raw_hex[10]), 16) & 0x02) == 0

def decode_airpods(raw_hex: bytes):
    flip = is_flipped(raw_hex)
    c7 = chr(raw_hex[7])
    model = (
        "AirPodsPro" if c7 == 'e' else
        "AirPods3"   if c7 == '3' else
        "AirPods2"   if c7 == 'f' else
        "AirPods1"   if c7 == '2' else
        "AirPodsMax" if c7 == 'a' else
        "unknown"
    )

    def pct_at(idx):
        v = int(chr(raw_hex[idx]), 16)
        return 100 if v == 10 else (v * 10 + 5 if v <= 10 else -1)

    left  = pct_at(12 if flip else 13)
    right = pct_at(13 if flip else 12)
    case  = pct_at(15)

    chg = int(chr(raw_hex[14]), 16)
    charging_left  = (chg & (0b00000010 if flip else 0b00000001)) != 0
    charging_right = (chg & (0b00000001 if flip else 0b00000010)) != 0
    charging_case  = (chg & 0b00000100) != 0

    return dict(
        status=1,
        charge=dict(left=left, right=right, case=case),
        charging_left=charging_left,
        charging_right=charging_right,
        charging_case=charging_case,
        model=model,
        date=datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
        raw=raw_hex.decode("utf-8"),
    )

def pick_strongest():
    now = time_ns()
    i = 0
    strongest = None
    while i < len(recent):
        if now - recent[i]["time"] > RECENT_BEACONS_MAX_T_NS:
            recent.pop(i)
            continue
        if strongest is None or (recent[i]["device"].rssi or -999) > (strongest["device"].rssi or -999):
            strongest = recent[i]
        i += 1
    return strongest

def kick_adapter():
    """Try to clear a stuck LE-scan state without requiring root if possible."""
    try:
        if shutil.which("btmgmt"):
            subprocess.run(["sudo","btmgmt","-i","hci0","find","stop"], timeout=2)
            subprocess.run(["sudo","btmgmt","-i","hci0","power","off"], timeout=3)
            subprocess.run(["sudo","btmgmt","-i","hci0","power","on"], timeout=3)
            return
    except Exception:
        pass
    try:
        if shutil.which("bluetoothctl"):
            subprocess.run(["bluetoothctl","scan","off"], timeout=2)
            subprocess.run(["bluetoothctl","power","off"], timeout=3)
            subprocess.run(["bluetoothctl","power","on"], timeout=3)
    except Exception:
        pass

async def poll_once_with_discover():
    """One-shot poll using bleak.discover() as a fallback path."""
    try:
        devs = await discover(timeout=3.0)
    except BleakDBusError as e:
        if "InProgress" in str(e):
            dbg("discover(): InProgress; backing off")
            await asyncio.sleep(1.0)
            return
        raise
    for d in devs:
        name = d.name or ""
        mfg = getattr(d, "metadata", {}).get("manufacturer_data", {}) or {}
        has_apple = AIRPODS_MANUFACTURER in mfg
        matches_name = any(h.lower() in name.lower() for h in NAME_HINTS) if name else False
        if not has_apple and not matches_name:
            continue
        if d.rssi is None or d.rssi < MIN_RSSI:
            continue
        mbytes = bytearray(mfg[AIRPODS_MANUFACTURER]) if has_apple else None
        mhex = hexlify(mbytes) if mbytes is not None else None
        if DEBUG and (has_apple or matches_name):
            lhex = (mhex[:64].decode() + "...") if mhex else "None"
            dbg(f"[discover] addr={d.address} rssi={d.rssi} name='{name}' apple={has_apple} hex={lhex}")
        keep_best(d, mhex, name)

async def run_async():
    out_path = argv[-1] if len(argv) > 1 else None

    async def on_adv(device, adv_data):
        name = (adv_data.local_name or device.name or "") if adv_data else (device.name or "")
        mfg = getattr(adv_data, "manufacturer_data", {}) or {}
        has_apple = AIRPODS_MANUFACTURER in mfg
        matches_name = any(h.lower() in name.lower() for h in NAME_HINTS) if name else False
        if not has_apple and not matches_name:
            return
        if device.rssi is None or device.rssi < MIN_RSSI:
            return
        mbytes = bytearray(mfg[AIRPODS_MANUFACTURER]) if has_apple else None
        mhex = hexlify(mbytes) if mbytes is not None else None
        if DEBUG and (has_apple or matches_name):
            lhex = (mhex[:64].decode() + "...") if mhex else "None"
            dbg(f"[scan] addr={device.address} rssi={device.rssi} name='{name}' apple={has_apple} hex={lhex}")
        keep_best(device, mhex, name)

    scanner = BleakScanner(detection_callback=on_adv)
    use_poll = False

    # Try to start scanner; if InProgress won't clear, toggle adapter and fallback to polling.
    for attempt in range(6):
        try:
            await scanner.start()
            dbg("BleakScanner started")
            break
        except BleakDBusError as e:
            if "InProgress" in str(e):
                dbg("StartDiscovery InProgress; attempting adapter kick...")
                await asyncio.to_thread(kick_adapter)
                await asyncio.sleep(1.0)
                if attempt == 5:
                    dbg("Falling back to discover() polling mode")
                    use_poll = True
            else:
                raise

    try:
        while True:
            await asyncio.sleep(UPDATE_DURATION)
            if use_poll:
                await poll_once_with_discover()

            strongest = pick_strongest()
            if not strongest:
                payload = dict(status=0, model="AirPods not found")
            else:
                raw_hex = strongest["mfg_hex"]
                if raw_hex is not None and len(raw_hex) == AIRPODS_DATA_HEX_LEN:
                    payload = decode_airpods(raw_hex)
                else:
                    payload = dict(
                        status=0,
                        model=("AirPods detected" if strongest["name"] else "Apple device detected"),
                        note="Manufacturer frame present but unsupported length" if raw_hex is not None else "Matched by name only",
                        rssi=strongest["device"].rssi,
                        name=strongest["name"],
                        date=datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
                    )

            line = dumps(payload)
            if out_path:
                with open(out_path, "a") as f:
                    f.write(line + "\n")
            else:
                print(line)
    finally:
        try:
            await scanner.stop()
        except Exception:
            pass

if __name__ == "__main__":
    asyncio.run(run_async())
