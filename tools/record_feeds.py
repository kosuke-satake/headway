#!/usr/bin/env python3
"""Record Madison Metro GTFS-Realtime feeds as raw, gzipped protobuf snapshots.

The recordings answer one question: which scheduled trips never show up with a
vehicle position? They are compared against the static GTFS schedule afterwards.

Standard library only. Output goes to data/feeds/<date>/, which is outside Git.

    python3 tools/record_feeds.py --hours 24
    python3 tools/record_feeds.py --once --no-static     # smoke test
"""

import argparse
import gzip
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path

BASE = "https://metromap.cityofmadison.com/gtfsrt"
STATIC_URL = "https://transitdata.cityofmadison.com/GTFS/mmt_gtfs.zip"
FEEDS = {
    # name: (path, interval in seconds). trips is ~250 KB, so it is polled less often.
    "vehicles": ("vehicles", 15),
    "trips": ("trips", 60),
    "alerts": ("alerts", 300),
}
ROOT = Path(__file__).resolve().parent.parent / "data" / "feeds"


def fetch(url: str) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": "headway-recorder/0.1"})
    with urllib.request.urlopen(request, timeout=20) as response:
        return response.read()


def save(out_dir: Path, name: str, payload: bytes) -> None:
    stamp = datetime.now().astimezone().strftime("%Y%m%dT%H%M%S%z")
    (out_dir / f"{stamp}_{name}.pb.gz").write_bytes(gzip.compress(payload))


def snapshot_static(out_dir: Path) -> None:
    target = out_dir / "mmt_gtfs.zip"
    if target.exists():
        return
    target.write_bytes(fetch(STATIC_URL))
    print(f"saved static GTFS ({target.stat().st_size} bytes)")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--hours", type=float, default=24, help="how long to record")
    parser.add_argument("--once", action="store_true", help="poll each feed one time and exit")
    parser.add_argument("--no-static", action="store_true", help="do not download the static GTFS zip")
    args = parser.parse_args()

    out_dir = ROOT / datetime.now().astimezone().strftime("%Y-%m-%d")
    out_dir.mkdir(parents=True, exist_ok=True)
    if not args.no_static:
        snapshot_static(out_dir)

    deadline = time.monotonic() + args.hours * 3600
    next_due = {name: 0.0 for name in FEEDS}
    failures = 0
    while True:
        now = time.monotonic()
        for name, (path, interval) in FEEDS.items():
            if now < next_due[name]:
                continue
            next_due[name] = now + interval
            try:
                save(out_dir, name, fetch(f"{BASE}/{path}"))
            except (urllib.error.URLError, TimeoutError, OSError) as error:
                failures += 1
                print(f"{datetime.now():%H:%M:%S} {name}: {error}", file=sys.stderr)
        if args.once or time.monotonic() >= deadline:
            break
        time.sleep(1)

    print(f"done: {len(list(out_dir.glob('*.pb.gz')))} snapshots, {failures} failed requests -> {out_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
