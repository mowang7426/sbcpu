include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SBCPULiquidGlassBackboardd

# Keep the preprocessor macro numeric even when GitHub Actions does not pass a value.
SBLIQUIDGLASS_DEBUG ?= 0

SBCPULiquidGlassBackboardd_FILES = Tweak.mm LGSymbolResolver.mm
SBCPULiquidGlassBackboardd_CFLAGS = -fobjc-arc -std=c++17 -fno-objc-arc-exceptions -DSBLIQUIDGLASS_DEBUG=$(SBLIQUIDGLASS_DEBUG) -I$(THEOS_PROJECT_DIR)/Shared
SBCPULiquidGlassBackboardd_FRAMEWORKS = Metal QuartzCore CoreFoundation
SBCPULiquidGlassBackboardd_LDFLAGS = -lc++
SBCPULiquidGlassBackboardd_INSTALL_TARGET_PROCESSES = backboardd

include $(THEOS_MAKE_PATH)/tweak.mk
