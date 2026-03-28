#!/usr/bin/env sh
set -eu

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required to resolve record schema versions" >&2
  exit 1
fi

if [ ! -d schemas ]; then
  echo "schemas/ directory not found" >&2
  exit 1
fi

set -- data/*.json
if [ "$1" = "data/*.json" ]; then
  echo "No event JSON files found in data/" >&2
  exit 1
fi

if command -v check-jsonschema >/dev/null 2>&1; then
  CMD="check-jsonschema"
elif python3 -m check_jsonschema --version >/dev/null 2>&1; then
  CMD="python3 -m check_jsonschema"
else
  echo "check-jsonschema is required to validate against schemas/<version>/schema.json" >&2
  echo "Install it with: pip install check-jsonschema" >&2
  exit 1
fi

COUNT=0
for record in "$@"; do
  SCHEMA_VERSION="$(jq -r '.schema_version // empty' "$record")"
  if [ -z "$SCHEMA_VERSION" ]; then
    echo "schema_version is missing in $record" >&2
    exit 1
  fi

  SCHEMA_PATH="schemas/${SCHEMA_VERSION}/schema.json"
  if [ ! -f "$SCHEMA_PATH" ]; then
    echo "No schema file found for schema_version $SCHEMA_VERSION ($record)" >&2
    exit 1
  fi

  if ! PYTHONWARNINGS=ignore $CMD --quiet --schemafile "$SCHEMA_PATH" "$record" 2>/dev/null; then
    echo "Schema validation failed for $record against $SCHEMA_PATH" >&2
    PYTHONWARNINGS=ignore $CMD --schemafile "$SCHEMA_PATH" "$record" 2>&1 | grep -v '^ok'
    exit 1
  fi

  COUNT=$((COUNT + 1))
done

# Validate all versioned schema files as JSON Schemas against their metaschemas
for schema_file in schemas/v*/schema.json; do
  if ! PYTHONWARNINGS=ignore $CMD --quiet --check-metaschema "$schema_file" 2>/dev/null; then
    echo "Schema metaschema validation failed for $schema_file" >&2
    PYTHONWARNINGS=ignore $CMD --check-metaschema "$schema_file" 2>&1 | grep -v '^ok'
    exit 1
  fi
done

# Infer latest version (highest vN directory)
LATEST=$(ls -d schemas/v*/ 2>/dev/null | sort -V | tail -1 | xargs basename)
if [ -z "$LATEST" ]; then
  echo "No versioned schema directories found in schemas/" >&2
  exit 1
fi

# Every versioned schema directory must ship with a template.json
for version_dir in schemas/v*/; do
  version_name="$(basename "$version_dir")"
  if [ ! -f "${version_dir}template.json" ]; then
    echo "schemas/${version_name}/template.json is missing -- every schema version must include a template" >&2
    exit 1
  fi
  if ! PYTHONWARNINGS=ignore $CMD --quiet --schemafile "${version_dir}schema.json" "${version_dir}template.json" 2>/dev/null; then
    echo "Template validation failed for schemas/${version_name}/" >&2
    PYTHONWARNINGS=ignore $CMD --schemafile "${version_dir}schema.json" "${version_dir}template.json" 2>&1 | grep -v '^ok'
    exit 1
  fi
  COUNT=$((COUNT + 1))
done

echo "OK - Dataset schema validation ($COUNT files)"
