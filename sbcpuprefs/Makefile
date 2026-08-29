
ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:14.0

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = SBCPUPrefs

SBCPUPrefs_FILES = SBCPUPrefsRootListController.m
SBCPUPrefs_FRAMEWORKS = UIKit
SBCPUPrefs_PRIVATE_FRAMEWORKS = Preferences
SBCPUPrefs_CFLAGS = -fobjc-arc

# 🔴 核心修复3：指定正确的安装路径和主类
SBCPUPrefs_INSTALL_PATH = /Library/PreferenceBundles
SBCPUPrefs_PRINCIPAL_CLASS = SBCPUPrefsRootListController
SBCPUPrefs_RESOURCE_DIRS = Resources

include $(THEOS_MAKE_PATH)/bundle.mk

# PreferenceLoader does NOT discover entry.plist just because it exists
# inside the subproject. It must be staged into /Library/PreferenceLoader/Preferences.
internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/SBCPUPrefs.plist$(ECHO_END)
	$(ECHO_NOTHING)cp Resources/icon.PNG $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/icon.PNG$(ECHO_END)



# The parent aggregate Makefile calls `make clean` in every subproject.
# bundle.mk does not provide a clean target on this Theos setup, so define
# one explicitly to keep rootless/roothide rebuilds working.
clean::
	$(ECHO_NOTHING)rm -rf .theos packages$(ECHO_END)
