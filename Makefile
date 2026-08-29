
ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SBCPUFloating SBCPUThermal

# 1. 桌面 UI、悬浮窗、与通知管理
SBCPUFloating_FILES = Tweak.xm
SBCPUFloating_CFLAGS = -fobjc-arc -Iinclude
SBCPUFloating_FRAMEWORKS = UIKit Foundation QuartzCore CoreMotion
SBCPUFloating_PRIVATE_FRAMEWORKS = PowerUI IOKit FrontBoardServices
SBCPUFloating_INSTALL_TARGET_PROCESSES = SpringBoard

# 2. 底层守护进程 (引入 IOKit 以支持硬件级拦截)
SBCPUThermal_FILES = SBCPUThermal.x SBCPUThermalRecovered.mm
SBCPUThermal_CFLAGS = -fobjc-arc -Iinclude -Wno-deprecated-declarations -DTHEOS_INSIDE -fvisibility=hidden
SBCPUThermal_LDFLAGS += -Wl,-x -Wl,-dead_strip
SBCPUThermal_FRAMEWORKS = Foundation UIKit CoreFoundation IOKit
SBCPUThermal_LIBRARIES = substrate
SBCPUThermal_INSTALL_TARGET_PROCESSES = thermalmonitord

ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
SBCPUThermal_LDFLAGS += -L$(THEOS_VENDOR_LIBRARY_PATH)/iphone/roothide -lroothide
endif

# ⚠️ 注意这里，这句必须在 SUBPROJECTS 之前
include $(THEOS_MAKE_PATH)/tweak.mk

# 🔴 核心修复1：必须加上这两行，编译器才会去打包你的设置页面！
SUBPROJECTS += sbcpufloatingcc sbcpuprefs
include $(THEOS_MAKE_PATH)/aggregate.mk


