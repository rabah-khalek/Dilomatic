# Contributing To Dilomatic

Dilomatic accepts new event records, corrections, and metadata improvements.

## Core Principles

When contributing data, please adhere to the following principles:

1. **Neutral Point of View (NPOV):** Political history is inherently complex and often biased. All contributions must be written from a neutral, objective standpoint. Avoid editorializing, moralizing, or using loaded language.
2. **High-Quality Citations:** Claims must be backed by reliable sources (e.g., academic papers, historical texts, primary documents). Use the `references` array to cite your sources properly. When a source has identifiable authors, link it with `references[].author_ids` and add a matching `cited_authors` entry with a short `bio`. If a citation tooltip should show verbatim evidence, store it under `references[].excerpts` and cite it inline with `{{cite|ref_id|pages|excerpt_id}}`. Reserve `defined_terms` for concepts that genuinely need explanation and appear verbatim in the record's prose; do not pollute it with terms already clarified in context.
3. **Documenting Disputed Outcomes:** Historians often disagree on *why* a strategy worked or failed. Instead of forcing a single "truth," use the `historiography` section to document both sides of a historical debate.

## Adding A New Event

- [**Google Form**](https://forms.gle/pnT5Lho3zrvgvVB96) (no GitHub account needed)
- [**GitHub issue form**](https://github.com/rabah-khalek/dilomatic/issues/new?template=01-event-submission.yml) (for GitHub users)

Both automatically generate a validated pull request.

## Updating An Existing Event

1. Edit the matching file in `data/`.
2. Run `make validate`.
3. Open a pull request summarizing the change and citing your sources for the correction.

## Licensing

By contributing data, you agree that event records are licensed under CC BY 4.0.

## Technical Reference

### Local Validation Requirements

- `make`
- `git`
- `python3`
- `jq`
- `check-jsonschema` (install with `python3 -m pip install -r .github/requirements-ci.txt`)

### Manual Pull Request

1. Copy the latest template (e.g. [`schemas/v1/template.json`](schemas/v1/template.json)) to `data/<your-record-id>.json`.
2. Fill in the record using the matching schema (e.g. [`schemas/v1/schema.json`](schemas/v1/schema.json)) as the source of truth. If your sources have identifiable authors, populate `references[].author_ids` and the top-level `cited_authors` array together. If you want cite tooltips to display verbatim evidence, put those quotations in `references[].excerpts` and refer to them from prose with `excerpt_id`.
3. Validate before you open a PR:
   ```bash
   make validate
   ```

### Schema Changes

As the dataset grows, the JSON schema may need to evolve to support new types of historical events.

- Every record-shape change should get a new directory under `schemas/` (e.g. `schemas/v2/`) with its own `schema.json` and `template.json`.
- **Backward-compatible additions:** open a PR with the new schema version and explain the use case.
- **Breaking changes:** open an issue first so migration and compatibility strategy can be discussed. Data migration scripts will be required for breaking changes to keep older records uniform.
