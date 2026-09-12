# SBCPUFloating V4.12.0 自适应屏幕版 - THEOS 工程

ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SBCPUFloating

SBCPUFloating_FILES = Tweak.xm
SBCPUFloating_CFLAGS = -fobjc-arc -Iinclude
SBCPUFloating_FRAMEWORKS = UIKit Foundation QuartzCore CoreMotion
SBCPUFloating_PRIVATE_FRAMEWORKS = PowerUI IOKit FrontBoardServices
SBCPUFloating_INSTALL_TARGET_PROCESSES = SpringBoard

# roothide 越狱支持
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
SBCPUFloating_LDFLAGS += -L$(THEOS_VENDOR_LIBRARY_PATH)/iphone/roothide -lroothide
endif

include $(THEOS_MAKE_PATH)/tweak.mk
