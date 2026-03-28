#!/usr/bin/env sh
set -eu

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required to validate repository metadata" >&2
  exit 1
fi

python3 - <<'PY'
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

required_paths = [
    Path("README.md"),
    Path("CONTRIBUTING.md"),
    Path("LICENSE"),
    Path("CITATION.cff"),
    Path("datapackage.json"),
    Path("schemas"),
]

errors: list[str] = []

for path in required_paths:
    if not path.exists():
        errors.append(f"Required repository metadata path is missing: {path}")

if not errors:
    datapackage = json.loads(Path("datapackage.json").read_text(encoding="utf-8"))
    datapackage_version = datapackage.get("version")
    if not isinstance(datapackage_version, str) or not datapackage_version.strip():
        errors.append("datapackage.json is missing a non-empty string version")

    citation_text = Path("CITATION.cff").read_text(encoding="utf-8")
    version_match = re.search(r'^version:\s*["\']?([^"\']+)["\']?\s*$', citation_text, re.MULTILINE)
    if not version_match:
        errors.append("CITATION.cff is missing a top-level version field")
    else:
        citation_version = version_match.group(1).strip()
        if not citation_version:
            errors.append("CITATION.cff version field is empty")
        elif isinstance(datapackage_version, str) and datapackage_version.strip() and citation_version != datapackage_version:
            errors.append(
                "Version mismatch between CITATION.cff and datapackage.json: "
                f"{citation_version!r} != {datapackage_version!r}"
            )

if errors:
    print("Repository metadata validation failed.", file=sys.stderr)
    for error in errors:
        print(f"  {error}", file=sys.stderr)
    raise SystemExit(1)

print(f"OK - Repository metadata ({datapackage_version})")
PY
