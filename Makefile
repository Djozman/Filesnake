# Builds Filesnake.app in ./build/
# Usage:
#   make          — debug build
#   make release  — release build
#   make open     — build (debug) and launch the app
#   make clean    — remove build/

APP_NAME   = Filesnake
BUNDLE_ID  = com.filesnake.app
BUILD_DIR  = build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
MACOS_DIR  = $(APP_BUNDLE)/Contents/MacOS
RES_DIR    = $(APP_BUNDLE)/Contents/Resources
PLIST_SRC  = Sources/Filesnake/Resources/Info.plist

.PHONY: all debug release open clean

all: debug

debug:
	@echo "Building (debug)..."
	@swift build 2>&1
	@$(MAKE) _bundle SWIFT_BUILD_CONFIG=debug

release:
	@echo "Building (release)..."
	@swift build -c release 2>&1
	@$(MAKE) _bundle SWIFT_BUILD_CONFIG=release

open: debug
	@echo "Launching $(APP_BUNDLE)..."
	@open $(APP_BUNDLE)

clean:
	@rm -rf $(BUILD_DIR)
	@swift package clean
	@echo "Cleaned."

# Internal: assemble the .app bundle from the compiled binary
_bundle:
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(MACOS_DIR) $(RES_DIR)
	@cp .build/$(SWIFT_BUILD_CONFIG)/$(APP_NAME) $(MACOS_DIR)/$(APP_NAME)
	@cp $(PLIST_SRC) $(APP_BUNDLE)/Contents/Info.plist
	@echo "Bundle ready: $(APP_BUNDLE)"
	@echo "Run with: open $(APP_BUNDLE)"
