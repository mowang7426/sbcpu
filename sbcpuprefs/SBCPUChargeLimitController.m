#import <UIKit/UIKit.h>
#import "SBCPUChargeLimitController.h"
#import "SBCPUChargePreferencesCommon.h"
#import "../SBCPUChargeDayNight.h"

@implementation SBCPUChargeLimitController

- (NSArray *)specifiers {
    if (!_specifiers) _specifiers = [self loadSpecifiersFromPlistName:@"ChargingLimit" target:self];
    return _specifiers;
}

- (id)getPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    id def = [specifier propertyForKey:@"default"];
    id value = [SBCPUChargePreferencesCommon valueForKey:key defaultValue:def];
    if ([key isEqualToString:@"smartChargeEnable"] || [key isEqualToString:@"chargeScheduleEnabled"]) {
        BOOL autoMode = [[SBCPUChargePreferencesCommon valueForKey:@"chargeDayNightAutoEnable" defaultValue:@NO] boolValue];
        if (autoMode) {
            NSInteger day = [[SBCPUChargePreferencesCommon valueForKey:@"chargeDayStartHour" defaultValue:@8] integerValue] * 60 + [[SBCPUChargePreferencesCommon valueForKey:@"chargeDayStartMinute" defaultValue:@0] integerValue];
            NSInteger night = [[SBCPUChargePreferencesCommon valueForKey:@"chargeNightStartHour" defaultValue:@22] integerValue] * 60 + [[SBCPUChargePreferencesCommon valueForKey:@"chargeNightStartMinute" defaultValue:@0] integerValue];
            NSDateComponents *dc = [[NSCalendar currentCalendar] components:(NSCalendarUnitHour | NSCalendarUnitMinute) fromDate:[NSDate date]];
            BOOL dayNow = sb_charge_is_daytime((int)(dc.hour * 60 + dc.minute), (int)day, (int)night);
            value = @([key isEqualToString:@"smartChargeEnable"] ? dayNow : !dayNow);
        }
    }
    if ([key hasSuffix:@"Hour"]) {
        NSInteger hour = [value integerValue];
        NSString *minuteKey = [key stringByReplacingOccurrencesOfString:@"Hour" withString:@"Minute"];
        NSInteger minuteDefault = ([key isEqualToString:@"chargeScheduleStartHour"] || [key isEqualToString:@"chargeDayStartHour"] || [key isEqualToString:@"chargeNightStartHour"]) ? 0 : 30;
        NSInteger minute = [[SBCPUChargePreferencesCommon valueForKey:minuteKey defaultValue:@(minuteDefault)] integerValue];
        return [NSString stringWithFormat:@"%02ld:%02ld", (long)hour, (long)minute];
    }
    if ([key isEqualToString:@"smartChargeUpperLimit"] || [key isEqualToString:@"smartChargeLowerLimit"]) {
        return [NSString stringWithFormat:@"%ld%%", (long)[value integerValue]];
    }
    if ([key isEqualToString:@"chargeMarqueeStyle"]) {
        return [value integerValue] == 1 ? @"双向对流光" : @"呼吸渐变";
    }
    return value;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if ([key isEqualToString:@"chargeDayNightAutoEnable"] && ![value boolValue]) {
        /* Leaving auto preserves the currently effective mode as the new manual
           baseline; subsequent edits are independent. */
        NSInteger day = [[SBCPUChargePreferencesCommon valueForKey:@"chargeDayStartHour" defaultValue:@8] integerValue] * 60 + [[SBCPUChargePreferencesCommon valueForKey:@"chargeDayStartMinute" defaultValue:@0] integerValue];
        NSInteger night = [[SBCPUChargePreferencesCommon valueForKey:@"chargeNightStartHour" defaultValue:@22] integerValue] * 60 + [[SBCPUChargePreferencesCommon valueForKey:@"chargeNightStartMinute" defaultValue:@0] integerValue];
        NSDateComponents *dc = [[NSCalendar currentCalendar] components:(NSCalendarUnitHour | NSCalendarUnitMinute) fromDate:[NSDate date]];
        BOOL dayNow = sb_charge_is_daytime((int)(dc.hour * 60 + dc.minute), (int)day, (int)night);
        [SBCPUChargePreferencesCommon setValues:@{@"chargeDayNightAutoEnable": @NO,
            @"smartChargeEnable": @(dayNow), @"chargeScheduleEnabled": @(!dayNow)}];
    } else {
        [SBCPUChargePreferencesCommon setValue:value forKey:key];
    }
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
                NSString *minuteKey = [key stringByReplacingOccurrencesOfString:@"Hour" withString:@"Minute"];
                if ([key isEqualToString:@"chargeDayStartHour"] || [key isEqualToString:@"chargeNightStartHour"]) {
                    NSString *otherHour = [key isEqualToString:@"chargeDayStartHour"] ? @"chargeNightStartHour" : @"chargeDayStartHour";
                    NSString *otherMinute = [otherHour stringByReplacingOccurrencesOfString:@"Hour" withString:@"Minute"];
                    NSInteger proposed = [pair[0] integerValue] * 60 + [pair[1] integerValue];
                    NSInteger other = [[SBCPUChargePreferencesCommon valueForKey:otherHour defaultValue:([otherHour hasPrefix:@"chargeDay"] ? @8 : @22)] integerValue] * 60 +
                        [[SBCPUChargePreferencesCommon valueForKey:otherMinute defaultValue:@0] integerValue];
                    if (proposed == other) {
                        UIAlertController *error = [UIAlertController alertControllerWithTitle:@"时间无效" message:@"白天开始时间与夜间开始时间不能相同，请选择不同时间。" preferredStyle:UIAlertControllerStyleAlert];
                        [error addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
                        [self presentViewController:error animated:YES completion:nil];
                        return;
                    }
                    [SBCPUChargePreferencesCommon setValues:@{key: pair[0], minuteKey: pair[1]}];
                } else {
                    [SBCPUChargePreferencesCommon setValue:pair[0] forKey:key];
                    [SBCPUChargePreferencesCommon setValue:pair[1] forKey:minuteKey];
                }
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

- (void)selectMarqueeValue:(PSSpecifier *)specifier {
    NSArray *values = @[@0, @1];
    NSArray *titles = @[@"呼吸渐变", @"双向对流光"];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[specifier name] message:@"请选择充电时的浮窗边框效果" preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSUInteger i = 0; i < values.count; i++) {
        [alert addAction:[UIAlertAction actionWithTitle:titles[i] style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [SBCPUChargePreferencesCommon setValue:values[i] forKey:@"chargeMarqueeStyle"];
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
