#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <notify.h>
@interface SBCPUFloatingAdvancedController : PSListController
@end
@implementation SBCPUFloatingAdvancedController
- (NSArray *)specifiers { if (!_specifiers) _specifiers = [self loadSpecifiersFromPlistName:@"Advanced" target:self]; return _specifiers; }
- (id)getPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    CFPropertyListRef v = CFPreferencesCopyValue((__bridge CFStringRef)key, CFSTR("com.yourname.sbcpufloating"), kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (v) return CFBridgingRelease(v);
    return [specifier propertyForKey:@"default"];
}
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    CFPreferencesSetValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, CFSTR("com.yourname.sbcpufloating"), kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPreferencesSynchronize(CFSTR("com.yourname.sbcpufloating"), kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    notify_post("com.yourname.sbcpufloating.prefschanged");
}
- (void)viewDidLoad { [super viewDidLoad]; self.title = @"浮窗全部设置"; }
@end
