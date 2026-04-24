#!/usr/bin/env sh
set -eu

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required to run quote validation" >&2
  exit 1
fi

python3 - <<'PY'
from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Iterable

DATA_FILES = sorted(Path("data").glob("*.json"))
if not DATA_FILES:
    print("No event JSON files found in data/", file=sys.stderr)
    raise SystemExit(1)

QUOTE_TAG_RE = re.compile(r"\{\{quote\|(.+?)\}\}")
CITE_RE = re.compile(r"\{\{cite\|([^|}]+)(?:\|([^|}]+))?(?:\|([^|}]+))?\}\}")

# Maximum character gap between a {{quote|}} end and the next {{cite|}} start
# for the cite to be considered as backing the quote.
MAX_CITE_GAP = 200

errors: list[str] = []


def format_path(parts: list[object]) -> str:
    path = "$"
    for part in parts:
        if isinstance(part, int):
            path += f"[{part}]"
        else:
            path += f".{part}"
    return path


def iter_strings(value: object, path_parts: list[object] | None = None) -> Iterable[tuple[list[object], str]]:
    current_path = path_parts or []
    if isinstance(value, dict):
        for key, nested in value.items():
            yield from iter_strings(nested, [*current_path, key])
        return
    if isinstance(value, list):
        for index, nested in enumerate(value):
            yield from iter_strings(nested, [*current_path, index])
        return
    if isinstance(value, str):
        yield current_path, value


def normalize_for_comparison(text: str) -> str:
    """Strip editorial annotations, punctuation, and typographic variants for substring matching."""
    text = re.sub(r"\[.*?\]", "", text)       # remove editorial brackets
    text = text.replace("...", " ")            # ASCII ellipsis
    text = text.replace("\u2026", " ")         # Unicode ellipsis
    text = re.sub(r"[\"'`\u2018\u2019\u201c\u201d]", "", text)  # strip all quote chars
    text = re.sub(r"[\u2013\u2014]", " ", text)                  # en/em dash to space
    text = re.sub(r"[,;:.\-!?()]", " ", text)                    # strip punctuation
    text = text.lower()
    text = re.sub(r"\s+", " ", text)
    return text.strip()


def truncate(text: str, max_len: int = 60) -> str:
    if len(text) <= max_len:
        return text
    return text[:max_len] + "..."


for file_path in DATA_FILES:
    with file_path.open("r", encoding="utf-8") as handle:
        payload = json.load(handle)

    refs_by_id = {
        ref.get("id"): ref
        for ref in (payload.get("references") or [])
        if isinstance(ref, dict) and isinstance(ref.get("id"), str)
    }

    for path_parts, value in iter_strings(payload):
        quote_matches = list(QUOTE_TAG_RE.finditer(value))
        if not quote_matches:
            continue

        cite_matches = list(CITE_RE.finditer(value))
        json_path = format_path(path_parts)

        for qm in quote_matches:
            quote_text = qm.group(1)
            quote_end = qm.end()

            # Find the next {{cite|}} after this quote within MAX_CITE_GAP
            next_cite = None
            gap = None
            for cm in cite_matches:
                if cm.start() >= quote_end:
                    gap = cm.start() - quote_end
                    if gap <= MAX_CITE_GAP:
                        next_cite = cm
                    break

            if next_cite is None:
                errors.append(
                    f"{file_path}::{json_path}: "
                    f"{{{{quote|{truncate(quote_text)}}}}} has no following {{{{cite}}}} tag"
                )
                continue

            ref_id = next_cite.group(1)
            pages = next_cite.group(2).strip() if next_cite.group(2) else ""
            excerpt_id = next_cite.group(3).strip() if next_cite.group(3) else ""
            if not excerpt_id:
                cite_preview = f"{{{{cite|{ref_id}|{pages}}}}}" if pages else f"{{{{cite|{ref_id}}}}}"
                errors.append(
                    f"{file_path}::{json_path}: "
                    f"{{{{quote|{truncate(quote_text)}}}}} is followed by {cite_preview} "
                    "without an excerpt_id, so the quote cannot be validated against references[].excerpts"
                )
                continue

            reference = refs_by_id.get(ref_id)
            if not isinstance(reference, dict):
                continue

            excerpt = next(
                (
                    entry for entry in (reference.get("excerpts") or [])
                    if isinstance(entry, dict) and entry.get("id") == excerpt_id
                ),
                None,
            )
            if not isinstance(excerpt, dict):
                errors.append(
                    f"{file_path}::{json_path}: "
                    f"{{{{quote|{truncate(quote_text)}}}}} is followed by {{{{cite|{ref_id}|...|{excerpt_id}}}}} "
                    "but that excerpt was not found in references[]"
                )
                continue

            cite_text_segments = [
                quote.get("text")
                for quote in (excerpt.get("quotes") or [])
                if isinstance(quote, dict) and isinstance(quote.get("text"), str)
            ]
            if not cite_text_segments:
                errors.append(
                    f"{file_path}::{json_path}: "
                    f"{{{{cite|{ref_id}|...|{excerpt_id}}}}} has no quote text to validate"
                )
                continue

            cite_combined = " ".join(cite_text_segments)

            # 1) Try exact substring match
            if quote_text in cite_combined:
                continue

            # 2) Check that every word in the quote exists in the cite text
            norm_quote = normalize_for_comparison(quote_text)
            norm_cite = normalize_for_comparison(cite_combined)
            quote_words = set(norm_quote.split())
            cite_words = set(norm_cite.split())
            missing = quote_words - cite_words

            if not missing:
                continue

            # Report error with the missing words
            errors.append(
                f"{file_path}::{json_path}: "
                f"{{{{quote|{truncate(quote_text)}}}}} — "
                f"words not found in {{{{cite|{next_cite.group(1)}}}}}: "
                f"{', '.join(sorted(missing))}"
            )

if errors:
    print("Quote validation errors were encountered.", file=sys.stderr)
    for e in errors:
        print(f"  {e}", file=sys.stderr)
    raise SystemExit(1)

quote_count = 0
for file_path in DATA_FILES:
    with file_path.open("r", encoding="utf-8") as handle:
        text = handle.read()
    quote_count += len(QUOTE_TAG_RE.findall(text))

print(f"OK - Quote validation ({quote_count} quotes across {len(DATA_FILES)} files)")
PY
