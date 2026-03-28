# Dilomatic

Dilomatic is the public dataset of historical political dilemmas. It contains one JSON record per event, a shared schema, a contributor template, and GitHub-based validation and submission flow.

## Repository Structure

- [`data/`](data)
  The dataset itself. One JSON file per event.
- [`schemas/`](schemas)
  Versioned schema directories (`schemas/v1/schema.json`, `schemas/v1/template.json`, etc.). Each record's `schema_version` points to its matching directory.
- [`CONTRIBUTING.md`](CONTRIBUTING.md)
  The contributor workflow.

## Contribute

Suggest an event via the [**Google Form**](https://forms.gle/pnT5Lho3zrvgvVB96) (no GitHub account needed) or the [**GitHub issue form**](https://github.com/rabah-khalek/dilomatic/issues/new?template=01-event-submission.yml).

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full workflow.

## License

- Dataset: [CC BY 4.0](LICENSE)
