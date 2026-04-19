#!/usr/bin/env sh
set -eu

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required to run integrity checks" >&2
  exit 1
fi

python3 - <<'PY'
from __future__ import annotations

import json
import os
import re
import sys
from collections import Counter
from datetime import date
from pathlib import Path
from typing import Iterable
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import Request, urlopen

DATA_FILES = sorted(Path("data").glob("*.json"))
if not DATA_FILES:
    print("No event JSON files found in data/", file=sys.stderr)
    raise SystemExit(1)

CITATION_SCHEMA_PATH = Path("schemas/inline_citation.json")
if not CITATION_SCHEMA_PATH.exists():
    print("schemas/inline_citation.json not found", file=sys.stderr)
    raise SystemExit(1)
CITATION_SCHEMA = json.loads(CITATION_SCHEMA_PATH.read_text(encoding="utf-8"))

# Derive validation patterns from the inline citation schema
_page_pattern = CITATION_SCHEMA["properties"]["pages"]["pattern"]
_quote_page_pattern = CITATION_SCHEMA["definitions"]["quotation_entry"]["properties"]["page"]["pattern"]
PAGE_RE = re.compile(_page_pattern)

# Citation tag: {{cite|ref_id|pages|quotations}}
CITE_RE = re.compile(r"\{\{cite\|([^|}]+)\|([^|}]+)\|([^}]+)\}\}")
# Each quotation entry: "text" (page ref)
QUOTE_ENTRY_RE = re.compile(r'^"([^"]+)"\s*\((' + _quote_page_pattern[1:-1] + r')\)$')
MALFORMED_CITE_RE = re.compile(
    r"(?<!\{)\{cite\|"                     # single opening brace (not preceded by {)
    r"|\{\{cite\|\}\}"                     # empty cite id: {{cite|}}
    r"|\{\{cite(?!\|)"                     # {{cite without pipe: {{cite}}
    r"|\{\{cite\|[^|}]+\}\}"              # only ref_id, missing pages and quotations
    r"|\{\{cite\|[^|}]+\|[^|}]+\}\}"      # only ref_id + pages, missing quotations
)
FILENAME_YEAR_RE = re.compile(r"^[a-z]+-(\d{4})-")
URL_MODE = os.environ.get("CHECK_URL_REACHABILITY", "off").strip().lower()
URL_TIMEOUT = float(os.environ.get("URL_CHECK_TIMEOUT", "8"))
VALID_URL_MODES = {"off", "warn", "error"}
if URL_MODE not in VALID_URL_MODES:
    print(
        f"Invalid CHECK_URL_REACHABILITY value: {URL_MODE}. Expected one of: {', '.join(sorted(VALID_URL_MODES))}.",
        file=sys.stderr,
    )
    raise SystemExit(1)

errors: list[str] = []
warnings: list[str] = []
record_ids: dict[str, Path] = {}
url_cache: dict[str, str | None] = {}
checked_urls = 0


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


def parse_iso_date(raw_value: str, file_path: Path, json_path: str) -> date | None:
    try:
        return date.fromisoformat(raw_value)
    except ValueError:
        errors.append(f"{file_path}::{json_path}: invalid ISO date {raw_value!r}")
        return None


def check_url_reachability(url: str) -> str | None:
    global checked_urls
    if url in url_cache:
        return url_cache[url]

    checked_urls += 1

    def attempt(method: str) -> str | None:
        request = Request(url, method=method, headers={"User-Agent": "DilomaticIntegrityCheck/1.0"})
        try:
            with urlopen(request, timeout=URL_TIMEOUT) as response:
                status = getattr(response, "status", 200)
                if 200 <= status < 400:
                    return None
                return f"returned HTTP {status}"
        except HTTPError as exc:
            if exc.code in {401, 403}:
                return None
            if method == "HEAD" and exc.code in {405, 501}:
                return attempt("GET")
            return f"returned HTTP {exc.code}"
        except URLError as exc:
            reason = exc.reason
            if isinstance(reason, Exception):
                return str(reason)
            return str(reason)
        except Exception as exc:  # pragma: no cover - defensive catch
            return str(exc)

    result = attempt("HEAD")
    url_cache[url] = result
    return result


