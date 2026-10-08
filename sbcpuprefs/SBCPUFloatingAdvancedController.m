#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import "../SBCPUChargeStore.h"
#import "../include/SBCPUThermalPaths.h"
#import "SBCPUThermalPreferenceUI.h"
#import <notify.h>
@interface SBCPUFloatingAdvancedController : PSListController @end
@implementation SBCPUFloatingAdvancedController
- (NSArray *)specifiers { if (!_specifiers) _specifiers=[self loadSpecifiersFromPlistName:@"Advanced" target:self]; return _specifiers; }
- (BOOL)isThermal:(NSString *)k { return SBCPUIsThermalPreference(k); }
- (BOOL)isChargeStore:(NSString *)k { return [@[@"blockChargingEnable",@"blockPowerEnable"] containsObject:k]; }
- (id)getPreferenceValue:(PSSpecifier *)sp { NSString *k=[sp propertyForKey:@"key"]; if ([self isThermal:k]) return SBCPUThermalPreferenceValue(SBCPUThermalReadPrefs(), k, [sp propertyForKey:@"default"]); if ([self isChargeStore:k]) return SBChargeRead()[k]?:[sp propertyForKey:@"default"]; CFPropertyListRef v=CFPreferencesCopyValue((__bridge CFStringRef)k,CFSTR("com.yourname.sbcpufloating"),kCFPreferencesCurrentUser,kCFPreferencesAnyHost); return v?CFBridgingRelease(v):[sp propertyForKey:@"default"]; }
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)sp { NSString *k=[sp propertyForKey:@"key"]; if ([self isThermal:k]) {
    if (!SBCPUSaveThermalPreference(k, value)) {
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
} else if ([self isChargeStore:k]) { SBChargePatch(@{k:value?:@NO}); } else { CFPreferencesSetValue((__bridge CFStringRef)k,(__bridge CFPropertyListRef)value,CFSTR("com.yourname.sbcpufloating"),kCFPreferencesCurrentUser,kCFPreferencesAnyHost); CFPreferencesSynchronize(CFSTR("com.yourname.sbcpufloating"),kCFPreferencesCurrentUser,kCFPreferencesAnyHost); } notify_post("com.yourname.sbcpufloating.prefschanged"); }
- (void)viewDidLoad { [super viewDidLoad]; self.title=@"浮窗全部设置"; }
@end
