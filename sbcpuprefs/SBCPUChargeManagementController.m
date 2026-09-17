#import "SBCPUChargeManagementController.h"
#import "SBCPUChargePreferencesCommon.h"

@implementation SBCPUChargeManagementController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"ChargingManagement" target:self];
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
    self.title = @"充电管理";
}

@end
