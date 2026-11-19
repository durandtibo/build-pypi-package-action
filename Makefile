SHELL = /bin/bash

include .make/all.mk

.PHONY: check-export
check-export: ## Check that the exported files are the files the action needs
	./dev/check_export.sh

.PHONY: check-readme
check-readme: ## Check that README.md documents the inputs and outputs of action.yaml
	./dev/check_readme.sh

.PHONY: test
test: check-export check-readme ## Run the local tests (the action itself is tested by GitHub Actions)

.PHONY: all
all: format lint test ## Format, lint and test

.PHONY: clean
clean: ## Remove the temporary files (see .gitignore)
	rm -f ./*.tmp ./*.bak ./*.log
