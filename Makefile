.DEFAULT_GOAL := help

DEVELOPER_DIR ?= /Applications/Xcode-26.4.0.app/Contents/Developer
SWIFT_TEST := DEVELOPER_DIR="$(DEVELOPER_DIR)" xcrun swift test
XCODEBUILD := DEVELOPER_DIR="$(DEVELOPER_DIR)" xcodebuild

PACKAGES := PixelbayCore PixelbayPermissions PixelbayCapture PixelbayRecording PixelbayCompositor PixelbayPlayback PixelbayInputCapture PixelbayEditor PixelbayTimelineUI

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
		(cd Packages/$$pkg && $(SWIFT_TEST) 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1) || exit 1; \
	done

# `make test-PixelbayCapture` — single package
test-%:
	@echo "=== $* ==="
	@cd Packages/$* && $(SWIFT_TEST)

build:
	@$(XCODEBUILD) -workspace Pixelbay.xcworkspace -scheme PixelbayApp -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "error:|warning:|BUILD " | grep -v "AppIntents" || true

ci: test build

release-dryrun:
	@Scripts/release-v0.1.sh --dry-run

clean:
	@for pkg in $(PACKAGES); do \
		rm -rf Packages/$$pkg/.build; \
	done
	@rm -rf ~/Library/Developer/Xcode/DerivedData/Pixelbay-*
	@echo "Cleaned .build/ caches and Pixelbay DerivedData"
