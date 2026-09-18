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


- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Preferences 可能缓存 specifier/cell；每次返回页面都重新读取持久化值。
    [self reloadSpecifiers];
    if ([self respondsToSelector:@selector(table)]) {
        [[self table] reloadData];
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"充电限制";
}

@end
