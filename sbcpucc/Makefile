ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:14.0

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = SBCPUFloatingCC
SBCPUFloatingCC_FILES = SBCPUFloatingCC.m
SBCPUFloatingCC_FRAMEWORKS = UIKit Foundation CoreFoundation
SBCPUFloatingCC_CFLAGS = -fobjc-arc
SBCPUFloatingCC_INSTALL_PATH = /Library/ControlCenter/Bundles
SBCPUFloatingCC_RESOURCE_DIRS = Resources
SBCPUFloatingCC_INFO_PLIST = SBCPUFloatingCC-Info.plist

include $(THEOS_MAKE_PATH)/bundle.mk
