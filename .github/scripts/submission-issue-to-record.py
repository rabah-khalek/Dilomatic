#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import re
import sys
from datetime import datetime
from pathlib import Path
from typing import Any


FORM_PREFIX = "[Submission]"
NO_RESPONSE = "_No response_"
HEADING_RE = re.compile(r"^###\s+(?P<label>.+?)\s*$")
CODE_FENCE_RE = re.compile(r"^```[^\n]*\n(?P<body>[\s\S]*?)\n```$", re.MULTILINE)
CHECKBOX_RE = re.compile(r"^- \[(?P<checked>[ xX])\]\s+(?P<label>.+?)\s*$")
BULLET_RE = re.compile(r"^-+\s+")



class SubmissionError(Exception):
    pass


def read_event_payload() -> dict[str, Any]:
    event_path = os.environ.get("GITHUB_EVENT_PATH")
    if not event_path:
        raise SubmissionError("GITHUB_EVENT_PATH is not set")
    with open(event_path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def parse_sections(body: str) -> dict[str, str]:
    sections: dict[str, str] = {}
    current_label: str | None = None
    current_lines: list[str] = []

    for line in body.splitlines():
        heading = HEADING_RE.match(line)
        if heading:
            if current_label is not None:
                sections[current_label] = "\n".join(current_lines).strip()
            current_label = heading.group("label")
            current_lines = []
            continue

        if current_label is not None:
            current_lines.append(line)

    if current_label is not None:
        sections[current_label] = "\n".join(current_lines).strip()

    if not sections:
        raise SubmissionError("Issue body does not look like a supported GitHub Issue Form submission")

    return sections


def strip_code_fence(value: str) -> str:
    stripped = value.strip()
    match = CODE_FENCE_RE.match(stripped)
    if match:
        return match.group("body").strip()
    return stripped


def normalized_scalar(value: str | None) -> str | None:
    if value is None:
        return None
    stripped = strip_code_fence(value).strip()
    if not stripped or stripped == NO_RESPONSE:
        return None
    return stripped


def require_scalar(sections: dict[str, str], label: str) -> str:
    value = normalized_scalar(sections.get(label))
    if value is None:
        raise SubmissionError(f"Missing required field: {label}")
    return value


def parse_int_field(sections: dict[str, str], label: str, required: bool = True) -> int | None:
    raw_value = require_scalar(sections, label) if required else normalized_scalar(sections.get(label))
    if raw_value is None:
        return None
    try:
        return int(raw_value)
    except ValueError as exc:
        raise SubmissionError(f"{label} must be an integer, got {raw_value!r}") from exc


def parse_list_lines(sections: dict[str, str], label: str) -> list[str]:
    raw_value = normalized_scalar(sections.get(label))
    if raw_value is None:
        return []

    values: list[str] = []
    for raw_line in raw_value.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        checkbox = CHECKBOX_RE.match(line)
        if checkbox:
            if checkbox.group("checked").lower() == "x":
                values.append(checkbox.group("label").strip())
            continue
        values.append(BULLET_RE.sub("", line).strip())

    return [value for value in values if value]


def parse_json_array(sections: dict[str, str], label: str, required: bool = False) -> list[Any]:
    raw_value = require_scalar(sections, label) if required else normalized_scalar(sections.get(label))
    if raw_value is None:
        return []

    try:
        parsed = json.loads(strip_code_fence(raw_value))
    except json.JSONDecodeError as exc:
        raise SubmissionError(f"{label} must be valid JSON: {exc}") from exc

    if not isinstance(parsed, list):
        raise SubmissionError(f"{label} must be a JSON array")

    return parsed


def parse_dilemma_category(sections: dict[str, str], label: str) -> list[str]:
    raw_value = require_scalar(sections, label)
    parts = [part.strip().lower() for part in raw_value.split("/") if part.strip()]
    if len(parts) != 2:
        raise SubmissionError(f"{label} must be two choices separated by '/', got {raw_value!r}")
    return parts


def sanitize_branch_component(value: str) -> str:
    value = value.lower()
    value = re.sub(r"[^a-z0-9-]+", "-", value)
    value = re.sub(r"-{2,}", "-", value)
    return value.strip("-")


def write_output(name: str, value: str) -> None:
    output_path = os.environ.get("GITHUB_OUTPUT")
    if not output_path:
        return

    with open(output_path, "a", encoding="utf-8") as handle:
        if "\n" in value:
            delimiter = "__DILOMATIC_OUTPUT__"
            handle.write(f"{name}<<{delimiter}\n{value}\n{delimiter}\n")
        else:
            handle.write(f"{name}={value}\n")


def main() -> int:
    event = read_event_payload()
    issue = event.get("issue") or {}
    issue_title = str(issue.get("title") or "")
    if not issue_title.startswith(FORM_PREFIX):
        raise SubmissionError(f"Issue title must start with {FORM_PREFIX!r}")

    issue_number = int(issue.get("number"))
    issue_body = str(issue.get("body") or "")
    if not issue_body.strip():
        raise SubmissionError("Issue body is empty")

    sections = parse_sections(issue_body)

    # Find the latest schema version directory (highest vN)
    schemas_dir = Path("schemas")
    if not schemas_dir.is_dir():
        raise SubmissionError("schemas/ directory not found")
    version_dirs = sorted(
        (d for d in schemas_dir.iterdir() if d.is_dir() and d.name.startswith("v")),
        key=lambda d: int(d.name[1:]) if d.name[1:].isdigit() else 0,
    )
    if not version_dirs:
        raise SubmissionError("No versioned schema directories found in schemas/")
    latest_dir = version_dirs[-1]

    template_path = latest_dir / "template.json"
    if not template_path.exists():
        raise SubmissionError(f"{template_path.as_posix()} not found")

    # Read schema_version from the template itself rather than inferring from the
    # directory name. This ensures the submission generator only targets a version
    # whose template has been explicitly updated, preventing a draft schemas/vN/
    # from silently hijacking all new submissions.
    with template_path.open("r", encoding="utf-8") as handle:
        template = json.load(handle)
    schema_version = template.get("schema_version")
    if not isinstance(schema_version, str) or not schema_version:
        raise SubmissionError(f"{template_path.as_posix()} is missing a valid schema_version")

    schema_path = schemas_dir / schema_version / "schema.json"
    if not schema_path.is_file():
        raise SubmissionError(f"{schema_path.as_posix()} not found")

    record_id = require_scalar(sections, "Record ID")
    if not re.fullmatch(r"[a-z0-9-]+", record_id):
        raise SubmissionError("Record ID must use lowercase letters, numbers, and hyphens only")

    output_path = Path("data") / f"{record_id}.json"
    if output_path.exists():
        raise SubmissionError(
            f"data/{record_id}.json already exists. Use a direct pull request for updates to existing records."
        )

    created_at = issue.get("created_at")
    updated_at = issue.get("updated_at") or created_at
    if not isinstance(created_at, str) or not isinstance(updated_at, str):
        raise SubmissionError("Issue timestamps are missing from the GitHub event payload")

    added_at = datetime.fromisoformat(created_at.replace("Z", "+00:00")).date().isoformat()
    edited_at = datetime.fromisoformat(updated_at.replace("Z", "+00:00")).date().isoformat()

    event_title = require_scalar(sections, "Event Title")
    geography = parse_list_lines(sections, "Geography")
    if not geography:
        raise SubmissionError("Geography must have at least one entry")
    conflict_types = parse_list_lines(sections, "Conflict Types")

    issue_author = (issue.get("user") or {}).get("login") or ""
    iso_country_code = normalized_scalar(sections.get("ISO Country Code"))

    record: dict[str, Any] = {
        "record_id": record_id,
        "schema_version": schema_version,
        "added_at": added_at,
        "edited_at": edited_at,
        "contributors": [
            {"name": issue_author, "github": issue_author, "role": "author"},
        ] if issue_author else [],
        "event": {
            "title": event_title,
            "time_period": {
                "start_year": parse_int_field(sections, "Start Year"),
                "end_year": parse_int_field(sections, "End Year", required=False),
            },
            "geography": geography,
            "context": require_scalar(sections, "Event Context"),
            "conflict_type": conflict_types,
            "core_dilemma": {
                "summary": require_scalar(sections, "Dilemma Summary"),
                "questions": parse_list_lines(sections, "Dilemma Questions"),
                "category": parse_dilemma_category(sections, "Dilemma Category"),
            },
        },
        "actors": parse_json_array(sections, "Actors JSON", required=True),
        "strategies": parse_json_array(sections, "Strategies JSON", required=True),
        "outcomes": {
            "description": require_scalar(sections, "Outcome Description"),
        },
        "assessment": {
            "verdict": require_scalar(sections, "Assessment Verdict"),
        },
        "references": parse_json_array(sections, "References JSON", required=True),
        "cited_authors": parse_json_array(sections, "Cited Authors JSON", required=True),
    }

    alternate_names = parse_list_lines(sections, "Alternate Names")
    if alternate_names:
        record["event"]["alternate_names"] = alternate_names

    if iso_country_code is not None:
        record["event"]["iso_country_code"] = iso_country_code

    triggering_event = normalized_scalar(sections.get("Triggering Event"))
    if triggering_event is not None:
        record["event"]["triggering_event"] = triggering_event

    timeline = parse_json_array(sections, "Timeline JSON")
    if timeline:
        record["event"]["timeline"] = timeline

    consequences = parse_json_array(sections, "Consequences JSON")
    if consequences:
        record["outcomes"]["consequences"] = consequences

    historiography = parse_json_array(sections, "Historiography JSON")
    if historiography:
        record["assessment"]["historiography"] = historiography

    related_events = parse_json_array(sections, "Related Events JSON")
    if related_events:
        record["related_events"] = related_events

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w", encoding="utf-8") as handle:
        json.dump(record, handle, indent=2, ensure_ascii=False)
        handle.write("\n")

    branch_name = f"submission/issue-{issue_number}-{sanitize_branch_component(record_id)}"
    pr_title = f"submission: add {record_id}"
    commit_message = f"submission: add {record_id} from issue #{issue_number}"

    write_output("record_id", record_id)
    write_output("event_title", event_title)
    write_output("file_path", output_path.as_posix())
    write_output("branch_name", branch_name)
    write_output("pr_title", pr_title)
    write_output("commit_message", commit_message)
    write_output("source_notes", normalized_scalar(sections.get("Source Notes")) or "")
    write_output("reviewer_notes", normalized_scalar(sections.get("Additional Reviewer Notes")) or "")

    print(f"OK - Submission record generated ({output_path.as_posix()})")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SubmissionError as exc:
        print(f"Submission generation failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
