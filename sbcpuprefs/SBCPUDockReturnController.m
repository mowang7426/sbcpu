#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <notify.h>
@interface SBCPUDockReturnController : PSListController @end
@implementation SBCPUDockReturnController
- (NSArray *)specifiers { if (!_specifiers) _specifiers=[self loadSpecifiersFromPlistName:@"DockReturn" target:self]; return _specifiers; }
- (id)getValue:(PSSpecifier *)s { CFPropertyListRef v=CFPreferencesCopyValue(CFSTR("statusDockReturnDelay"),CFSTR("com.yourname.sbcpufloating"),kCFPreferencesCurrentUser,kCFPreferencesAnyHost); return v?CFBridgingRelease(v):@5; }
- (void)setValue:(id)value specifier:(PSSpecifier *)s { NSNumber *n=[value isKindOfClass:[NSNumber class]]?value:@([value integerValue]); if(!n)return; CFPreferencesSetValue(CFSTR("statusDockReturnDelay"),(__bridge CFPropertyListRef)n,CFSTR("com.yourname.sbcpufloating"),kCFPreferencesCurrentUser,kCFPreferencesAnyHost); CFPreferencesSynchronize(CFSTR("com.yourname.sbcpufloating"),kCFPreferencesCurrentUser,kCFPreferencesAnyHost); notify_post("com.yourname.sbcpufloating.prefschanged"); }
@end
