#ifndef SBCPU_TELEMETRY_FORMAT_H
#define SBCPU_TELEMETRY_FORMAT_H
#import <Foundation/Foundation.h>
#include <sys/sysctl.h>
#include <time.h>
#include <math.h>
static inline double SBCTMono(void) {
    struct timespec t = {0}; clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}
static inline NSString *SBCTBoot(void) {
    struct timeval t = {0}; size_t size = sizeof(t); int mib[] = {CTL_KERN, KERN_BOOTTIME};
    if (sysctl(mib, 2, &t, &size, NULL, 0) != 0) return @"unknown";
    return [NSString stringWithFormat:@"%lld.%06d", (long long)t.tv_sec, (int)t.tv_usec];
}
static inline NSArray *SBCTKeys(void) {
    return @[@"thermalEngineEnabled", @"powerMode", @"thermalPressureAutoProtectionEnabled", @"thermalLockScreenLowPowerEnabled", @"thermalNominalAutoRecoveryEnabled", @"thermalPreventDimmingEnabled", @"thermalBlockNotifPopup"];
}
// Stable, normalized revision content, not a UI request. Defaults match the existing loader.
static inline NSDictionary *SBCTConfig(NSDictionary *d) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSString *k in SBCTKeys()) {
        if ([k isEqual:@"powerMode"]) {
            id v = d[k]; result[k] = [v isKindOfClass:NSString.class] && [@[@"lowPower", @"extremeFull"] containsObject:v] ? v : @"fullPower";
        } else result[k] = d[k] ? @([d[k] boolValue]) : @(![@[@"thermalPreventDimmingEnabled", @"thermalBlockNotifPopup"] containsObject:k]);
    }
    return result;
}
static inline NSString *SBCTValidate(id object, NSString *boot, double wall, double mono) {
    if (!object) return @"missing";
    if (![object isKindOfClass:NSDictionary.class]) return @"malformed";
    NSDictionary *d = object;
    for (NSString *k in @[@"schema", @"pid", @"sequence", @"wall", @"mono"])
        if (![d[k] isKindOfClass:NSNumber.class]) return @"malformed";
    for (NSString *k in @[@"boot", @"session", @"process"])
        if (![d[k] isKindOfClass:NSString.class] || ![d[k] length]) return @"malformed";
    for (NSString *k in @[@"runtime", @"config"])
        if (![d[k] isKindOfClass:NSDictionary.class]) return @"malformed";
    if (![d[@"configLoaded"] isKindOfClass:NSNumber.class] || ![d[@"lastLoadSucceeded"] isKindOfClass:NSNumber.class] || ![d[@"loadStatus"] isKindOfClass:NSString.class] || ![d[@"revision"] isKindOfClass:NSNumber.class] || ![d[@"lastLoadWall"] isKindOfClass:NSNumber.class] || ![d[@"lastSuccessfulLoadWall"] isKindOfClass:NSNumber.class]) return @"malformed";
    if ([d[@"configLoaded"] boolValue]) for (NSString *key in SBCTKeys()) if (![d[@"config"][key] isKindOfClass:[key isEqual:@"powerMode"] ? NSString.class : NSNumber.class]) return @"malformed";
    NSDictionary *runtime = d[@"runtime"];
    for (NSString *k in @[@"effectiveMode", @"selectedMode", @"reason"])
        if (![runtime[k] isKindOfClass:NSString.class]) return @"malformed";
    if (![@[@"fullPower", @"lowPower", @"extremeFull", @"unknown"] containsObject:runtime[@"effectiveMode"]]) return @"malformed";
    if (![d[@"hooks"] isKindOfClass:NSArray.class] || [d[@"hooks"] count] > 16) return @"malformed";
    for (id hook in d[@"hooks"]) {
        if (![hook isKindOfClass:NSDictionary.class]) return @"malformed";
        for (NSString *k in @[@"class", @"selector", @"installation", @"result"])
            if (![hook[k] isKindOfClass:NSString.class]) return @"malformed";
        for (NSString *k in @[@"called", @"callCount", @"lastCalledMono", @"methodPresent", @"implementationInCore"])
            if (![hook[k] isKindOfClass:NSNumber.class]) return @"malformed";
    }
    if (![d[@"routes"] isKindOfClass:NSArray.class] || [d[@"routes"] count] > 16 || ![d[@"events"] isKindOfClass:NSArray.class] || [d[@"events"] count] > 80) return @"malformed";
    for (id route in d[@"routes"]) if (![route isKindOfClass:NSDictionary.class] || ![route[@"name"] isKindOfClass:NSString.class] || ![route[@"count"] isKindOfClass:NSNumber.class] || ![route[@"result"] isKindOfClass:NSString.class]) return @"malformed";
    for (id event in d[@"events"]) if (![event isKindOfClass:NSDictionary.class] || ![event[@"route"] isKindOfClass:NSString.class] || ![event[@"count"] isKindOfClass:NSNumber.class] || ![event[@"coalesced"] isKindOfClass:NSNumber.class] || ![event[@"result"] isKindOfClass:NSString.class]) return @"malformed";
    if ([d[@"schema"] intValue] != 1 || [d[@"pid"] intValue] <= 0 || [d[@"sequence"] longLongValue] <= 0 || ![d[@"process"] isEqual:@"thermalmonitord"]) return @"malformed";
    double w = [d[@"wall"] doubleValue], m = [d[@"mono"] doubleValue];
    if (!isfinite(w) || !isfinite(m) || w <= 0 || m < 0) return @"malformed";
    if ([boot isEqual:@"unknown"] || ![d[@"boot"] isEqual:boot]) return @"wrongboot";
    if (w > wall + 2 || m > mono + 0.1) return @"future";
    return mono - m <= 15 && wall - w <= 15 ? @"recent" : @"stale";
}
static inline BOOL SBCTSequenceOK(NSDictionary *previous, NSDictionary *current) {
    if (![previous[@"session"] isEqual:current[@"session"]]) return YES;
    return [current[@"sequence"] unsignedLongLongValue] >= [previous[@"sequence"] unsignedLongLongValue];
}
#endif
