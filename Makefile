ARCHS = arm64
TARGET = iphone:clang:16.5:14.0
INSTALL_TARGET_PROCESSES = Animal\ Company

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ACMODDED
ACMODDED_FILES = Tweak.x.m
ACMODDED_CFLAGS = -fobjc-arc

include $(THEOS)/makefiles/tweak.mk
