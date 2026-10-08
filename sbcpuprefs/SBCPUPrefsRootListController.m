#import <UIKit/UIKit.h>
#import <Preferences/PSSpecifier.h>
#import "SBCPUPrefsRootListController.h"
#import "SBCPUThermalDiagnosticsController.h"
#import "../SBCPUChargeStore.h"
#import "../include/SBCPUThermalPaths.h"
#import "SBCPUThermalPreferenceUI.h"
#import <notify.h>

@implementation SBCPUPrefsRootListController

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Restore the root title when returning from a detail or host-restored page.
    self.title = @"灵动监测";
    self.navigationItem.title = @"灵动监测";
}

- (void)openThermalDiagnostics {
    // Do not delegate this route to PreferenceLoader's nested detail resolution.
    // This action is invoked only by the root's PSButtonCell, never on appearance.
    UINavigationController *navigationController = self.navigationController;
    if (!navigationController || navigationController.topViewController != self) return;
    SBCPUThermalDiagnosticsController *controller = [[SBCPUThermalDiagnosticsController alloc] init];
    [navigationController pushViewController:controller animated:YES];
}

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
    if (SBCPUIsThermalPreference(key)) {
        return SBCPUThermalPreferenceValue(SBCPUThermalReadPrefs(), key, [specifier propertyForKey:@"default"]);
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
    if (SBCPUIsThermalPreference(key)) {
        if (!SBCPUSaveThermalPreference(key, value)) {
            // Defer until the switch finishes its optimistic UI update, then reread disk.
            dispatch_async(dispatch_get_main_queue(), ^{
                [self reloadSpecifiers];
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"温控设置未保存"
                    message:@"写入偏好失败。已重新读取现有配置；本次更改未发送给温控核心。"
                    preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:alert animated:YES completion:nil];
            });
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

