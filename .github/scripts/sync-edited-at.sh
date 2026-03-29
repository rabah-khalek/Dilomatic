#!/usr/bin/env sh
set -eu

if ! command -v git >/dev/null 2>&1; then
  echo "git is required to sync edited_at on uncommitted data files" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required to sync edited_at on uncommitted data files" >&2
  exit 1
fi

python3 - <<'PY'
from __future__ import annotations

import json
import re
import subprocess
import sys
from datetime import date
from pathlib import Path

DATA_DIR = Path("data")
TODAY = date.today().isoformat()
EDITED_AT_RE = re.compile(r'("edited_at"\s*:\s*")([^"\n]*)(")')


def git_stdout(*args: str) -> str:
    completed = subprocess.run(
        ["git", *args],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if completed.returncode != 0:
        message = completed.stderr.strip() or completed.stdout.strip() or f"git {' '.join(args)} failed"
        print(message, file=sys.stderr)
        raise SystemExit(1)
    return completed.stdout


def split_null_terminated(output: str) -> list[str]:
    return [entry for entry in output.split("\0") if entry]


def head_exists() -> bool:
    return (
        subprocess.run(
            ["git", "rev-parse", "--verify", "HEAD"],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        ).returncode
        == 0
    )


def candidate_paths() -> list[Path]:
    paths: set[Path] = set()

    if head_exists():
        paths.update(
            Path(entry)
            for entry in split_null_terminated(
                git_stdout("diff", "--name-only", "-z", "--diff-filter=ACMR", "HEAD", "--", "data")
            )
        )
    else:
        paths.update(
            Path(entry)
            for entry in split_null_terminated(
                git_stdout("diff", "--name-only", "-z", "--diff-filter=ACMR", "--", "data")
            )
        )
        paths.update(
            Path(entry)
            for entry in split_null_terminated(
                git_stdout("diff", "--cached", "--name-only", "-z", "--diff-filter=ACMR", "--", "data")
            )
        )

    paths.update(
        Path(entry)
        for entry in split_null_terminated(
            git_stdout("ls-files", "--others", "--exclude-standard", "-z", "--", "data")
        )
    )

    return sorted(
        path
        for path in paths
        if path.parent == DATA_DIR and path.suffix == ".json" and path.is_file()
    )


updated: list[str] = []
warnings: list[str] = []

for path in candidate_paths():
    try:
        raw_text = path.read_text(encoding="utf-8")
        payload = json.loads(raw_text)
    except json.JSONDecodeError as exc:
        warnings.append(f"{path}: skipped edited_at sync because JSON is invalid ({exc.msg})")
        continue

    if not isinstance(payload, dict):
        warnings.append(f"{path}: skipped edited_at sync because the top-level JSON value is not an object")
        continue

    if payload.get("edited_at") == TODAY:
        continue

    updated_text, replacements = EDITED_AT_RE.subn(rf"\g<1>{TODAY}\g<3>", raw_text, count=1)
    if replacements == 0:
        warnings.append(f"{path}: skipped edited_at sync because no string edited_at field was found")
        continue

    path.write_text(updated_text, encoding="utf-8")
    updated.append(str(path))

for warning in warnings:
    print(f"WARN - {warning}", file=sys.stderr)

if updated:
    count = len(updated)
    suffix = "" if count == 1 else "s"
    print(f"OK - edited_at sync ({count} file{suffix} updated)")
    for path in updated:
        print(f"  {path}")
    print("  Re-stage updated files if they were already staged.")
else:
    print("OK - edited_at sync (no updates)")
PY
