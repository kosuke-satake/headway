#!/usr/bin/env python3
"""Adds or updates Japanese translations in the string catalog.

Usage: tools/add_strings.py <<'JSON'
{"English text": "日本語", "Count: %lld": "件数: %lld"}
JSON

Keys are the English source strings (interpolations written as %@ or %lld). Existing keys are updated.

A value can also be an object with the Japanese text and English plural forms, for a count that reads differently in
English ("1 bus", "2 buses"):

    {"%lld buses now": {"ja": "いま%lld台", "en": {"one": "%lld bus now", "other": "%lld buses now"}}}
"""
import json
import sys
from pathlib import Path

catalog = Path(__file__).resolve().parent.parent / "App/Resources/Localizable.xcstrings"
data = json.loads(catalog.read_text())
added = updated = 0
for key, value in json.load(sys.stdin).items():
    japanese = value["ja"] if isinstance(value, dict) else value
    entry = data["strings"].get(key)
    if entry is None:
        entry = data["strings"][key] = {"extractionState": "manual", "localizations": {}}
        added += 1
    else:
        updated += 1
    localizations = entry.setdefault("localizations", {})
    localizations["ja"] = {"stringUnit": {"state": "translated", "value": japanese}}
    if isinstance(value, dict) and "en" in value:
        localizations["en"] = {
            "variations": {"plural": {form: {"stringUnit": {"state": "translated", "value": text}} for form, text in value["en"].items()}}
        }
catalog.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
print(f"{added} added, {updated} updated")
