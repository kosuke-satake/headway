#!/usr/bin/env python3
"""Pull what the Cloudflare collector has recorded into data/feeds/, in the layout `record_feeds.py` uses.

The collector (see collector/README.md) records the city's feeds around the clock. This script fetches the snapshots it
holds, writes each as data/feeds/<local date>/<stamp>_<feed>.pb.gz (so `feedanalysis` needs no changes), and then tells
the collector to delete them, which keeps its small free database from filling up. It also keeps the day's timetable
(the static GTFS zip), which the collector does not handle.

Settings come from data/collector/config.json ({"url": "https://...", "token": "..."}) or from the environment
(HEADWAY_COLLECTOR_URL, HEADWAY_COLLECTOR_TOKEN). Standard library only.

    python3 tools/pull_feeds.py            # pull everything new
    python3 tools/pull_feeds.py --status   # what the collector holds, and when it last ran
"""

import argparse
import gzip
import json
import os
import sys
import urllib.error
import urllib.request
from datetime import datetime, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import record_feeds  # noqa: E402  (its timetable download is reused)

CONFIG = Path(__file__).resolve().parent.parent / "data" / "collector" / "config.json"
BATCH = 200


def load_config() -> tuple[str, str]:
    url = os.environ.get("HEADWAY_COLLECTOR_URL", "")
    token = os.environ.get("HEADWAY_COLLECTOR_TOKEN", "")
    if (not url or not token) and CONFIG.exists():
        data = json.loads(CONFIG.read_text())
        url, token = url or data.get("url", ""), token or data.get("token", "")
    if not url or not token:
        sys.exit(f"No collector configured: write {CONFIG} or set HEADWAY_COLLECTOR_URL and HEADWAY_COLLECTOR_TOKEN.")
    return url.rstrip("/"), token


class Collector:
    def __init__(self, url: str, token: str):
        self.url, self.token = url, token

    def request(self, path: str, method: str = "GET") -> tuple[bytes, dict]:
        request = urllib.request.Request(
            self.url + path, method=method, headers={"Authorization": f"Bearer {self.token}", "User-Agent": "headway-pull/0.1"}
        )
        with urllib.request.urlopen(request, timeout=60) as response:
            return response.read(), dict(response.headers)

    def json(self, path: str, method: str = "GET") -> dict:
        return json.loads(self.request(path, method)[0])


def same_snapshot_nearby(folder: Path, feed: str, moment: datetime, raw: bytes) -> bool:
    """True when the same feed with the same content is already saved within 90 seconds (for example by the Mac
    recorder, while both ran)."""
    if not folder.exists():
        return False
    for path in folder.glob(f"*_{feed}.pb.gz"):
        try:
            stamp = datetime.strptime(path.name.split("_")[0], "%Y%m%dT%H%M%S%z")
        except ValueError:
            continue
        if abs((stamp - moment).total_seconds()) <= 90 and gzip.decompress(path.read_bytes()) == raw:
            return True
    return False


def write_snapshot(root: Path, feed: str, ts_ms: int, encoding: str, body: bytes) -> bool:
    """Saves one snapshot. Returns False when the same snapshot is already on disk (a repeated pull)."""
    raw = gzip.decompress(body) if encoding == "gzip" else body
    # Compress here, so that the files are byte-for-byte what record_feeds.py writes, whatever the collector stored.
    packed = gzip.compress(raw)
    moment = datetime.fromtimestamp(ts_ms / 1000).astimezone()
    if same_snapshot_nearby(root / moment.strftime("%Y-%m-%d"), feed, moment, raw):
        return False
    while True:
        folder = root / moment.strftime("%Y-%m-%d")
        target = folder / f"{moment.strftime('%Y%m%dT%H%M%S%z')}_{feed}.pb.gz"
        if not target.exists():
            folder.mkdir(parents=True, exist_ok=True)
            target.write_bytes(packed)
            return True
        if gzip.decompress(target.read_bytes()) == raw:
            return False
        # A different snapshot of the same feed in the same second (rare): keep both, a second apart.
        moment = moment.replace(microsecond=0) + timedelta(seconds=1)


def pull(collector: Collector, root: Path) -> tuple[int, int]:
    saved = skipped = 0
    cursor = 0
    while True:
        items = collector.json(f"/list?after={cursor}&limit={BATCH}")["items"]
        if not items:
            break
        for item in items:
            body, _ = collector.request(f"/snapshot/{item['id']}")
            if write_snapshot(root, item["feed"], item["ts"], item["encoding"], body):
                saved += 1
            else:
                skipped += 1
        cursor = items[-1]["id"]
        # Only after the files are on disk: the collector forgets everything up to here.
        collector.json(f"/ack?upto={cursor}", method="POST")
    return saved, skipped


def show_status(collector: Collector) -> None:
    status = collector.json("/status")
    last = status.get("lastRun")
    print("last run:", datetime.fromtimestamp(last / 1000).astimezone().isoformat(timespec="seconds") if last else "never")
    print("last error:", status.get("lastError") or "none")
    for row in status["feeds"]:
        print(f"  {row['feed']:9} {row['snapshots']:6} snapshots waiting, {row['bytes'] / 1e6:6.1f} MB")
    if not status["feeds"]:
        print("  nothing waiting")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--status", action="store_true", help="show what the collector holds and exit")
    parser.add_argument("--root", type=Path, default=record_feeds.ROOT, help="where to write (default: data/feeds)")
    parser.add_argument("--no-static", action="store_true", help="do not download the static GTFS zip")
    args = parser.parse_args()

    collector = Collector(*load_config())
    if args.status:
        show_status(collector)
        return 0

    try:
        saved, skipped = pull(collector, args.root)
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        print(f"{datetime.now():%H:%M:%S} pull failed: {error}", file=sys.stderr)
        return 1
    print(f"pulled {saved} snapshots ({skipped} already on disk)", flush=True)

    if not args.no_static:
        try:
            record_feeds.ROOT = args.root
            record_feeds.snapshot_static(record_feeds.day_dir(), {})
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            print(f"{datetime.now():%H:%M:%S} static: {error}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
