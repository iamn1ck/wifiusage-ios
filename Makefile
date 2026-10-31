TARGET := iphone:clang:latest:14.0
THEOS_PACKAGE_SCHEME = rootless
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = Preferences

include $(THEOS)/makefiles/common.mk

SUBPROJECTS += wifiusaged WiFiUsagePrefs

include $(THEOS_MAKE_PATH)/aggregate.mk
