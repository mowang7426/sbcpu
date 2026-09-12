ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SBCPUFloating SBCPUThermal SBCPUPowerd SBCPUFloatingCCRegistration

# 1. 桌面 UI、悬浮窗、120Hz/FPS、通知管理
SBCPUFloating_FILES = Tweak.xm
SBCPUFloating_CFLAGS = -fobjc-arc -Iinclude
SBCPUFloating_FRAMEWORKS = UIKit Foundation QuartzCore CoreMotion
SBCPUFloating_PRIVATE_FRAMEWORKS = PowerUI IOKit FrontBoardServices
SBCPUFloating_INSTALL_TARGET_PROCESSES = SpringBoard

# 2. CPUthermal 合并引擎
SBCPUThermal_FILES = SBCPUThermal.x SBCPUThermalRecovered.mm
SBCPUThermal_CFLAGS = -fobjc-arc -Iinclude -Wno-deprecated-declarations -DTHEOS_INSIDE -fvisibility=hidden
SBCPUThermal_LDFLAGS += -Wl,-x -Wl,-dead_strip
SBCPUThermal_FRAMEWORKS = Foundation UIKit CoreFoundation IOKit
SBCPUThermal_LIBRARIES = substrate
SBCPUThermal_INSTALL_TARGET_PROCESSES = thermalmonitord

# 3. 独立 powerd 满血充电核心：只负责强制快充/解除充电降流限制。
# 与 thermalmonitord 分离，避免把 powerd 专属 Hook 混入温控核心。
SBCPUPowerd_FILES = SBCPUPowerd.xm
SBCPUPowerd_CFLAGS = -fobjc-arc -Iinclude -Wno-deprecated-declarations -DTHEOS_INSIDE -fvisibility=hidden
SBCPUPowerd_LDFLAGS += -Wl,-x -Wl,-dead_strip
SBCPUPowerd_FRAMEWORKS = Foundation CoreFoundation IOKit
SBCPUPowerd_LIBRARIES = substrate
SBCPUPowerd_INSTALL_TARGET_PROCESSES = powerd

# 4. Control Center 注册桥
# 这一部分按你上传的 CPUthermal 1.6.4-53 的 CCRegistration.xm 方式实现：
# 把第三方 Bundles 目录加入 CCSModuleRepository，并处理 allowlist。
SBCPUFloatingCCRegistration_FILES = CCRegistration.xm
SBCPUFloatingCCRegistration_CFLAGS = -fobjc-arc -Iinclude -Wno-deprecated-declarations -DTHEOS_INSIDE -fvisibility=hidden
SBCPUFloatingCCRegistration_LDFLAGS += -Wl,-x -Wl,-dead_strip
SBCPUFloatingCCRegistration_FRAMEWORKS = Foundation CoreFoundation
SBCPUFloatingCCRegistration_LIBRARIES = substrate
SBCPUFloatingCCRegistration_INSTALL_TARGET_PROCESSES = SpringBoard

ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
SBCPUThermal_LDFLAGS += -L$(THEOS_VENDOR_LIBRARY_PATH)/iphone/roothide -lroothide
SBCPUFloatingCCRegistration_LDFLAGS += -L$(THEOS_VENDOR_LIBRARY_PATH)/iphone/roothide -lroothide
endif

include $(THEOS_MAKE_PATH)/tweak.mk

# PreferenceBundle
SUBPROJECTS += sbcpuprefs

# Control Center Bundle：结构/生命周期参考 CPUthermal 1.6.4-53。
BUNDLE_NAME = SBCPUFloatingCC
SBCPUFloatingCC_FILES = ControlCenter/SBCPUFloatingCCModule.m ControlCenter/SBCPUFloatingCCModuleViewController.m
SBCPUFloatingCC_CFLAGS = -fobjc-arc -IControlCenter -Iinclude
SBCPUFloatingCC_FRAMEWORKS = Foundation UIKit ControlCenterUIKit
SBCPUFloatingCC_PRIVATE_FRAMEWORKS = ControlCenterUIKit
SBCPUFloatingCC_INSTALL_PATH = /Library/ControlCenter/Bundles/
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
SBCPUFloatingCC_LDFLAGS += -L$(THEOS_VENDOR_LIBRARY_PATH)/iphone/roothide -lroothide
endif

include $(THEOS_MAKE_PATH)/bundle.mk
include $(THEOS_MAKE_PATH)/aggregate.mk

# 确保 Control Center bundle 的资源和注册过滤器一定进入最终 DEB。
after-stage::
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries"$(ECHO_END)
	$(ECHO_NOTHING)cp "$(THEOS_PROJECT_DIR)/SBCPUPowerd.plist" "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/SBCPUPowerd.plist"$(ECHO_END)
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/Library/ControlCenter/Bundles/SBCPUFloatingCC.bundle"$(ECHO_END)
	$(ECHO_NOTHING)cp "$(THEOS_PROJECT_DIR)/ControlCenter/resources/Info.plist" "$(THEOS_STAGING_DIR)/Library/ControlCenter/Bundles/SBCPUFloatingCC.bundle/Info.plist"$(ECHO_END)
	$(ECHO_NOTHING)cp "$(THEOS_PROJECT_DIR)/ControlCenter/resources/SettingsIcon.png" "$(THEOS_STAGING_DIR)/Library/ControlCenter/Bundles/SBCPUFloatingCC.bundle/SettingsIcon.png"$(ECHO_END)
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries"$(ECHO_END)
	$(ECHO_NOTHING)cp "$(THEOS_PROJECT_DIR)/SBCPUFloatingCCRegistration.plist" "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/SBCPUFloatingCCRegistration.plist"$(ECHO_END)