for file_path in DATA_FILES:
    with file_path.open("r", encoding="utf-8") as handle:
        payload = json.load(handle)

    record_id = payload.get("record_id")
    expected_record_id = file_path.stem
    if record_id != expected_record_id:
        errors.append(
            f"{file_path}::$.record_id: expected {expected_record_id!r} to match filename, got {record_id!r}"
        )

    if isinstance(record_id, str):
        previous = record_ids.get(record_id)
        if previous is not None:
            errors.append(
                f"{file_path}::$.record_id: duplicate record_id {record_id!r}; already used in {previous}"
            )
        else:
            record_ids[record_id] = file_path

    added_at = payload.get("added_at")
    edited_at = payload.get("edited_at")
    added_date = parse_iso_date(added_at, file_path, "$.added_at") if isinstance(added_at, str) else None
    edited_date = parse_iso_date(edited_at, file_path, "$.edited_at") if isinstance(edited_at, str) else None
    if added_date and edited_date and edited_date < added_date:
        errors.append(f"{file_path}::$.edited_at: must be on or after added_at")
    today = date.today()
    if edited_date and edited_date > today:
        errors.append(f"{file_path}::$.edited_at: date {edited_at} is in the future")
    if added_date and added_date > today:
        errors.append(f"{file_path}::$.added_at: date {added_at} is in the future")

    event = payload.get("event") or {}

    time_period = event.get("time_period") or {}
    start_year = time_period.get("start_year")
    end_year = time_period.get("end_year")
    if isinstance(start_year, int) and isinstance(end_year, int) and end_year < start_year:
        errors.append(f"{file_path}::$.event.time_period: end_year ({end_year}) is before start_year ({start_year})")

    filename_match = FILENAME_YEAR_RE.match(file_path.stem)
    if filename_match:
        filename_year = int(filename_match.group(1))
        if isinstance(start_year, int) and isinstance(end_year, int):
            if not (start_year <= filename_year <= end_year):
                errors.append(
                    f"{file_path}: filename year {filename_year} is outside time_period {start_year}-{end_year}"
                )
        elif isinstance(start_year, int) and filename_year < start_year:
            errors.append(
                f"{file_path}: filename year {filename_year} is before time_period start_year {start_year}"
            )

    actors = payload.get("actors") or []
    actor_names = {actor.get("name") for actor in actors if isinstance(actor, dict) and isinstance(actor.get("name"), str)}

    strategies = payload.get("strategies")
    if not isinstance(strategies, list) or len(strategies) == 0:
        errors.append(f"{file_path}::$.strategies: must contain at least one entry")
    elif isinstance(strategies, list):
        strategy_names: list[str] = []
        valid_effectiveness = {"effective", "ineffective", "mixed"}
        for idx, entry in enumerate(strategies):
            if not isinstance(entry, dict):
                continue
            name = entry.get("strategy_name")
            if isinstance(name, str):
                strategy_names.append(name)
            effectiveness = entry.get("effectiveness")
            if isinstance(effectiveness, str) and effectiveness not in valid_effectiveness:
                errors.append(f"{file_path}::$.strategies[{idx}].effectiveness: invalid value {effectiveness!r}")
            
            actor = entry.get("actor")
            if isinstance(actor, str) and actor not in actor_names:
                errors.append(f"{file_path}::$.strategies[{idx}].actor: actor {actor!r} not found in actors array")
                
        seen: set[str] = set()
        for name in strategy_names:
            if name in seen:
                errors.append(f"{file_path}::$.strategies: duplicate strategy_name {name!r}")
            seen.add(name)
            
        # Second pass to check related_strategies
        for idx, entry in enumerate(strategies):
            if not isinstance(entry, dict):
                continue
            related = entry.get("related_strategies")
            if isinstance(related, list):
                for rel_idx, rel_name in enumerate(related):
                    if isinstance(rel_name, str) and rel_name not in seen:
                        errors.append(f"{file_path}::$.strategies[{idx}].related_strategies[{rel_idx}]: related strategy {rel_name!r} not found in strategies array")

    cited_authors = payload.get("cited_authors") or []
    author_ids = {author.get("id") for author in cited_authors if isinstance(author, dict) and isinstance(author.get("id"), str)}
    used_author_ids = set()

    references = payload.get("references") or []
    ref_ids = [ref.get("id") for ref in references if isinstance(ref, dict) and isinstance(ref.get("id"), str)]
    ref_id_set = set(ref_ids)
    duplicate_ref_ids = sorted(ref_id for ref_id, count in Counter(ref_ids).items() if count > 1)
    for ref_id in duplicate_ref_ids:
        errors.append(f"{file_path}::$.references: duplicate reference id {ref_id!r}")
        
    for idx, ref in enumerate(references):
        if not isinstance(ref, dict):
            continue
        ref_author_ids = ref.get("author_ids")
        if isinstance(ref_author_ids, list):
            for a_idx, a_id in enumerate(ref_author_ids):
                if isinstance(a_id, str):
                    if a_id not in author_ids:
                        errors.append(f"{file_path}::$.references[{idx}].author_ids[{a_idx}]: author id {a_id!r} not found in cited_authors array")
                    used_author_ids.add(a_id)
                    
    unused_author_ids = author_ids - used_author_ids
    for unused_id in sorted(unused_author_ids):
        errors.append(f"{file_path}::$.cited_authors: author id {unused_id!r} is never used by any reference")

    related_events = payload.get("related_events") or []
    for idx, rel_event in enumerate(related_events):
        if not isinstance(rel_event, dict):
            continue
        rel_id = rel_event.get("record_id")
        if isinstance(rel_id, str):
            # Check if this record_id exists as a file
            expected_path = Path("data") / f"{rel_id}.json"
            if not expected_path.exists():
                errors.append(f"{file_path}::$.related_events[{idx}].record_id: related event {rel_id!r} does not correspond to an existing file in data/")

    cited_ref_ids: set[str] = set()
    for path_parts, value in iter_strings(payload):
        if not value.strip() and value != "":
            json_path = format_path(path_parts)
            warnings.append(f"{file_path}::{json_path}: string contains only whitespace")
            
        for m in CITE_RE.finditer(value):
            ref_id, pages, quotations = m.group(1), m.group(2), m.group(3)
            cited_ref_ids.add(ref_id)
            json_path = format_path(path_parts)
            
            # Check smart quotes inside cite tags
            if any(c in quotations for c in "“”‘’"):
                errors.append(f"{file_path}::{json_path}: cite tag for {ref_id!r} contains smart quotes (use straight quotes)")
                
            # Check p. vs pp. logic
            pages_stripped = pages.strip()
            if not PAGE_RE.match(pages_stripped):
                errors.append(f"{file_path}::{json_path}: invalid page format {pages_stripped!r} in cite tag (expected e.g. 'p. 47' or 'pp. 78-120')")
            else:
                if "-" in pages_stripped and pages_stripped.startswith("p.") and not pages_stripped.startswith("pp."):
                    errors.append(f"{file_path}::{json_path}: page range {pages_stripped!r} should use 'pp.' instead of 'p.'")
                elif "-" not in pages_stripped and pages_stripped.startswith("pp."):
                    errors.append(f"{file_path}::{json_path}: single page {pages_stripped!r} should use 'p.' instead of 'pp.'")

            quote_entries = [q.strip() for q in re.split(r'(?<=\))\s*;\s*(?=")', quotations) if q.strip()]
            if not quote_entries:
                errors.append(f"{file_path}::{json_path}: cite tag for {ref_id!r} has no quotation entries")
            for qe in quote_entries:
                if not QUOTE_ENTRY_RE.match(qe):
                    errors.append(f"{file_path}::{json_path}: invalid quotation entry {qe!r} in cite tag (expected '\"text\" (p. N)' or '\"text\" (pp. N-M)')")
                else:
                    # Check p. vs pp. for individual quote entries
                    q_page = QUOTE_ENTRY_RE.match(qe).group(2)
                    if "-" in q_page and q_page.startswith("p.") and not q_page.startswith("pp."):
                        errors.append(f"{file_path}::{json_path}: quote page range {q_page!r} should use 'pp.' instead of 'p.'")
                    elif "-" not in q_page and q_page.startswith("pp."):
                        errors.append(f"{file_path}::{json_path}: quote single page {q_page!r} should use 'p.' instead of 'pp.'")
                        
        for m in MALFORMED_CITE_RE.finditer(value):
            json_path = format_path(path_parts)
            errors.append(f"{file_path}::{json_path}: malformed cite tag near: ...{value[max(0,m.start()-10):m.end()+20]}...")

    missing_ref_ids = sorted(cited_ref_id for cited_ref_id in cited_ref_ids if cited_ref_id not in ref_id_set)
    for missing_ref_id in missing_ref_ids:
        errors.append(f"{file_path}::$: cite id {missing_ref_id!r} is used but missing from references[]")

    unused_ref_ids = sorted(ref_id for ref_id in ref_id_set if ref_id not in cited_ref_ids)
    for unused_ref_id in unused_ref_ids:
        errors.append(f"{file_path}::$.references: reference id {unused_ref_id!r} is never cited")

    defined_terms = payload.get("defined_terms") or []
    term_ids_seen: set[str] = set()
    term_surfaces_seen: set[str] = set()
    for idx, entry in enumerate(defined_terms):
        if not isinstance(entry, dict):
            continue
        term_id = entry.get("id")
        term_surface = entry.get("term")
        if isinstance(term_id, str):
            if term_id in term_ids_seen:
                errors.append(f"{file_path}::$.defined_terms[{idx}].id: duplicate term id {term_id!r}")
            term_ids_seen.add(term_id)
        if isinstance(term_surface, str):
            if term_surface in term_surfaces_seen:
                errors.append(f"{file_path}::$.defined_terms[{idx}].term: duplicate term surface {term_surface!r}")
            term_surfaces_seen.add(term_surface)

    if defined_terms:
        search_corpus_parts: list[str] = []
        for path_parts, value in iter_strings(payload):
            if path_parts and path_parts[0] == "defined_terms":
                continue
            search_corpus_parts.append(value)
        search_corpus = "\n".join(search_corpus_parts)
        for idx, entry in enumerate(defined_terms):
            if not isinstance(entry, dict):
                continue
            term_surface = entry.get("term")
            if not isinstance(term_surface, str) or not term_surface:
                continue
            boundary_pattern = (
                r"(?<![A-Za-z0-9\-])"
                + re.escape(term_surface)
                + r"(?![A-Za-z0-9\-])"
            )
            if not re.search(boundary_pattern, search_corpus):
                errors.append(
                    f"{file_path}::$.defined_terms[{idx}]: term {term_surface!r} does not appear verbatim in any prose field"
                )

    if URL_MODE != "off":
        for index, ref in enumerate(references):
            if not isinstance(ref, dict):
                continue
            raw_url = ref.get("url")
            if not isinstance(raw_url, str) or not raw_url.strip():
                continue

            scheme = urlparse(raw_url).scheme.lower()
            if scheme not in {"http", "https"}:
                continue

            issue = check_url_reachability(raw_url)
            if issue:
                warnings.append(f"{file_path}::$.references[{index}].url: {issue} for {raw_url}")

if errors:
    print("Dataset integrity errors were encountered.", file=sys.stderr)
    for error in errors:
        print(f"  {error}", file=sys.stderr)
    raise SystemExit(1)

if warnings:
    label = "errors" if URL_MODE == "error" else "warnings"
    header = "Dataset URL reachability errors were encountered." if URL_MODE == "error" else "Dataset URL reachability warnings were encountered."
    stream = sys.stderr if URL_MODE == "error" else sys.stdout
    print(header, file=stream)
    for warning in warnings:
        print(f"  {warning}", file=stream)
    if URL_MODE == "error":
        raise SystemExit(1)
    print(f"WARN - Dataset URL reachability ({len(warnings)} {label} across {checked_urls} urls)")

print(f"OK - Dataset integrity checks ({len(DATA_FILES)} files)")
PY
