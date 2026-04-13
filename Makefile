.PHONY: build build-swift build-parakeet build-python install clean setup

SWIFT_SOURCES = audiocapture/Sources/audiocapture/AudioCapture.swift \
                audiocapture/Sources/audiocapture/main.swift
SWIFT_OUT = audiocapture/.build/release/audiocapture
SDK_PATH = $(shell xcrun --show-sdk-path)

build: build-swift build-python

setup:
	./scripts/setup.sh

build-swift:
	@mkdir -p audiocapture/.build/release
	swiftc -O \
		-target arm64-apple-macosx14.2 \
		-sdk "$(SDK_PATH)" \
		-framework AVFoundation \
		-framework CoreAudio \
		-framework AppKit \
		$(SWIFT_SOURCES) \
		-o $(SWIFT_OUT)
	@echo "Built: $(SWIFT_OUT)"

build-parakeet:
	cd parakeet.cpp && mkdir -p build && cd build && \
		cmake .. -DCMAKE_BUILD_TYPE=Release && \
		cmake --build . -j$$(sysctl -n hw.ncpu)

build-python:
	pip install -e .

install: build
	mkdir -p ~/.local/bin
	cp $(SWIFT_OUT) ~/.local/bin/audiocapture
	cp parakeet.cpp/build/parakeet ~/.local/bin/parakeet
	cp parakeet.cpp/build/examples/server/parakeet-server ~/.local/bin/parakeet-server

clean:
	rm -rf audiocapture/.build
	pip uninstall -y whisper-term 2>/dev/null || true
