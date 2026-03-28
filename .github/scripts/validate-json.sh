#!/usr/bin/env sh
set -eu

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required to validate JSON event files" >&2
  exit 1
fi

if [ ! -d data ]; then
  echo "data directory not found" >&2
  exit 1
fi

set -- data/*.json
if [ "$1" = "data/*.json" ]; then
  echo "No event JSON files found in data/" >&2
  exit 1
fi

jq '.' "$@" >/dev/null
echo "OK - Dataset JSON syntax ($# files)"
