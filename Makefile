EVENT_FILES := $(wildcard data/*.json)
SCHEMA_FILES := $(wildcard schemas/*/schema.json schemas/*/template.json)
SCRIPT_DIR := .github/scripts

.PHONY: validate validate-prereqs sync-edited-at validate-metadata validate-json validate-schema validate-integrity validate-quotes validate-security

validate: validate-prereqs sync-edited-at
	@$(MAKE) validate-metadata validate-json validate-schema validate-integrity validate-quotes validate-security

validate-prereqs: $(SCRIPT_DIR)/check-prereqs.sh
	@./$(SCRIPT_DIR)/check-prereqs.sh

sync-edited-at: $(SCRIPT_DIR)/sync-edited-at.sh
	@./$(SCRIPT_DIR)/sync-edited-at.sh

validate-metadata: $(SCRIPT_DIR)/validate-metadata.sh
	@./$(SCRIPT_DIR)/validate-metadata.sh

validate-json: $(EVENT_FILES) $(SCRIPT_DIR)/validate-json.sh
	@./$(SCRIPT_DIR)/validate-json.sh

validate-schema: $(EVENT_FILES) $(SCRIPT_DIR)/validate-schema.sh
	@./$(SCRIPT_DIR)/validate-schema.sh

validate-integrity: $(EVENT_FILES) $(SCRIPT_DIR)/integrity-check.sh
	@./$(SCRIPT_DIR)/integrity-check.sh

validate-quotes: $(EVENT_FILES) $(SCRIPT_DIR)/validate-quotes.sh
	@./$(SCRIPT_DIR)/validate-quotes.sh

validate-security: $(EVENT_FILES) $(SCHEMA_FILES) $(SCRIPT_DIR)/security-check.sh
	@./$(SCRIPT_DIR)/security-check.sh
