#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import "SBCPUChargePreferencesCommon.h"

@interface SBCPULiquidGlassController : PSListController
@end

@implementation SBCPULiquidGlassController
- (NSArray *)specifiers {
    if (!_specifiers) _specifiers = [self loadSpecifiersFromPlistName:@"LiquidGlass" target:self];
    return _specifiers;
}
- (id)getPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    id def = [specifier propertyForKey:@"default"];
    return [SBCPUChargePreferencesCommon valueForKey:key defaultValue:def];
}
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    [SBCPUChargePreferencesCommon setValue:value forKey:key];
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"液态玻璃调节";
}
@end
