#!/usr/bin/env python3
"""Checks i18n/strings.json and writes the Java resource bundles.

Every key needs all twelve PXPlay languages and the same {n} placeholders as English.
    Tools/gen-i18n.py <output folder for mirage/i18n/*.properties>
"""
import json
import pathlib
import re
import sys

LANGUAGES = ["en", "de", "es", "fr", "he", "it", "ja", "ko", "pt", "ru", "zh_CN", "zh_TW"]
repo = pathlib.Path(__file__).resolve().parent.parent
strings = json.loads((repo / "i18n" / "strings.json").read_text(encoding="utf-8"))
problems = []
for key, values in strings.items():
    placeholders = set(re.findall(r"\{\d\}", values.get("en", "")))
    for language in LANGUAGES:
        text = values.get(language)
        if not text:
            problems.append(f"{key}: missing {language}")
        elif set(re.findall(r"\{\d\}", text)) != placeholders:
            problems.append(f"{key}: {language} placeholders differ")
    extra = set(values) - set(LANGUAGES)
    if extra:
        problems.append(f"{key}: unknown languages {sorted(extra)}")
if problems:
    sys.exit("i18n:\n  " + "\n  ".join(problems))


def escape(text):
    out = []
    for ch in text:
        if ch == "\\":
            out.append("\\\\")
        elif ch == "\n":
            out.append("\\n")
        elif ord(ch) < 0x20 or ord(ch) > 0x7e:
            units = ch.encode("utf-16-be")
            out.append("".join(f"\\u{int.from_bytes(units[i:i + 2], 'big'):04x}" for i in range(0, len(units), 2)))
        else:
            out.append(ch)
    return "".join(out)


output = pathlib.Path(sys.argv[1]) / "mirage" / "i18n"
output.mkdir(parents=True, exist_ok=True)
for language in LANGUAGES:
    name = "strings.properties" if language == "en" else f"strings_{language}.properties"
    lines = [f"{key}={escape(values[language])}" for key, values in sorted(strings.items()) if key.startswith("pxplay.")]
    (output / name).write_text("# Generated from i18n/strings.json\n" + "\n".join(lines) + "\n", encoding="ascii")
print(f"i18n: {len(strings)} keys in {len(LANGUAGES)} languages")
