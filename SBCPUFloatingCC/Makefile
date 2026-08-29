ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:14.0

BUNDLE_NAME = SBCPUFloatingCC

$(BUNDLE_NAME)_FILES = SBCPUFloatingCC.m
$(BUNDLE_NAME)_CFLAGS = -fobjc-arc -I$(THEOS_PROJECT_DIR)/SBCPUFloatingCC/headers
$(BUNDLE_NAME)_FRAMEWORKS = UIKit Foundation
$(BUNDLE_NAME)_INSTALL_PATH = /Library/ControlCenter/Bundles

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/bundle.mk
