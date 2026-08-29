ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:14.0

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = SBCPUFloatingCC
SBCPUFloatingCC_FILES = SBCPUFloatingCCModule.m
SBCPUFloatingCC_FRAMEWORKS = UIKit Foundation CoreFoundation
SBCPUFloatingCC_PRIVATE_FRAMEWORKS = ControlCenterUIKit
SBCPUFloatingCC_CFLAGS = -fobjc-arc
SBCPUFloatingCC_INSTALL_PATH = /Library/ControlCenter/Bundles
SBCPUFloatingCC_INFO_PLIST = SBCPUFloatingCC-Info.plist
SBCPUFloatingCC_RESOURCE_DIRS = Resources

include $(THEOS_MAKE_PATH)/bundle.mk
