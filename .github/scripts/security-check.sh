#!/usr/bin/env sh
set -eu

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required to run security checks" >&2
  exit 1
fi

python3 - <<'PY'
from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from urllib.parse import urlparse

JSON_FILES = sorted(Path("data").glob("*.json")) + sorted(Path("schemas").glob("*/template.json"))
if not JSON_FILES:
    print("No JSON files found in data/ or schemas/", file=sys.stderr)
    raise SystemExit(1)

BLOCKED_PATTERNS = [
    ("script tag", re.compile(r"<\s*script\b", re.IGNORECASE)),
    ("style tag", re.compile(r"<\s*style\b", re.IGNORECASE)),
    ("iframe tag", re.compile(r"<\s*iframe\b", re.IGNORECASE)),
    ("object tag", re.compile(r"<\s*object\b", re.IGNORECASE)),
    ("embed tag", re.compile(r"<\s*embed\b", re.IGNORECASE)),
    ("link tag", re.compile(r"<\s*link\b", re.IGNORECASE)),
    ("svg tag", re.compile(r"<\s*svg\b", re.IGNORECASE)),
    ("inline style attribute", re.compile(r"\bstyle\s*=\s*[\"']", re.IGNORECASE)),
    ("inline event handler", re.compile(r"\bon[a-z]+\s*=", re.IGNORECASE)),
    ("javascript url", re.compile(r"javascript\s*:", re.IGNORECASE)),
    ("vbscript url", re.compile(r"vbscript\s*:", re.IGNORECASE)),
    ("html data url", re.compile(r"data\s*:\s*text/html", re.IGNORECASE)),
    ("css import", re.compile(r"@import\b", re.IGNORECASE)),
    ("css expression", re.compile(r"expression\s*\(", re.IGNORECASE)),
]
CONTROL_CHARS = re.compile(r"[\x00-\x08\x0B\x0C\x0E-\x1F]")

errors: list[str] = []


def format_path(parts: list[object]) -> str:
    path = "$"
    for part in parts:
        if isinstance(part, int):
            path += f"[{part}]"
        else:
            path += f".{part}"
    return path


def check_string(file_path: Path, path_parts: list[object], value: str) -> None:
    json_path = format_path(path_parts)

    if CONTROL_CHARS.search(value):
        errors.append(f"{file_path}::{json_path}: contains disallowed control characters")

    for label, pattern in BLOCKED_PATTERNS:
        if pattern.search(value):
            errors.append(f"{file_path}::{json_path}: matched blocked {label} pattern")

    if path_parts and path_parts[-1] == "url":
        parsed = urlparse(value)
        scheme = parsed.scheme.lower()
        if scheme not in {"http", "https"}:
            errors.append(
                f"{file_path}::{json_path}: url fields must use http or https, got {scheme or 'missing scheme'}"
            )


def walk(file_path: Path, value: object, path_parts: list[object]) -> None:
    if isinstance(value, dict):
        for key, nested in value.items():
            walk(file_path, nested, [*path_parts, key])
        return

    if isinstance(value, list):
        for index, nested in enumerate(value):
            walk(file_path, nested, [*path_parts, index])
        return

    if isinstance(value, str):
        check_string(file_path, path_parts, value)


for file_path in JSON_FILES:
    with file_path.open("r", encoding="utf-8") as handle:
        payload = json.load(handle)
    walk(file_path, payload, [])

if errors:
    print("Security validation errors were encountered.", file=sys.stderr)
    for error in errors:
        print(f"  {error}", file=sys.stderr)
    raise SystemExit(1)

print(f"OK - Dataset security checks ({len(JSON_FILES)} JSON files)")
PY
