#!/usr/bin/env python3
"""Record Madison Metro GTFS-Realtime feeds as raw, gzipped protobuf snapshots, for as long as it is left running.

The recordings feed two analyses (see `feedanalysis`): how punctual each route and stop really is, and how good the live
predictions are. Standard library only. Output goes to data/feeds/<local date>/, which is outside Git.

A snapshot is saved only when its content changed, so polling often costs nothing on disk: the vehicle feed is rebuilt
every 30 seconds, and a poll every 10 seconds catches each new one within 10 seconds.

    python3 tools/record_feeds.py                 # run until stopped
    python3 tools/record_feeds.py --hours 24
    python3 tools/record_feeds.py --once --no-static     # smoke test
"""

import argparse
import gzip
import hashlib
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path

BASE = "https://metromap.cityofmadison.com/gtfsrt"
STATIC_URL = "https://transitdata.cityofmadison.com/GTFS/mmt_gtfs.zip"
FEEDS = {
    # name: (path, poll interval in seconds). `trips` is about 250 KB, so it is polled less often.
    "vehicles": ("vehicles", 10),
    "trips": ("trips", 300),
    "alerts": ("alerts", 600),
}
ROOT = Path(__file__).resolve().parent.parent / "data" / "feeds"


def fetch(url: str, method: str = "GET") -> tuple[bytes, dict]:
    request = urllib.request.Request(url, method=method, headers={"User-Agent": "headway-recorder/0.2"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.read(), dict(response.headers)


def day_dir() -> Path:
    path = ROOT / datetime.now().astimezone().strftime("%Y-%m-%d")
    path.mkdir(parents=True, exist_ok=True)
    return path


def save(out_dir: Path, name: str, payload: bytes) -> None:
    stamp = datetime.now().astimezone().strftime("%Y%m%dT%H%M%S%z")
    (out_dir / f"{stamp}_{name}.pb.gz").write_bytes(gzip.compress(payload))


def snapshot_static(out_dir: Path, state: dict) -> None:
    """Save the timetable once per day, but only when the city has published a new one."""
    meta = ROOT / "static.last-modified"
    previous = meta.read_text().strip() if meta.exists() else ""
    _, headers = fetch(STATIC_URL, method="HEAD")
    modified = headers.get("Last-Modified", "")
    target = out_dir / "mmt_gtfs.zip"
    if modified and modified == previous:
        return
    body, _ = fetch(STATIC_URL)
    target.write_bytes(body)
    meta.write_text(modified)
    print(f"saved static GTFS ({len(body)} bytes, modified {modified})", flush=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--hours", type=float, default=0, help="how long to record; 0 means until stopped")
    parser.add_argument("--once", action="store_true", help="poll each feed one time and exit")
    parser.add_argument("--no-static", action="store_true", help="do not download the static GTFS zip")
    args = parser.parse_args()

    ROOT.mkdir(parents=True, exist_ok=True)
    deadline = time.monotonic() + args.hours * 3600 if args.hours > 0 else None
    next_due = {name: 0.0 for name in FEEDS}
    last_hash: dict[str, str] = {}
    last_static_day = ""
    saved = failures = 0

    while True:
        now = time.monotonic()
        today = datetime.now().astimezone().strftime("%Y-%m-%d")
        if not args.no_static and today != last_static_day:
            try:
                snapshot_static(day_dir(), {})
                last_static_day = today
            except (urllib.error.URLError, TimeoutError, OSError) as error:
                failures += 1
                print(f"{datetime.now():%H:%M:%S} static: {error}", file=sys.stderr, flush=True)
                last_static_day = today  # try again tomorrow; the previous timetable is still good

        for name, (path, interval) in FEEDS.items():
            if now < next_due[name]:
                continue
            next_due[name] = now + interval
            try:
                body, _ = fetch(f"{BASE}/{path}")
                digest = hashlib.md5(body).hexdigest()
                if last_hash.get(name) != digest:
                    save(day_dir(), name, body)
                    last_hash[name] = digest
                    saved += 1
            except (urllib.error.URLError, TimeoutError, OSError) as error:
                failures += 1
                print(f"{datetime.now():%H:%M:%S} {name}: {error}", file=sys.stderr, flush=True)

        if args.once or (deadline is not None and time.monotonic() >= deadline):
            break
        time.sleep(1)

    print(f"done: {saved} snapshots saved, {failures} failed requests", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
