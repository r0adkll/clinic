.PHONY: setup ghostty project build dev dev-build dev-stop dev-reset test release publish screenshots clean

setup:
	brew install xcodegen zig@0.15 gettext
	git submodule update --init
	@xcrun -sdk macosx metal --version >/dev/null 2>&1 || echo "Run: xcodebuild -downloadComponent MetalToolchain"

ghostty:
	scripts/build-ghostty.sh

project:
	@[ -f Local.xcconfig ] || cp Local.xcconfig.example Local.xcconfig
	xcodegen generate

build: project
	xcodebuild -project Clinic.xcodeproj -scheme Clinic -configuration Debug -derivedDataPath build -skipPackagePluginValidation -skipMacroValidation build | tail -20

# Clinic Dev (ADR-176): its own bundle id, preferences, data directory and derived data, so it runs beside
# the Clinic you work in and shares nothing with it. `make dev` builds, quits the running one and relaunches.
dev:
	scripts/dev

dev-build:
	scripts/dev build

dev-stop:
	scripts/dev stop

# Deletes ~/Library/Application Support/Clinic Dev and the com.r0adkll.clinic.dev preferences.
dev-reset:
	scripts/dev reset

test:
	swift test --package-path Packages/ClinicCore
	swift test --package-path Packages/GhosttyBridge

release:
	scripts/release.sh

# make publish                    releases the version in Version.xcconfig
# make publish VERSION=0.3.0      bumps to it and commits first (ADR-169); ARGS="--dry-run" passes flags
publish:
	scripts/publish $(VERSION) $(ARGS)

screenshots:
	scripts/screenshots/run

clean:
	rm -rf build Clinic.xcodeproj Packages/*/.build
