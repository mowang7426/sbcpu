#import <UIKit/UIKit.h>
#import "SBCPUChargeLimitController.h"
#import "SBCPUChargePreferencesCommon.h"

@implementation SBCPUChargeLimitController

- (NSArray *)specifiers {
    if (!_specifiers) _specifiers = [self loadSpecifiersFromPlistName:@"ChargingLimit" target:self];
    return _specifiers;
}

- (id)getPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    id def = [specifier propertyForKey:@"default"];
    id value = [SBCPUChargePreferencesCommon valueForKey:key defaultValue:def];
    if ([key hasSuffix:@"Hour"]) {
        NSInteger hour = [value integerValue];
        NSString *minuteKey = [key stringByReplacingOccurrencesOfString:@"Hour" withString:@"Minute"];
        NSInteger minuteDefault = [key isEqualToString:@"chargeScheduleStartHour"] ? 0 : 30;
        NSInteger minute = [[SBCPUChargePreferencesCommon valueForKey:minuteKey defaultValue:@(minuteDefault)] integerValue];
        return [NSString stringWithFormat:@"%02ld:%02ld", (long)hour, (long)minute];
    }
    if ([key isEqualToString:@"smartChargeUpperLimit"] || [key isEqualToString:@"smartChargeLowerLimit"]) {
        return [NSString stringWithFormat:@"%ld%%", (long)[value integerValue]];
    }
    return value;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    [SBCPUChargePreferencesCommon setValue:value forKey:key];
    [SBCPUChargePreferencesCommon redecideDaemon];
}

- (void)selectScheduleValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    BOOL isTime = [key hasSuffix:@"Hour"];
    NSMutableArray *values = [NSMutableArray array];
    NSMutableArray *titles = [NSMutableArray array];
    if (isTime) {
        for (NSInteger h = 0; h < 24; h++) for (NSInteger m = 0; m < 60; m += 30) {
            [values addObject:@[@(h), @(m)]];
            [titles addObject:[NSString stringWithFormat:@"%02ld:%02ld", (long)h, (long)m]];
        }
    } else {
        NSInteger min = [key isEqualToString:@"smartChargeLowerLimit"] ? 20 : 50;
        NSInteger max = [key isEqualToString:@"smartChargeLowerLimit"] ? 95 : 100;
        for (NSInteger p = min; p <= max; p += 5) {
            [values addObject:@(p)];
            [titles addObject:[NSString stringWithFormat:@"%ld%%", (long)p]];
        }
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[specifier name] message:@"请选择一个值" preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSUInteger i = 0; i < values.count; i++) {
        [alert addAction:[UIAlertAction actionWithTitle:titles[i] style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            if (isTime) {
                NSArray *pair = values[i];
                [SBCPUChargePreferencesCommon setValue:pair[0] forKey:key];
                [SBCPUChargePreferencesCommon setValue:pair[1] forKey:[key stringByReplacingOccurrencesOfString:@"Hour" withString:@"Minute"]];
            } else {
                [SBCPUChargePreferencesCommon setValue:values[i] forKey:key];
            }
            [SBCPUChargePreferencesCommon redecideDaemon];
            [self reloadSpecifiers];
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    UIPopoverPresentationController *popover = alert.popoverPresentationController;
    popover.sourceView = self.view;
    popover.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)viewDidLoad { [super viewDidLoad]; self.title = @"充电限制"; }
@end
