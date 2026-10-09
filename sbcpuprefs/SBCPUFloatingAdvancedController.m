#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import "../SBCPUChargeStore.h"
#import <notify.h>
@interface SBCPUFloatingAdvancedController : PSListController @end
@implementation SBCPUFloatingAdvancedController
- (NSArray *)specifiers { if (!_specifiers) _specifiers=[self loadSpecifiersFromPlistName:@"Advanced" target:self]; return _specifiers; }
- (BOOL)isChargeStore:(NSString *)k { return [@[@"blockChargingEnable",@"blockPowerEnable"] containsObject:k]; }
- (id)getPreferenceValue:(PSSpecifier *)sp { NSString *k=[sp propertyForKey:@"key"]; if ([self isChargeStore:k]) return SBChargeRead()[k]?:[sp propertyForKey:@"default"]; CFPropertyListRef v=CFPreferencesCopyValue((__bridge CFStringRef)k,CFSTR("com.yourname.sbcpufloating"),kCFPreferencesCurrentUser,kCFPreferencesAnyHost); return v?CFBridgingRelease(v):[sp propertyForKey:@"default"]; }
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)sp { NSString *k=[sp propertyForKey:@"key"]; if ([self isChargeStore:k]) { SBChargePatch(@{k:value?:@NO}); } else { CFPreferencesSetValue((__bridge CFStringRef)k,(__bridge CFPropertyListRef)value,CFSTR("com.yourname.sbcpufloating"),kCFPreferencesCurrentUser,kCFPreferencesAnyHost); CFPreferencesSynchronize(CFSTR("com.yourname.sbcpufloating"),kCFPreferencesCurrentUser,kCFPreferencesAnyHost); } notify_post("com.yourname.sbcpufloating.prefschanged"); }
- (void)viewDidLoad { [super viewDidLoad]; self.title=@"浮窗全部设置"; }
@end
