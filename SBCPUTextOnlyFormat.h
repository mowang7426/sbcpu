#ifndef SBCPU_TEXT_ONLY_FORMAT_H
#define SBCPU_TEXT_ONLY_FORMAT_H
#import <Foundation/Foundation.h>
#include <math.h>

// Presentation inputs only: no thermal/charging status or controller settings.
typedef struct {
    BOOL cpu, frequency, fps, battery, temperature, current, sim1, sim2;
} SBCPUTextOnlyFields;

static inline NSString *SBCPUTextOnlyCompactValue(NSString *value, NSString *unit, BOOL allowNegative) {
    if (![value isKindOfClass:[NSString class]]) return [@"--" stringByAppendingString:unit];
    NSString *compact = [[value componentsSeparatedByCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet] componentsJoinedByString:@""];
    if (![compact hasSuffix:unit]) return [@"--" stringByAppendingString:unit];
    NSString *number = [compact substringToIndex:compact.length - unit.length];
    NSScanner *scanner = [NSScanner scannerWithString:number];
    scanner.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    double parsed = 0;
    if (![scanner scanDouble:&parsed] || !scanner.isAtEnd || !isfinite(parsed) ||
        (!allowNegative && parsed < 0)) return [@"--" stringByAppendingString:unit];
    return [number stringByAppendingString:unit];
}

static inline NSString *SBCPUTextOnlySignal(NSArray<NSDictionary *> *signals, NSInteger slot) {
    NSString *dbm = @"--";
    for (NSDictionary *signal in signals) {
        if ([signal[@"slot"] integerValue] == slot) {
            NSString *raw = [signal[@"dbm"] isKindOfClass:[NSString class]] ? signal[@"dbm"] : nil;
            NSString *validated = SBCPUTextOnlyCompactValue([raw stringByAppendingString:@"dBm"], @"dBm", YES);
            dbm = [validated substringToIndex:validated.length - 3];
            break;
        }
    }
    // Deliberately omit carrier names/band/technology; these remain in ordinary UI.
    return [NSString stringWithFormat:@"S%ld%@dBm", (long)slot, dbm];
}

static inline NSString *SBCPUTextOnlyRow(SBCPUTextOnlyFields fields,
    NSString *cpu, NSString *frequency, NSString *fps, NSString *battery,
    NSString *temperature, NSString *current, NSArray<NSDictionary *> *signals) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (fields.cpu) [parts addObject:[@"◉" stringByAppendingString:SBCPUTextOnlyCompactValue(cpu, @"%", NO)]];
    if (fields.frequency) [parts addObject:SBCPUTextOnlyCompactValue(frequency, @"MHz", NO)];
    if (fields.fps) [parts addObject:SBCPUTextOnlyCompactValue([fps isKindOfClass:[NSString class]] ? [fps stringByAppendingString:@"fps"] : nil, @"fps", NO)];
    if (fields.battery) [parts addObject:[@"▰" stringByAppendingString:SBCPUTextOnlyCompactValue(battery, @"%", NO)]];
    if (fields.temperature) [parts addObject:SBCPUTextOnlyCompactValue(temperature, @"°C", YES)];
    if (fields.current) [parts addObject:SBCPUTextOnlyCompactValue(current, @"mA", YES)];
    if (fields.sim1) [parts addObject:SBCPUTextOnlySignal(signals, 1)];
    if (fields.sim2) [parts addObject:SBCPUTextOnlySignal(signals, 2)];
    return [parts componentsJoinedByString:@" · "];
}
#endif
