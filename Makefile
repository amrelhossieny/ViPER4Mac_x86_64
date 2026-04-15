PROJECT    := ViPER4Mac.xcodeproj
CONFIG     := Release
ARCH       := x86_64
BUILD_DIR  := build/$(CONFIG)

APP_NAME    := ViPER4Mac.app
DRIVER_NAME := ViPER4Mac.driver

APP_SRC    := $(BUILD_DIR)/$(APP_NAME)
DRIVER_SRC := $(BUILD_DIR)/$(DRIVER_NAME)

APP_DST    := /Applications/$(APP_NAME)
DRIVER_DST := /Library/Audio/Plug-Ins/HAL/$(DRIVER_NAME)

PKG_DIR    := build/pkg
PKG_ROOT   := $(PKG_DIR)/root
PKG_OUT    := build/ViPER4Mac.pkg
VERSION    := 1.0.0
DRIVER_VERSION := 1.0.0

.PHONY: all app driver build fix-plist resign install uninstall clean package

all: build

# ── Swift App ─────────────────────────────────────────────────────
app:
	xcodebuild -project $(PROJECT) -target ViPER4Mac \
		-configuration $(CONFIG) \
		MARKETING_VERSION=$(VERSION) \
		ONLY_ACTIVE_ARCH=NO ARCHS=$(ARCH) \
		BUILD_DIR=$(CURDIR)/build

# ── Driver (Xcode builds the bundle) ──────────────────────────────
driver:
	xcodebuild -project $(PROJECT) -target ViPERDSP \
		-configuration $(CONFIG) \
		MARKETING_VERSION=$(DRIVER_VERSION) \
		ONLY_ACTIVE_ARCH=NO ARCHS=$(ARCH) \
		BUILD_DIR=$(CURDIR)/build
	xcodebuild -project $(PROJECT) -target ViPERDriver \
		-configuration $(CONFIG) \
		MARKETING_VERSION=$(DRIVER_VERSION) \
		ONLY_ACTIVE_ARCH=NO ARCHS=$(ARCH) \
		BUILD_DIR=$(CURDIR)/build

# ── Patch Info.plist after Xcode overwrites it ────────────────────
fix-plist:
	@echo "Patching driver Info.plist..."
	@python3 -c "import plistlib; path='build/Release/ViPER4Mac.driver/Contents/Info.plist'; f=open(path,'rb'); pl=plistlib.load(f); f.close(); pl.pop('AudioServerPlugIn_XPCServiceName',None); pl['CFPlugInFactories']={'A2E1C4F1-9B23-4A84-9D5D-7E1A4F6B8C9D':'ViPER4Mac_Create'}; pl['CFPlugInTypes']={'443ABAB8-E7B3-491A-B985-BEB9187030DB':['A2E1C4F1-9B23-4A84-9D5D-7E1A4F6B8C9D']}; f=open(path,'wb'); plistlib.dump(pl,f); f.close(); print('Plist patched with correct UUIDs')"

# ── Re-sign after plist patch ─────────────────────────────────────
resign:
	@echo "Re-signing driver..."
	codesign -f -s - "build/Release/ViPER4Mac.driver"
	@echo "Re-signed"

# ── Full build ────────────────────────────────────────────────────
build: app driver fix-plist resign
	@echo ""
	@echo "Full build complete. Bundle structure:"
	@find build/Release/ViPER4Mac.driver -type f | sort
	@echo ""
	@echo "Architecture check:"
	@file build/Release/ViPER4Mac.driver/Contents/MacOS/ViPER4Mac
	@echo ""
	@echo "Plist check:"
	@grep -A1 "XPCService\|PlugInFact\|PlugInType" \
		build/Release/ViPER4Mac.driver/Contents/Info.plist || \
		echo "No XPC key - good!"

# ── Install ───────────────────────────────────────────────────────
install: build
	@echo "Installing ViPER4Mac..."
	-osascript -e 'tell application "ViPER4Mac" to quit' 2>/dev/null
	sudo rm -rf $(DRIVER_DST) $(APP_DST)
	sudo cp -R $(DRIVER_SRC) $(DRIVER_DST)
	sudo cp -R $(APP_SRC)    $(APP_DST)
	sudo chown -R root:wheel $(DRIVER_DST)
	sudo chmod -R 755        $(DRIVER_DST)
	sudo xattr -cr           $(DRIVER_DST)
	sudo codesign -f -s -    $(DRIVER_DST)
	@echo "Restarting coreaudiod..."
	sudo killall coreaudiod 2>/dev/null || true
	sleep 5
	@echo "Checking..."
	system_profiler SPAudioDataType | grep -q "ViPER4Mac" \
		&& echo "Driver loaded!" \
		|| echo "Driver not found"
	open $(APP_DST)

# ── Uninstall ─────────────────────────────────────────────────────
uninstall:
	-osascript -e 'tell application "ViPER4Mac" to quit' 2>/dev/null
	sleep 1
	-sudo rm -rf $(APP_DST) $(DRIVER_DST)
	sudo killall coreaudiod 2>/dev/null || true
	@echo "Done."

# ── Clean ─────────────────────────────────────────────────────────
clean:
	rm -rf build

# ── Package ───────────────────────────────────────────────────────
package: build
	@echo "Building installer package..."
	rm -rf $(PKG_DIR)
	mkdir -p $(PKG_ROOT)/Applications
	mkdir -p "$(PKG_ROOT)/Library/Audio/Plug-Ins/HAL"
	mkdir -p $(PKG_DIR)/scripts
	cp -R $(APP_SRC) $(PKG_ROOT)/Applications/
	cp -R $(DRIVER_SRC) "$(PKG_ROOT)/Library/Audio/Plug-Ins/HAL/"
	cp installer/preinstall  $(PKG_DIR)/scripts/preinstall
	cp installer/postinstall $(PKG_DIR)/scripts/postinstall
	chmod +x $(PKG_DIR)/scripts/preinstall \
	         $(PKG_DIR)/scripts/postinstall
	pkgbuild \
		--root $(PKG_ROOT) \
		--scripts $(PKG_DIR)/scripts \
		--identifier com.viper4mac.pkg \
		--version $(VERSION) \
		--install-location / \
		$(PKG_DIR)/ViPER4Mac-component.pkg
	productbuild \
		--distribution installer/Distribution.xml \
		--package-path $(PKG_DIR) \
		--resources installer \
		$(PKG_OUT)
	@echo "Package: $(PKG_OUT)"