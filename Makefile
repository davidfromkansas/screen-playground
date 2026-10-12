# Screen Playground developer commands.
DERIVED := build/DerivedData
APP := $(DERIVED)/Build/Products/Debug/Screen Playground.app
PGCTL := $(DERIVED)/Build/Products/Debug/pgctl

.PHONY: gen build run test test-fast pgctl e2e clean

gen:
	xcodegen generate --quiet

build: gen
	xcodebuild -project ScreenPlayground.xcodeproj -scheme ScreenPlayground -configuration Debug \
		-derivedDataPath $(DERIVED) -destination 'platform=macOS' build | xcbeautify 2>/dev/null || \
	xcodebuild -project ScreenPlayground.xcodeproj -scheme ScreenPlayground -configuration Debug \
		-derivedDataPath $(DERIVED) -destination 'platform=macOS' -quiet build

pgctl: gen
	xcodebuild -project ScreenPlayground.xcodeproj -target pgctl -configuration Debug \
		SYMROOT=$(CURDIR)/$(DERIVED)/Build/Products -quiet build

run: build
	open "$(APP)"

test-fast:
	cd Packages/PlaygroundKit && swift test --filter "PlaygroundCoreTests|TimelineTests|MotionTests|CompositionTests"

test:
	cd Packages/PlaygroundKit && swift test

e2e: pgctl
	./scripts/e2e.sh "$(PGCTL)"

clean:
	rm -rf build ScreenPlayground.xcodeproj
