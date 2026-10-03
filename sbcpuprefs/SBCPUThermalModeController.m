#import "SBCPUThermalModeController.h"
#import "../include/SBCPUThermalPaths.h"
#import <notify.h>
@implementation SBCPUThermalModeController
- (NSArray *)specifiers {
    if (!_specifiers) _specifiers = [self loadSpecifiersFromPlistName:@"ThermalMode" target:self];
    return _specifiers;
}
- (void)chooseMode:(NSString *)mode {
    NSMutableDictionary *prefs = [SBCPUThermalReadPrefs() mutableCopy] ?: [NSMutableDictionary dictionary];
    prefs[@"powerMode"] = mode;
    if (!SBCPUThermalWritePrefs(prefs)) return;
    SBCPUThermalPostPowerMode(mode);
    notify_post("com.yourname.sbcpufloating/settingsChanged");
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.yourname.sbcpufloating.prefschanged"), NULL, NULL, YES);
    [self.navigationController popViewControllerAnimated:YES];
}
- (void)selectLowPower { [self chooseMode:@"lowPower"]; }
- (void)selectFullPower { [self chooseMode:@"fullPower"]; }
- (void)selectExtremeFull { [self chooseMode:@"extremeFull"]; }
@end
