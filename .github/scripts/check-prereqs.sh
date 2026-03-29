#!/usr/bin/env sh
set -eu

missing_tools=""
missing_schema_validator=0

append_missing() {
  if [ -n "$missing_tools" ]; then
    missing_tools="${missing_tools}
- $1"
  else
    missing_tools="- $1"
  fi
}

for tool in git python3 jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    append_missing "$tool"
  fi
done

if command -v check-jsonschema >/dev/null 2>&1; then
  :
elif command -v python3 >/dev/null 2>&1 && python3 -m check_jsonschema --version >/dev/null 2>&1; then
  :
else
  missing_schema_validator=1
  append_missing "check-jsonschema"
fi

if [ -n "$missing_tools" ]; then
  echo "Missing required tools for local validation:" >&2
  printf '%s\n' "$missing_tools" >&2
  if [ "$missing_schema_validator" -eq 1 ]; then
    echo >&2
    echo "Install Python dependencies with:" >&2
    echo "  python3 -m pip install -r .github/requirements-ci.txt" >&2
  fi
  exit 1
fi

echo "OK - Validation prerequisites"
