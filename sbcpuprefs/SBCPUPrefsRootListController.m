#import <UIKit/UIKit.h>
#import <Preferences/PSSpecifier.h>
#import "SBCPUPrefsRootListController.h"
#import "../SBCPUChargeStore.h"
#import "../include/SBCPUThermalPaths.h"
#import <notify.h>

@implementation SBCPUPrefsRootListController

- (NSArray *)specifiers {
	if (!_specifiers) {
		_specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
	}
	return _specifiers;
}

// 录屏增强使用独立权威 store，避免 PreferenceLoader/cfprefsd 重进页面时
// 把旧缓存写回并把开关恢复为关闭。
- (id)getPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if ([key isEqualToString:@"respringPreserveNativeUnlockEnabled"]) {
        CFPreferencesSynchronize(CFSTR("com.yourname.sbcpufloating"), kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        CFPropertyListRef stored = CFPreferencesCopyValue((__bridge CFStringRef)key, CFSTR("com.yourname.sbcpufloating"), kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        id value = stored ? CFBridgingRelease(stored) : nil;
        return [value isKindOfClass:[NSNumber class]] ? @([value boolValue]) : @NO;
    }
    if ([key isEqualToString:@"screenRecordingHighFrameRateEnabled"])
        return SBChargeRead()[key] ?: @NO;
    NSArray *thermalKeys = @[@"thermalEngineEnabled", @"powerMode", @"thermalPressureAutoProtectionEnabled", @"thermalLockScreenLowPowerEnabled", @"thermalNominalAutoRecoveryEnabled", @"thermalPreventDimmingEnabled", @"thermalBlockNotifPopup"];
    if ([thermalKeys containsObject:key]) {
        NSDictionary *prefs = SBCPUThermalReadPrefs();
        return prefs[key] ?: ([key isEqualToString:@"powerMode"] ? @"fullPower" : @YES);
    }
    return nil;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if ([key isEqualToString:@"respringPreserveNativeUnlockEnabled"]) {
        CFPreferencesSetValue((__bridge CFStringRef)key, [value boolValue] ? kCFBooleanTrue : kCFBooleanFalse, CFSTR("com.yourname.sbcpufloating"), kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        if (CFPreferencesSynchronize(CFSTR("com.yourname.sbcpufloating"), kCFPreferencesCurrentUser, kCFPreferencesAnyHost)) {
            notify_post("com.yourname.sbcpufloating/settingsChanged");
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.yourname.sbcpufloating.prefschanged"), NULL, NULL, YES);
        }
        return;
    }
    if ([key isEqualToString:@"screenRecordingHighFrameRateEnabled"]) {
        if (SBChargePatch(@{key: @([value boolValue])})) {
            notify_post("com.yourname.sbcpufloating/settingsChanged");
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.yourname.sbcpufloating.prefschanged"), NULL, NULL, YES);
        }
        return;
    }
    NSArray *thermalKeys = @[@"thermalEngineEnabled", @"powerMode", @"thermalPressureAutoProtectionEnabled", @"thermalLockScreenLowPowerEnabled", @"thermalNominalAutoRecoveryEnabled", @"thermalPreventDimmingEnabled", @"thermalBlockNotifPopup"];
    if ([thermalKeys containsObject:key]) {
        NSMutableDictionary *prefs = [SBCPUThermalReadPrefs() mutableCopy] ?: [NSMutableDictionary dictionary];
        prefs[key] = value ?: @NO;
        if (SBCPUThermalWritePrefs(prefs)) {
            notify_post("com.yourname.sbcpufloating/settingsChanged");
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.yourname.sbcpufloating.prefschanged"), NULL, NULL, YES);
            if ([key isEqualToString:@"powerMode"]) SBCPUThermalPostPowerMode(prefs[key]);
        }
        return;
    }
}

- (void)openMoWangSource {
	NSURL *url = [NSURL URLWithString:@"sileo://source/https://mowang7426.github.io/mowang/"];
	if ([[UIApplication sharedApplication] canOpenURL:url]) {
		[[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
	}
}

@end

