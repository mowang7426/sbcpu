#import "SBCPUThermalModeController.h"
#import "../include/SBCPUThermalPaths.h"
#import <notify.h>

@implementation SBCPUThermalModeController
- (NSArray *)specifiers {
    if (!_specifiers) {
        PSSpecifier *group = [PSSpecifier groupSpecifierWithName:@"选择温控运行方式"];
        [group setProperty:@"极限满频仅阻止插件主动降频，不关闭系统与硬件安全保护。" forKey:@"footerText"];
        PSSpecifier *low = [PSSpecifier preferenceSpecifierNamed:@"省电保护" target:self set:@selector(setMode:specifier:) get:@selector(getMode:) detail:nil cell:PSRadioCell edit:nil];
        PSSpecifier *full = [PSSpecifier preferenceSpecifierNamed:@"稳定高性能" target:self set:@selector(setMode:specifier:) get:@selector(getMode:) detail:nil cell:PSRadioCell edit:nil];
        PSSpecifier *extreme = [PSSpecifier preferenceSpecifierNamed:@"极限满频" target:self set:@selector(setMode:specifier:) get:@selector(getMode:) detail:nil cell:PSRadioCell edit:nil];
        [low setProperty:@"lowPower" forKey:@"modeValue"];
        [full setProperty:@"fullPower" forKey:@"modeValue"];
        [extreme setProperty:@"extremeFull" forKey:@"modeValue"];
        _specifiers = @[group, low, full, extreme];
    }
    return _specifiers;
}
- (id)getMode:(PSSpecifier *)specifier {
    NSString *mode = SBCPUThermalReadPrefs()[@"powerMode"] ?: @"fullPower";
    return [mode isEqualToString:[specifier propertyForKey:@"modeValue"]] ? @YES : @NO;
}
- (void)setMode:(id)value specifier:(PSSpecifier *)specifier {
    if (![value boolValue]) return;
    NSMutableDictionary *prefs = [SBCPUThermalReadPrefs() mutableCopy] ?: [NSMutableDictionary dictionary];
    NSString *mode = [specifier propertyForKey:@"modeValue"];
    if (mode.length == 0) return;
    prefs[@"powerMode"] = mode;
    if (SBCPUThermalWritePrefs(prefs)) {
        SBCPUThermalPostPowerMode(mode);
        notify_post("com.yourname.sbcpufloating/settingsChanged");
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.yourname.sbcpufloating.prefschanged"), NULL, NULL, YES);
    }
}
@end
