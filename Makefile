BUILD_DIR ?= build
CONFIG    ?= Release
APP       := $(BUILD_DIR)/Wink.app

.PHONY: all bootstrap configure build run run-debug test clean distclean blocklist icon

all: build

bootstrap:
	@./scripts/bootstrap.sh

$(BUILD_DIR)/build.ninja: CMakeLists.txt
	@./scripts/bootstrap.sh
	@cmake -S . -B $(BUILD_DIR) -G Ninja -DCMAKE_BUILD_TYPE=$(CONFIG) $(CMAKE_FLAGS)

configure: $(BUILD_DIR)/build.ninja

build: configure
	@cmake --build $(BUILD_DIR)

# Launch through LaunchServices (normal app launch).
run: build
	@open "$(APP)"

# Launch attached to the terminal so engine/app logs are visible.
run-debug: build
	@"$(APP)/Contents/MacOS/Wink"

# Unit tests for the engine's privacy core (no Chromium needed).
test: configure
	@cmake --build $(BUILD_DIR) --target wink_tests && ./$(BUILD_DIR)/wink_tests

# Regenerate the bundled tracker/ad blocklist from upstream sources.
blocklist:
	@python3 -I scripts/update_blocklist.py Resources/blocklist

# Regenerate the app icon.
icon: configure
	@swiftc $(if $(wildcard $(BUILD_DIR)/swift-overlay/overlay.yaml),-vfsoverlay $(BUILD_DIR)/swift-overlay/overlay.yaml) \
		scripts/make_icon.swift -o $(BUILD_DIR)/make_icon && $(BUILD_DIR)/make_icon Resources/Brand/wink-eye.jpg Resources/AppIcon.icns

clean:
	@rm -rf $(BUILD_DIR)

distclean: clean
	@rm -rf third_party/cef third_party/downloads
