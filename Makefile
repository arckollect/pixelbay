.DEFAULT_GOAL := help

DEVELOPER_DIR ?= /Applications/Xcode-26.4.0.app/Contents/Developer
SWIFT_TEST := DEVELOPER_DIR="$(DEVELOPER_DIR)" xcrun swift test
XCODEBUILD := DEVELOPER_DIR="$(DEVELOPER_DIR)" xcodebuild

PACKAGES := PixelbayCore PixelbayDesignSystem PixelbayPermissions PixelbayCapture PixelbayRecording PixelbayCompositor PixelbayPlayback PixelbayInputCapture PixelbayEditor PixelbayTimelineUI

.PHONY: help test test-% build clean ci release-dryrun

help:
	@echo "Pixelbay developer Makefile (HANDOFF §6.8)"
	@echo ""
	@echo "  make test            Run all package test suites (10/10/29/12/8/9/7/51/42 = 178 tests)"
	@echo "  make test-<package>  Run a single package's tests, e.g. make test-PixelbayCapture"
	@echo "  make build           Build the PixelbayApp.xcodeproj via the workspace"
	@echo "  make ci              test + build (use this in CI pipelines)"
	@echo "  make release-dryrun  Dry-run the v0.1 ship pipeline (archive/sign/notarize/DMG/appcast)"
	@echo "  make clean           Remove .build/ caches in each package + DerivedData"
	@echo ""
	@echo "Override DEVELOPER_DIR if you use a different Xcode:"
	@echo "  make test DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer"

test:
	@for pkg in $(PACKAGES); do \
		echo "=== $$pkg ==="; \
		out=$$(mktemp); \
		if (cd Packages/$$pkg && $(SWIFT_TEST)) > "$$out" 2>&1; then \
			awk '/Executed [0-9]+ tests/ { line = $$0 } /Test run with [0-9]+ tests/ { fallback = $$0 } END { if (line) print line; else if (fallback) print fallback; else exit 1 }' "$$out" || tail -20 "$$out"; \
		else \
			cat "$$out"; \
			rm -f "$$out"; \
			exit 1; \
		fi; \
		rm -f "$$out"; \
	done

# `make test-PixelbayCapture` — single package
test-%:
	@echo "=== $* ==="
	@cd Packages/$* && $(SWIFT_TEST)

build:
	@out=$$(mktemp); \
	if $(XCODEBUILD) -workspace Pixelbay.xcworkspace -scheme PixelbayApp -configuration Debug -destination 'platform=macOS' build > "$$out" 2>&1; then \
		grep -E "error:|warning:|BUILD " "$$out" | grep -v "AppIntents" || true; \
	else \
		grep -E "error:|warning:|BUILD " "$$out" | grep -v "AppIntents" || cat "$$out"; \
		rm -f "$$out"; \
		exit 1; \
	fi; \
	rm -f "$$out"

ci: test build

release-dryrun:
	@Scripts/release-v0.1.sh --dry-run

clean:
	@for pkg in $(PACKAGES); do \
		rm -rf Packages/$$pkg/.build; \
	done
	@rm -rf ~/Library/Developer/Xcode/DerivedData/Pixelbay-*
	@echo "Cleaned .build/ caches and Pixelbay DerivedData"
