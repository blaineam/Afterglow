#!/usr/bin/env python3
"""The interface's localization, checked without building. Run by Soren's l10n suite.

Fails when a catalog entry is missing or untranslated in one of the eight languages, when a
translation changes its format specifiers, HTML tags, leading emoji or {placeholders}, or when
source code passes a likely interface string to a panel without going through the catalog.
"""
import json
import os
import re
import sys

APP = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "app")
LANGS = ["de", "es", "fr", "it", "ja", "ko", "pt-BR", "zh-Hans"]
CATALOGS = ["Afterglow/Localizable.xcstrings", "Afterglow/InfoPlist.xcstrings", "AfterglowWatch/Localizable.xcstrings"]
SPEC = re.compile(r"%%|%(?:\d+\$)?[-0-9.]*(?:hh?|ll?|[qztL])?[@dioxXuUfeEgGaAcsSpC]")
# Same word in the language, or nothing to translate: reported only if a whole catalog is untouched.
EMOJI = re.compile(r"^[^\w\s%]+\s")


def signature(text):
    """Which argument each specifier reads, as what type, however it is written."""
    out = []
    position = 0
    for match in SPEC.findall(text):
        if match == "%%":
            continue
        numbered = re.match(r"%(\d+)\$", match)
        index = int(numbered.group(1)) if numbered else position + 1
        position += 1
        kind = match[-1]
        out.append((index, "d" if kind in "diouxX" else kind))
    return sorted(out)


def check_catalog(path, problems):
    catalog = json.load(open(os.path.join(APP, path), encoding="utf-8"))
    strings = catalog["strings"]
    for key, entry in strings.items():
        if entry.get("shouldTranslate") is False:
            continue
        for lang in LANGS:
            unit = entry.get("localizations", {}).get(lang, {}).get("stringUnit")
            if not unit or not unit.get("value"):
                problems.append(f"{path}: {lang} is missing {key!r}")
                continue
            if unit.get("state") != "translated":
                problems.append(f"{path}: {lang} {key!r} is {unit.get('state')}")
            value = unit["value"]
            if signature(key) != signature(value):
                problems.append(f"{path}: {lang} {key!r} changed its specifiers: {value!r}")
            bare_source = [s for s in SPEC.findall(key) if s != "%%"]
            bare_target = [s for s in SPEC.findall(value) if s != "%%"]
            if not any("$" in s for s in bare_target) and bare_source != bare_target:
                problems.append(f"{path}: {lang} {key!r} reorders bare specifiers: {value!r}")
            if sorted(re.findall(r"</?b>", key)) != sorted(re.findall(r"</?b>", value)):
                problems.append(f"{path}: {lang} {key!r} changed its tags: {value!r}")
            if re.findall(r"\{\w+\}", key) != re.findall(r"\{\w+\}", value):
                problems.append(f"{path}: {lang} {key!r} changed its placeholder: {value!r}")
            emoji = EMOJI.match(key)
            if emoji and not value.startswith(emoji.group(0)):
                problems.append(f"{path}: {lang} {key!r} must keep its leading {emoji.group(0)!r}: {value!r}")
    return strings


def check_source(known, problems):
    """A label: "Words" that never reached the catalog is English in every language."""
    plain = re.compile(r'\blabel: "((?:[^"\\]|\\.)*[A-Za-z]{2}(?:[^"\\]|\\.)*)"')
    keep = {"Apple Music", "Afterglow"}
    for root, _, names in os.walk(os.path.join(APP, "Afterglow")):
        for name in names:
            if not name.endswith(".swift"):
                continue
            path = os.path.join(root, name)
            for number, line in enumerate(open(path, encoding="utf-8"), 1):
                for text in plain.findall(line):
                    # Queue labels, and values with only a unit or the interpolated values themselves.
                    words = re.sub(r"\\\([^)]*\)+", "", text).strip(" ·")
                    if text not in keep and not re.fullmatch(r"afterglow\.\w+", text) and words not in ("", "bpm"):
                        problems.append(f"{os.path.relpath(path, APP)}:{number}: {text!r} isn't localized")


def main():
    problems = []
    known = {}
    for path in CATALOGS:
        known.update(check_catalog(path, problems))
    check_source(known, problems)
    for problem in problems[:80]:
        print(problem)
    if problems:
        print(f"FAIL: {len(problems)} localization problems")
        return 1
    print(f"PASS: {len(known)} strings in {len(LANGS)} languages")
    return 0


if __name__ == "__main__":
    sys.exit(main())
