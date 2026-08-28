
ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SBCPUFloating SBCPUMitigation SBCPUGameOverlay

# 1. 桌面 UI、悬浮窗、与通知管理
SBCPUFloating_FILES = Tweak.xm
SBCPUFloating_CFLAGS = -fobjc-arc
SBCPUFloating_FRAMEWORKS = UIKit Foundation QuartzCore CoreMotion
SBCPUFloating_PRIVATE_FRAMEWORKS = PowerUI IOKit FrontBoardServices
SBCPUFloating_INSTALL_TARGET_PROCESSES = SpringBoard

# 2. 底层守护进程 (引入 IOKit 以支持硬件级拦截)
SBCPUMitigation_FILES = MitigationHook.xm
SBCPUMitigation_CFLAGS = -fobjc-arc
SBCPUMitigation_FRAMEWORKS = Foundation
SBCPUMitigation_PRIVATE_FRAMEWORKS = IOKit
SBCPUMitigation_INSTALL_TARGET_PROCESSES = thermalmonitord powerd

# 3. 游戏内弹幕通知显示层
SBCPUGameOverlay_FILES = GameOverlay.xm
SBCPUGameOverlay_CFLAGS = -fobjc-arc
SBCPUGameOverlay_FRAMEWORKS = UIKit Foundation QuartzCore
SBCPUGameOverlay_INSTALL_TARGET_PROCESSES =

# ⚠️ 注意这里，这句必须在 SUBPROJECTS 之前
include $(THEOS_MAKE_PATH)/tweak.mk

# 🔴 核心修复1：必须加上这两行，编译器才会去打包你的设置页面！
SUBPROJECTS += sbcpuprefs
include $(THEOS_MAKE_PATH)/aggregate.mk


