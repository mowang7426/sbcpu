ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:14.0

# RootHide / Rootless scheme is selected by the build command.
# Example:
#   THEOS_PACKAGE_SCHEME=rootless make package
#   THEOS_PACKAGE_SCHEME=roothide make package

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SBCPUFloating SBCPUMitigation

# ------------------------------------------------------------
# SBCPUFloating
# SpringBoard floating UI / CPU / FPS / battery / temperature
# ------------------------------------------------------------
SBCPUFloating_FILES = Tweak.xm
SBCPUFloating_CFLAGS = -fobjc-arc
SBCPUFloating_FRAMEWORKS = UIKit Foundation QuartzCore CoreMotion
SBCPUFloating_PRIVATE_FRAMEWORKS = IOKit

# ------------------------------------------------------------
# SBCPUMitigation
# Low-level mitigation / charging / thermal related hooks
# ------------------------------------------------------------
SBCPUMitigation_FILES = MitigationHook.xm
SBCPUMitigation_CFLAGS = -fobjc-arc
SBCPUMitigation_FRAMEWORKS = Foundation
SBCPUMitigation_PRIVATE_FRAMEWORKS = IOKit

# Build the two tweak dylibs.
include $(THEOS_MAKE_PATH)/tweak.mk

# Build the PreferenceBundle subproject.
SUBPROJECTS += sbcpuprefs

include $(THEOS_MAKE_PATH)/aggregate.mk
