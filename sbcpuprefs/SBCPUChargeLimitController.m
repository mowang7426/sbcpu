#import "SBCPUChargeLimitController.h"
#import "SBCPUChargePreferencesCommon.h"

@implementation SBCPUChargeLimitController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"ChargingLimit" target:self];
    }
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
    [SBCPUChargePreferencesCommon redecideDaemon];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"充电限制";
}

@end
