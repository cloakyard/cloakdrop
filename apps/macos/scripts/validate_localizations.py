#!/usr/bin/env python3
"""Validate the app's String Catalog: every UI string must be translated into every
supported language, with format placeholders (%@, %lld, …) preserved.

A missing translation leaves the UI half-English; a mismatched placeholder count can crash
at format time or substitute the wrong value. Run from the repo root:

    python3 scripts/validate_localizations.py

Exits non-zero (and prints what's wrong) if the catalog is incomplete or inconsistent.
"""
import json
import os
import re
import sys

CATALOG = os.path.join(os.path.dirname(__file__), "..", "App", "Resources", "Localizable.xcstrings")
EXPECTED_LANGS = {"es", "fr", "de", "zh-Hans", "ja", "ko", "pt-BR", "ru", "ar", "hi"}
PLACEHOLDER = re.compile(r"%(?:@|lld|ld|d|lf|f)")


def placeholder_count(s: str) -> int:
    return len(PLACEHOLDER.findall(s))


def main() -> int:
    catalog = json.load(open(CATALOG, encoding="utf-8"))
    strings = catalog["strings"]
    problems = []

    for key, entry in strings.items():
        want = placeholder_count(key)
        locs = entry.get("localizations", {})
        present = set(locs.keys())

        for lang in sorted(EXPECTED_LANGS - present):
            problems.append(f"[{lang}] missing translation for {key!r}")

        for lang in sorted(EXPECTED_LANGS & present):
            unit = locs[lang].get("stringUnit", {})
            value = unit.get("value", "")
            if not value.strip():
                problems.append(f"[{lang}] empty translation for {key!r}")
                continue
            got = placeholder_count(value)
            if got != want:
                problems.append(
                    f"[{lang}] placeholder mismatch for {key!r}: key has {want}, translation has {got} ({value!r})"
                )

    langs_found = set()
    for entry in strings.values():
        langs_found |= set(entry.get("localizations", {}).keys())
    missing_langs = EXPECTED_LANGS - langs_found
    if missing_langs:
        problems.append(f"languages entirely absent from catalog: {sorted(missing_langs)}")

    if problems:
        print(f"FAIL: {len(problems)} localization problem(s):")
        for p in problems[:60]:
            print("  " + p)
        return 1

    print(
        f"OK: {len(strings)} strings × {len(EXPECTED_LANGS)} languages "
        f"({', '.join(sorted(EXPECTED_LANGS))}) — all translated, placeholders consistent."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
