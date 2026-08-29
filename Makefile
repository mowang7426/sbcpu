
ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SBCPUFloating SBCPUThermal SBCPUFloatingCCRegistration

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

# 3. Control Center registration bridge (same registration strategy as CPUthermal 1.6.4-53)
SBCPUFloatingCCRegistration_FILES = CCRegistration.xm
SBCPUFloatingCCRegistration_CFLAGS = -fobjc-arc -Iinclude -Wno-deprecated-declarations -DTHEOS_INSIDE -fvisibility=hidden
SBCPUFloatingCCRegistration_LDFLAGS += -Wl,-x -Wl,-dead_strip
SBCPUFloatingCCRegistration_FRAMEWORKS = Foundation CoreFoundation
SBCPUFloatingCCRegistration_LIBRARIES = substrate

ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
SBCPUThermal_LDFLAGS += -L$(THEOS_VENDOR_LIBRARY_PATH)/iphone/roothide -lroothide
endif

# ⚠️ 注意这里，这句必须在 SUBPROJECTS 之前
include $(THEOS_MAKE_PATH)/tweak.mk

# 🔴 核心修复1：必须加上这两行，编译器才会去打包你的设置页面！
SUBPROJECTS += sbcpuprefs

BUNDLE_NAME = SBCPUFloatingCC

# Control Center bundle: follows CPUthermal 1.6.4-53 working layout.
SBCPUFloatingCC_FILES = ControlCenter/SBCPUFloatingCCModule.m ControlCenter/SBCPUFloatingCCModuleViewController.m
SBCPUFloatingCC_CFLAGS = -fobjc-arc -IControlCenter -Iinclude
SBCPUFloatingCC_FRAMEWORKS = Foundation UIKit
SBCPUFloatingCC_PRIVATE_FRAMEWORKS = ControlCenterUIKit
SBCPUFloatingCC_INSTALL_PATH = /Library/ControlCenter/Bundles/
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
SBCPUFloatingCC_LDFLAGS += -L$(THEOS_VENDOR_LIBRARY_PATH)/iphone/roothide -lroothide
endif

# Stage registration filter and Control Center bundle resources.
after-stage::
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/Library/ControlCenter/Bundles/SBCPUFloatingCC.bundle"$(ECHO_END)
	$(ECHO_NOTHING)cp "$(THEOS_PROJECT_DIR)/ControlCenter/resources/Info.plist" "$(THEOS_STAGING_DIR)/Library/ControlCenter/Bundles/SBCPUFloatingCC.bundle/Info.plist"$(ECHO_END)
	$(ECHO_NOTHING)cp "$(THEOS_PROJECT_DIR)/ControlCenter/resources/SettingsIcon.png" "$(THEOS_STAGING_DIR)/Library/ControlCenter/Bundles/SBCPUFloatingCC.bundle/SettingsIcon.png"$(ECHO_END)
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries"$(ECHO_END)
	$(ECHO_NOTHING)cp "$(THEOS_PROJECT_DIR)/CPUthermalCCRegistration.plist" "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/SBCPUFloatingCCRegistration.plist"$(ECHO_END)

include $(THEOS_MAKE_PATH)/bundle.mk
include $(THEOS_MAKE_PATH)/aggregate.mk


