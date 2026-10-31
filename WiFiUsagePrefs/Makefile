TARGET := iphone:clang:latest:14.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = WiFiUsagePrefs

WiFiUsagePrefs_FILES = \
	WUDataUsageItem.m \
	WUDataUsageManager.m \
	WUUsageCell.m \
	WUSummaryHeaderView.m \
	WiFiUsageRootListController.m

WiFiUsagePrefs_FRAMEWORKS = UIKit Foundation CoreGraphics
WiFiUsagePrefs_PRIVATE_FRAMEWORKS = Preferences
WiFiUsagePrefs_LIBRARIES = sqlite3
WiFiUsagePrefs_INSTALL_PATH = /Library/PreferenceBundles
WiFiUsagePrefs_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
WiFiUsagePrefs_LDFLAGS = -Wl,-no_fixup_chains

include $(THEOS_MAKE_PATH)/bundle.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/WiFiUsagePrefs.plist$(ECHO_END)
