APP := build/Build/Products/Debug/Muxify.app
RELEASE_APP := build/Build/Products/Release/Muxify.app
INSTALL_DIR ?= /Applications

.PHONY: all setup tools project build cli test test-release run install release clean

all: build

setup: tools
	@if [ ! -f vendor/ghostty/lib/libghostty.a ] || \
	    [ ! -f vendor/ghostty/include/ghostty.h ] || \
	    [ ! -f vendor/ghostty/build-info.json ] || \
	    [ ! -f vendor/ghostty/resources/terminfo/78/xterm-ghostty ] || \
	    [ ! -d vendor/ghostty/resources/ghostty/themes ] || \
	    [ ! -f vendor/ghostty/resources/ghostty/shell-integration/zsh/ghostty-integration ]; then \
		./scripts/setup-ghostty.sh; \
	fi

tools:
	command -v xcodegen >/dev/null || brew install xcodegen

project: setup
	xcodegen generate --quiet

build: project
	xcodebuild -project Muxify.xcodeproj -scheme Muxify -configuration Debug \
		-derivedDataPath build -clonedSourcePackagesDirPath build/SourcePackages -quiet build

# Build only the CLI, without desktop app dependencies.
cli:
	/bin/sh scripts/build-cli.sh build/bin
	/bin/sh scripts/bundle-simulator-notices.sh build/bin/ThirdPartyNotices

test: project
	swift test
	node --test Tests/SimulatorWeb/*.test.mjs
	xcodebuild -project Muxify.xcodeproj -scheme Muxify -configuration Debug \
		-derivedDataPath build -clonedSourcePackagesDirPath build/SourcePackages test

test-release:
	python3 -m unittest discover -s Tests/ReleaseTests -v

run: build
	open $(APP)

release:
	BUILD_NUMBER="$(or $(BUILD_NUMBER),1)" ./scripts/package-release.sh "$(TAG)"

install: project
	xcodebuild -project Muxify.xcodeproj -scheme Muxify -configuration Release \
		-derivedDataPath build -clonedSourcePackagesDirPath build/SourcePackages -quiet build
	rm -rf "$(INSTALL_DIR)/Muxify.app"
	cp -R "$(RELEASE_APP)" "$(INSTALL_DIR)/"

clean:
	rm -rf build Muxify.xcodeproj
