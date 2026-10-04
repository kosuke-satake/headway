#!/usr/bin/env python3
"""Adds or updates Japanese translations in the string catalog.

Usage: tools/add_strings.py <<'JSON'
{"English text": "日本語", "Count: %lld": "件数: %lld"}
JSON

Keys are the English source strings (interpolations written as %@ or %lld). Existing keys are updated.
"""
import json
import sys
from pathlib import Path

catalog = Path(__file__).resolve().parent.parent / "App/Resources/Localizable.xcstrings"
data = json.loads(catalog.read_text())
added = updated = 0
for key, japanese in json.load(sys.stdin).items():
    entry = data["strings"].get(key)
    if entry is None:
        data["strings"][key] = {"extractionState": "manual", "localizations": {"ja": {"stringUnit": {"state": "translated", "value": japanese}}}}
        added += 1
    else:
        entry.setdefault("localizations", {})["ja"] = {"stringUnit": {"state": "translated", "value": japanese}}
        updated += 1
catalog.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
print(f"{added} added, {updated} updated")
