# Builds Filesnake.app in ./build/
# Usage:
#   make              — debug build
#   make release      — release build
#   make open         — build (debug) and launch
#   make install      — release build + copy to /Applications
#   make uninstall    — remove from /Applications
#   make release-zip  — release build + zip for GitHub distribution
#   make clean        — remove build/

APP_NAME    = Filesnake
BUNDLE_ID   = com.filesnake.app
BUILD_DIR   = build
APP_BUNDLE  = $(BUILD_DIR)/$(APP_NAME).app
MACOS_DIR   = $(APP_BUNDLE)/Contents/MacOS
RES_DIR     = $(APP_BUNDLE)/Contents/Resources
PLIST_SRC   = Sources/Filesnake/Resources/Info.plist
ICON_SRC    = Sources/Filesnake/Resources/Filesnake.icns
INSTALL_DIR = /Applications
ZIP_NAME    = $(BUILD_DIR)/$(APP_NAME).zip

.PHONY: all debug release open install uninstall release-zip clean

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

install: release
	@echo "Installing to $(INSTALL_DIR)..."
	@rm -rf $(INSTALL_DIR)/$(APP_NAME).app
	@cp -R $(APP_BUNDLE) $(INSTALL_DIR)/$(APP_NAME).app
	@echo "Installed: $(INSTALL_DIR)/$(APP_NAME).app"
	@echo "You can now launch Filesnake from Spotlight or the Dock."

uninstall:
	@echo "Removing $(INSTALL_DIR)/$(APP_NAME).app..."
	@rm -rf $(INSTALL_DIR)/$(APP_NAME).app
	@echo "Uninstalled."

release-zip: release
	@echo "Packaging for distribution..."
	@rm -f $(ZIP_NAME)
	@cd $(BUILD_DIR) && zip -r --symlinks $(APP_NAME).zip $(APP_NAME).app
	@echo "Ready for GitHub release: $(ZIP_NAME)"

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
	@cp $(ICON_SRC) $(RES_DIR)/$(APP_NAME).icns
	@echo "Bundle ready: $(APP_BUNDLE)"
