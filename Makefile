PROJECT := Arrow.xcodeproj
DERIVED := build/DerivedData
APP := $(DERIVED)/Build/Products/Debug/Arrow.app
XCODEBUILD := xcodebuild -project $(PROJECT) -scheme Arrow -derivedDataPath $(DERIVED)

.PHONY: all cef project build release dist run test lint server-test clean

all: build

cef:
	./scripts/fetch-cef.sh

project:
	xcodegen generate

build: project
	$(XCODEBUILD) -configuration Debug build

release: project
	$(XCODEBUILD) -configuration Release build

# Signed DMG for distribution: make dist TEAM=<team ID> [NOTARIZE=1]
dist:
	./scripts/dist.sh

run: build
	open $(APP)

lint:
	swiftlint lint --strict

test:
	cd Packages/ArrowKit && swift test

server-test:
	cd server && go vet ./... && go test ./...

clean:
	rm -rf build $(PROJECT)
