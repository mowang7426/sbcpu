include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SBCPULiquidGlassBackboardd

SBCPULiquidGlassBackboardd_FILES = Tweak.mm LGSymbolResolver.mm
SBCPULiquidGlassBackboardd_CFLAGS = -fobjc-arc -std=c++17 -fno-objc-arc-exceptions -DSBLIQUIDGLASS_DEBUG=$(SBLIQUIDGLASS_DEBUG) -I$(THEOS_PROJECT_DIR)/Shared
SBCPULiquidGlassBackboardd_FRAMEWORKS = Metal QuartzCore CoreFoundation
SBCPULiquidGlassBackboardd_LDFLAGS = -lc++
SBCPULiquidGlassBackboardd_INSTALL_TARGET_PROCESSES = backboardd

include $(THEOS_MAKE_PATH)/tweak.mk
