CONFIG ?= Debug
APP := .build/xcode/Build/Products/$(CONFIG)/Strata.app
XCODEBUILD := xcodebuild -project Strata.xcodeproj -scheme Strata -derivedDataPath .build/xcode -destination 'platform=macOS,arch=arm64'

.PHONY: project build release install run selftest clean

project:
	@xcodegen generate --quiet

build: project
	@mkdir -p .build
	@$(XCODEBUILD) -configuration $(CONFIG) build > .build/build.log 2>&1 || { grep -E '\.swift:[0-9]+:[0-9]+: error|BUILD FAILED' .build/build.log | sort -u; exit 1; }
	@grep -E '\.swift:[0-9]+:[0-9]+: warning' .build/build.log | sort -u || true
	@echo "Built $(APP)"

release:
	@$(MAKE) build CONFIG=Release

# Release build into /Applications, replacing (and quitting) any copy there.
install: release
	@pkill -x Strata || true
	@rm -rf /Applications/Strata.app
	@ditto .build/xcode/Build/Products/Release/Strata.app /Applications/Strata.app
	@/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Strata.app
	@open /Applications/Strata.app
	@echo "Installed /Applications/Strata.app"

run: build
	open $(APP)

selftest: build
	$(APP)/Contents/MacOS/Strata --self-test

clean:
	rm -rf .build Strata.xcodeproj
