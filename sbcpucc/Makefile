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


# The parent aggregate Makefile calls `make clean` in every subproject.
# bundle.mk does not provide a clean target on this Theos setup, so define
# one explicitly to keep rootless/roothide rebuilds working.
clean::
	$(ECHO_NOTHING)rm -rf .theos packages$(ECHO_END)
