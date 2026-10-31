TARGET := iphone:clang:latest:14.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TOOL_NAME = wifiusaged

wifiusaged_FILES = main.m
wifiusaged_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
wifiusaged_LDFLAGS = -Wl,-no_fixup_chains
wifiusaged_CODESIGN_FLAGS = -Sentitlements.plist
wifiusaged_FRAMEWORKS = Foundation CoreFoundation
wifiusaged_LIBRARIES = sqlite3
wifiusaged_INSTALL_PATH = /usr/libexec

include $(THEOS_MAKE_PATH)/tool.mk
