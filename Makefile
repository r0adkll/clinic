.PHONY: setup ghostty project build test release clean

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
	xcodebuild -project Clinic.xcodeproj -scheme Clinic -configuration Debug -derivedDataPath build build | tail -20

test:
	swift test --package-path Packages/ClinicCore
	swift test --package-path Packages/GhosttyBridge

release:
	scripts/release.sh

clean:
	rm -rf build Clinic.xcodeproj Packages/*/.build
