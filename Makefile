ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SBCPUFloating SBCPUThermal SBCPUPowerd SBCPUFloatingCCRegistration SBCPUForce120

# 1. 桌面 UI、悬浮窗、120Hz/FPS、通知管理
SBCPUFloating_FILES = Tweak.xm
SBCPUFloating_CFLAGS = -fobjc-arc -Iinclude
SBCPUFloating_LDFLAGS = -Wl,-U,___isOSVersionAtLeast
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

# 5. 全局 120Hz 强制（V4.17.0）：注入所有进程，hook 每个 App 的 CADisplayLink
# CAFrameRateRange 是 iOS 15+ 类型，源码内 @available 已做运行时保护；
# 编译期压掉 unguarded-availability 警告（Logos 生成的声明无法消音，-Werror 会转 error）
SBCPUForce120_FILES = SBCPUForce120.xm
SBCPUForce120_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -fvisibility=hidden -Wno-error=unguarded-availability-new
SBCPUForce120_LDFLAGS += -Wl,-x -Wl,-dead_strip -Wl,-U,___isOSVersionAtLeast
SBCPUForce120_FRAMEWORKS = Foundation QuartzCore
SBCPUForce120_LIBRARIES = substrate
SBCPUForce120_INSTALL_TARGET_PROCESSES = SpringBoard

# 6. 充电控制 root daemon（V4.21）：SpringBoard 无 AppleSMC entitlement，
# 由 launchd 以 root 拉起本 daemon，ldid 签名带 com.apple.private.applesmc.user-access，
# 监听 unix socket 替 SpringBoard 写 CH0C(停充)/CH0I(断外部供电)。
TOOL_NAME = SBCPUChargeDaemon
SBCPUChargeDaemon_FILES = SBCPUChargeDaemon.m
SBCPUChargeDaemon_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
SBCPUChargeDaemon_FRAMEWORKS = Foundation IOKit
SBCPUChargeDaemon_CODESIGN_FLAGS = -S$(THEOS_PROJECT_DIR)/SBCPUChargeDaemon.entitlements
SBCPUChargeDaemon_INSTALL_PATH = /usr/libexec

ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
SBCPUThermal_LDFLAGS += -L$(THEOS_VENDOR_LIBRARY_PATH)/iphone/roothide -lroothide
SBCPUFloatingCCRegistration_LDFLAGS += -L$(THEOS_VENDOR_LIBRARY_PATH)/iphone/roothide -lroothide
SBCPUForce120_LDFLAGS += -L$(THEOS_VENDOR_LIBRARY_PATH)/iphone/roothide -lroothide
SBCPUChargeDaemon_CFLAGS += -I$(THEOS_VENDOR_INCLUDE_PATH)/roothide
SBCPUChargeDaemon_LDFLAGS += -L$(THEOS_VENDOR_LIBRARY_PATH)/iphone/roothide -lroothide
endif

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/tool.mk

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
	$(ECHO_NOTHING)cp "$(THEOS_PROJECT_DIR)/SBCPUForce120.plist" "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/SBCPUForce120.plist"$(ECHO_END)
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/Library/ControlCenter/Bundles/SBCPUFloatingCC.bundle"$(ECHO_END)
	$(ECHO_NOTHING)cp "$(THEOS_PROJECT_DIR)/ControlCenter/resources/Info.plist" "$(THEOS_STAGING_DIR)/Library/ControlCenter/Bundles/SBCPUFloatingCC.bundle/Info.plist"$(ECHO_END)
	$(ECHO_NOTHING)cp "$(THEOS_PROJECT_DIR)/ControlCenter/resources/SettingsIcon.png" "$(THEOS_STAGING_DIR)/Library/ControlCenter/Bundles/SBCPUFloatingCC.bundle/SettingsIcon.png"$(ECHO_END)
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries"$(ECHO_END)
	$(ECHO_NOTHING)cp "$(THEOS_PROJECT_DIR)/SBCPUFloatingCCRegistration.plist" "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/SBCPUFloatingCCRegistration.plist"$(ECHO_END)
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/Library/LaunchDaemons"$(ECHO_END)
	$(ECHO_NOTHING)cp "$(THEOS_PROJECT_DIR)/com.sbcpu.charged.plist" "$(THEOS_STAGING_DIR)/Library/LaunchDaemons/com.sbcpu.charged.plist"$(ECHO_END)
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/DEBIAN"$(ECHO_END)
	$(ECHO_NOTHING)cp "$(THEOS_PROJECT_DIR)/postinst" "$(THEOS_STAGING_DIR)/DEBIAN/postinst"$(ECHO_END)
	$(ECHO_NOTHING)chmod 0755 "$(THEOS_STAGING_DIR)/DEBIAN/postinst"$(ECHO_END)
