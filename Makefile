TARGET := iphone:clang:latest:14.0
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LowPowerMock

LowPowerMock_FILES = Tweak.m
LowPowerMock_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
