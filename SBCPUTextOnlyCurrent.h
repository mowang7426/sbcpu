#ifndef SBCPU_TEXT_ONLY_CURRENT_H
#define SBCPU_TEXT_ONLY_CURRENT_H
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#include <math.h>
#include <stdint.h>
#include <string.h>

// Signed NET battery current in mA, not charger input or a charging-state estimate.
// Only reinterpret two's-complement values when NSNumber explicitly carries a
// 16/32-bit unsigned type. A missing/invalid measurement must remain missing.
static inline NSNumber *SBCPUTextOnlyCurrentNumber(id value) {
    if (![value isKindOfClass:[NSNumber class]] ||
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return nil;
    const char *type = [value objCType];
    double current = [value doubleValue];
    if (!isfinite(current)) return nil;
    if (strcmp(type, @encode(unsigned short)) == 0) {
        unsigned long long raw = [value unsignedLongLongValue];
        if (raw > INT16_MAX) current = (double)raw - 65536.0;
    } else if (strcmp(type, @encode(unsigned int)) == 0) {
        unsigned long long raw = [value unsignedLongLongValue];
        if (raw > INT32_MAX) current = (double)raw - 4294967296.0;
    }
    if (current < -10000.0 || current > 10000.0) return nil;
    return @(current);
}

static inline NSNumber *SBCPUTextOnlyBatteryCurrent(id properties) {
    if (![properties isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *p = properties;
    id nested = p[@"BatteryData"];
    for (NSDictionary *source in @[p, [nested isKindOfClass:[NSDictionary class]] ? nested : @{}]) {
        for (NSString *key in @[@"Amperage", @"InstantAmperage"]) {
            NSNumber *n = SBCPUTextOnlyCurrentNumber(source[key]);
            if (n) return n;
        }
    }
    return nil;
}

static inline NSString *SBCPUTextOnlyCurrentText(NSNumber *current, NSTimeInterval sampledAt,
                                                 NSTimeInterval now) {
    if (!current || !isfinite(sampledAt) || !isfinite(now) ||
        sampledAt <= 0 || now < sampledAt || now - sampledAt > 3.0) return @"--mA";
    NSNumber *validated = SBCPUTextOnlyCurrentNumber(current);
    if (!validated) return @"--mA";
    double value = validated.doubleValue;
    return [NSString stringWithFormat:@"%.0fmA", value == 0 ? 0.0 : value];
}
#endif
