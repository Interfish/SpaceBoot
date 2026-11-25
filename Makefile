SHELL := /usr/bin/env bash
APP_NAME := SpaceBoot
INSTALL_DIR ?= /Applications
BUILD_SCRIPT := ./scripts/build.sh

SIGN_FLAGS := $(if $(CODESIGN_IDENTITY),--sign "$(CODESIGN_IDENTITY)",)
VERSION_FLAGS := $(if $(VERSION),--version "$(VERSION)",)
BUILD_NUM_FLAGS := $(if $(BUILD_NUMBER),--build-number "$(BUILD_NUMBER)",)
COMMON_FLAGS := $(SIGN_FLAGS) $(VERSION_FLAGS) $(BUILD_NUM_FLAGS)

.DEFAULT_GOAL := build

.PHONY: build debug universal install run package icon clean help

build: ## Build release SpaceBoot.app into ./build/
	@$(BUILD_SCRIPT) --configuration release $(COMMON_FLAGS)

debug: ## Build debug SpaceBoot.app into ./build/
	@$(BUILD_SCRIPT) --configuration debug $(COMMON_FLAGS)

universal: ## Build universal (arm64 + x86_64) release SpaceBoot.app into ./build/
	@$(BUILD_SCRIPT) --configuration release --arch universal $(COMMON_FLAGS)

install: ## Build and install SpaceBoot.app into $(INSTALL_DIR)
	@INSTALL_DIR="$(INSTALL_DIR)" $(BUILD_SCRIPT) --configuration release --install $(COMMON_FLAGS)

run: install ## Build, install, and (re)launch SpaceBoot.app
	@pkill -x "$(APP_NAME)" 2>/dev/null || true
	@sleep 0.3
	@open "$(INSTALL_DIR)/$(APP_NAME).app"

package: ## Build universal .dmg and .zip release archives + .sha256 checksums in ./build/
	@$(BUILD_SCRIPT) --configuration release --arch universal --package $(COMMON_FLAGS)

icon: ## Regenerate Resources/AppIcon.icns and docs/icon.png
	@swift ./scripts/generate-icon.swift

clean: ## Remove build artifacts (build/ and .build/)
	@rm -rf build .build

help: ## Show available make targets
	@awk 'BEGIN {FS = ":.*## "; printf "Usage:\n  make <target> [CODESIGN_IDENTITY=...] [INSTALL_DIR=...] [VERSION=...]\n\nTargets:\n"} /^[a-zA-Z0-9_-]+:.*## / { printf "  %-12s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
