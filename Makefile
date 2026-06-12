SCHEME        = KosmoNotes
CONFIGURATION = Release
DERIVED_DATA  = build
APP_PATH      = $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/$(SCHEME).app
INSTALL_PATH  = /Applications/$(SCHEME).app
CERT_HASH     = 700E6802C639969593A1AC7F57C1FBFA0A1C7762
ENTITLEMENTS  = App/KosmoNotes.entitlements
DEVELOPER_DIR = /Applications/Xcode.app/Contents/Developer

.PHONY: build sign install release test clean

build:
	DEVELOPER_DIR=$(DEVELOPER_DIR) xcodebuild \
		-scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		CODE_SIGN_IDENTITY="" \
		CODE_SIGNING_REQUIRED=NO \
		CODE_SIGNING_ALLOWED=NO \
		-derivedDataPath $(DERIVED_DATA) \
		-destination 'platform=macOS'

sign:
	codesign --force --deep \
		--sign "$(CERT_HASH)" \
		--entitlements $(ENTITLEMENTS) \
		$(APP_PATH)

install: build sign
	rm -rf $(INSTALL_PATH)
	ditto $(APP_PATH) $(INSTALL_PATH)
	@echo "✅ Installed to $(INSTALL_PATH)"
	@echo "   System permissions (mic, camera, screen) will persist across updates."

release: install

test:
	DEVELOPER_DIR=$(DEVELOPER_DIR) swift test

clean:
	rm -rf $(DERIVED_DATA)
