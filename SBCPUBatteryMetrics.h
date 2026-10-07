#ifndef SBCPU_BATTERY_METRICS_H
#define SBCPU_BATTERY_METRICS_H
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#include <math.h>

// Pure Foundation, no IOKit, UIKit, disk, socket, clock reads or charge-policy writes.
// Caller owns a serially accessed history and supplies monotonic systemUptime.
static inline NSNumber *SBCPUBatteryNumber(id value) {
    if (![value isKindOfClass:[NSNumber class]]) return nil;
    if (CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return nil;
    return isfinite([value doubleValue]) ? value : nil;
}

// Tri-state: absent/malformed != false. Accept CFBoolean and numeric 0/1 only.
static inline NSInteger SBCPUBatteryFlag(id value) {
    if (![value isKindOfClass:[NSNumber class]]) return -1;
    double v = [value doubleValue];
    return v == 0.0 ? 0 : (v == 1.0 ? 1 : -1);
}

static inline NSString *SBCPUBatteryManufacturer(id value) {
    NSString *text = nil;
    if ([value isKindOfClass:[NSString class]]) {
        text = value;
    } else if ([value isKindOfClass:[NSData class]]) {
        NSData *data = value; // CFData is toll-free bridged; only strict UTF-8.
        if (data.length == 0 || data.length > 256) return @"厂商未知";
        const unsigned char *bytes = (const unsigned char *)data.bytes;
        NSUInteger length = data.length;
        while (length > 0 && bytes[length - 1] == 0) length--;
        if (length == 0) return @"厂商未知";
        text = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(0, length)]
                                   encoding:NSUTF8StringEncoding];
    }
    if (!text || text.length > 128) return @"厂商未知";
    text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (text.length == 0 || text.length > 64) return @"厂商未知";
    NSMutableCharacterSet *allowed = [[NSCharacterSet alphanumericCharacterSet] mutableCopy];
    [allowed addCharactersInString:@" .,&()-_/+"];
    if ([text rangeOfCharacterFromSet:[allowed invertedSet]].location != NSNotFound ||
        [text rangeOfCharacterFromSet:[NSCharacterSet letterCharacterSet]].location == NSNotFound)
        return @"厂商未知";
    NSArray *unknown = @[@"unknown", @"unknown manufacturer", @"null", @"(null)",
                         @"nil", @"none", @"n/a", @"na", @"not available", @"未提供", @"未知"];
    if ([unknown containsObject:text.lowercaseString]) return @"厂商未知";
    // Exact aliases only. Never map cell supplier codes or serial prefixes to brands.
    if ([@[@"apple", @"apple inc", @"apple inc.", @"apple, inc."] containsObject:text.lowercaseString])
        return @"Apple";
    return text;
}

static inline NSDictionary *SBCPUBatteryDictionary(id value) {
    return [value isKindOfClass:[NSDictionary class]] ? value : @{};
}

static inline NSString *SBCPUBatteryManufacturerFromProperties(id properties) {
    NSDictionary *p = SBCPUBatteryDictionary(properties);
    // BatteryData is specific to the battery pack; prefer it to a generic device
    // Manufacturer field. Never infer a retail brand from serials or supplier codes.
    for (NSDictionary *location in @[SBCPUBatteryDictionary(p[@"BatteryData"]), p]) {
        for (NSString *key in @[@"Manufacturer", @"ManufacturerName"]) {
            NSString *name = SBCPUBatteryManufacturer(location[key]);
            if (![name isEqualToString:@"厂商未知"]) return name;
        }
    }
    return @"厂商未知";
}

// Numeric fallbacks consider only well-typed finite numbers within explicit units/ranges.
static inline NSNumber *SBCPUBatteryFindNumber(NSDictionary *p, NSArray *keys,
                                              double minimum, double maximum) {
    NSDictionary *nested = SBCPUBatteryDictionary(p[@"BatteryData"]);
    for (NSDictionary *location in @[p, nested]) {
        for (NSString *key in keys) {
            NSNumber *n = SBCPUBatteryNumber(location[key]);
            if (n && n.doubleValue >= minimum && n.doubleValue <= maximum) return n;
        }
    }
    return nil;
}

// Snapshot must receive ORIGINAL registry properties, not UI-synthesized capacities,
// abs(current), design-capacity substitutions, or a default battery percentage.
// Optional SBCPUChargeBlocked/SBCPUChargePaused are fresh ACTUAL cached status only.
static inline NSDictionary *SBCPUBatterySnapshot(id properties, NSTimeInterval uptime) {
    NSDictionary *p = SBCPUBatteryDictionary(properties);
    NSMutableDictionary *s = [NSMutableDictionary dictionary];
    s[@"Uptime"] = @(uptime);
    s[@"Manufacturer"] = SBCPUBatteryManufacturerFromProperties(p);
    for (NSString *key in @[@"ExternalConnected", @"IsCharging", @"FullyCharged"])
        s[key] = @(SBCPUBatteryFlag(p[key]));
    BOOL blocked = SBCPUBatteryFlag(p[@"ChargingBlocked"]) == 1 ||
                   SBCPUBatteryFlag(p[@"SBCPUChargeBlocked"]) == 1;
    s[@"Blocked"] = @(blocked);
    s[@"Paused"] = @(SBCPUBatteryFlag(p[@"SBCPUChargePaused"]) == 1);
    for (NSDictionary *location in @[p, SBCPUBatteryDictionary(p[@"BatteryData"])]) {
        for (NSString *key in @[@"AvgTimeToFull", @"TimeToFull"]) {
            NSNumber *minutes = SBCPUBatteryNumber(location[key]);
            if (minutes && minutes.doubleValue >= 1.0 && minutes.doubleValue <= 1440.0 &&
                floor(minutes.doubleValue) == minutes.doubleValue && !s[@"SystemMinutes"])
                s[@"SystemMinutes"] = minutes;
        }
    }
    NSNumber *current = SBCPUBatteryFindNumber(p, @[@"Amperage", @"InstantAmperage"], -10000.0, 10000.0);
    if (current) s[@"CurrentMA"] = current; // Signed NET battery current. NEVER fabs.

    NSNumber *maximum = SBCPUBatteryFindNumber(p,
        @[@"AppleRawMaxCapacity", @"NominalChargeCapacity", @"MaxCapacity"], 101.0, 20000.0);
    NSNumber *rawCurrent = SBCPUBatteryFindNumber(p, @[@"AppleRawCurrentCapacity"], 0.0, 20000.0);
    NSNumber *nativeMax = SBCPUBatteryNumber(p[@"MaxCapacity"]);
    NSNumber *nativeCurrent = SBCPUBatteryNumber(p[@"CurrentCapacity"]);
    NSNumber *percent = SBCPUBatteryFindNumber(p, @[@"SBCPUBatteryPercent", @"StateOfCharge"], 0.0, 100.0);
    // Paired percentage properties are not mAh. A missing/ambiguous unit is not guessed.
    if (!percent && nativeMax && nativeMax.doubleValue == 100.0 && nativeCurrent &&
        nativeCurrent.doubleValue >= 0.0 && nativeCurrent.doubleValue <= 100.0)
        percent = nativeCurrent;
    if (!rawCurrent && nativeMax && nativeMax.doubleValue > 100.0 &&
        nativeMax.doubleValue <= 20000.0 && nativeCurrent) {
        maximum = nativeMax; // Native mAh pair must use its own upper bound.
        rawCurrent = nativeCurrent;
    }
    if (!rawCurrent && maximum && percent) rawCurrent = @(maximum.doubleValue * percent.doubleValue / 100.0);
    if (maximum && rawCurrent && rawCurrent.doubleValue >= 0.0 && rawCurrent.doubleValue <= maximum.doubleValue) {
        s[@"MaximumMAh"] = maximum;
        s[@"RemainingMAh"] = @(maximum.doubleValue - rawCurrent.doubleValue);
        s[@"SOC"] = @(rawCurrent.doubleValue / maximum.doubleValue);
    }
    if (percent) s[@"Percent"] = percent;
    // Adapter changes reset the current window; identity is never used for branding.
    NSDictionary *adapter = SBCPUBatteryDictionary(p[@"AdapterDetails"]);
    NSMutableDictionary *identity = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"SerialString", @"Name", @"Description", @"Watts"])
        if (adapter[key]) identity[key] = adapter[key];
    s[@"AdapterIdentity"] = [identity copy];
    return [s copy];
}

static inline BOOL SBCPUBatteryCanSample(NSDictionary *s) {
    NSNumber *n = SBCPUBatteryNumber(s[@"CurrentMA"]);
    return SBCPUBatteryFlag(s[@"ExternalConnected"]) == 1 &&
           SBCPUBatteryFlag(s[@"IsCharging"]) == 1 &&
           SBCPUBatteryFlag(s[@"FullyCharged"]) != 1 &&
           SBCPUBatteryFlag(s[@"Blocked"]) != 1 && SBCPUBatteryFlag(s[@"Paused"]) != 1 &&
           n && n.doubleValue >= 100.0 && n.doubleValue <= 10000.0;
}

// Feed each new collected snapshot (not the same cached sample with a new timestamp).
// 30s sustained positive samples; <=10s gaps; bounded 120s / 64 observations.
static inline void SBCPUBatteryAppendSample(NSMutableArray *history, NSDictionary *snapshot) {
    NSDictionary *s = SBCPUBatteryDictionary(snapshot);
    NSNumber *stamp = SBCPUBatteryNumber(s[@"Uptime"]);
    if (!stamp || stamp.doubleValue < 0.0 || !SBCPUBatteryCanSample(s)) {
        [history removeAllObjects];
        return;
    }
    NSDictionary *previous = history.lastObject;
    if (previous) {
        double dt = stamp.doubleValue - [previous[@"Uptime"] doubleValue];
        if (dt < 0.0 || dt > 10.0 ||
            ![s[@"AdapterIdentity"] isEqual:previous[@"AdapterIdentity"]]) {
            [history removeAllObjects];
        } else if (dt < 1.0) {
            return; // Repeated getter/UI calls cannot manufacture a sustained window.
        }
    }
    [history addObject:[s copy]];
    while (history.count > 64 || (history.count > 1 &&
           stamp.doubleValue - [history.firstObject[@"Uptime"] doubleValue] > 120.0))
        [history removeObjectAtIndex:0];
}

// Use the slower of whole-window and recent (~15s) time-weighted means.
// Reject unstable currents rather than presenting a precise answer from a transient peak.
static inline double SBCPUBatterySustainedCurrent(NSArray *history, NSDictionary *s) {
    if (history.count < 4) return 0.0;
    NSDictionary *last = history.lastObject;
    double end = [s[@"Uptime"] doubleValue];
    double lastTime = [last[@"Uptime"] doubleValue];
    if (end < lastTime || end - lastTime > 10.0 ||
        ![s[@"AdapterIdentity"] isEqual:last[@"AdapterIdentity"]]) return 0.0;
    double start = [history.firstObject[@"Uptime"] doubleValue];
    if (lastTime - start < 30.0 || lastTime - start > 120.0) return 0.0;
    double area = 0.0, recentArea = 0.0, duration = 0.0, recentDuration = 0.0;
    double low = INFINITY, high = 0.0;
    NSDictionary *previous = nil;
    for (NSDictionary *sample in history) {
        if (!SBCPUBatteryCanSample(sample) ||
            ![sample[@"AdapterIdentity"] isEqual:s[@"AdapterIdentity"]]) return 0.0;
        double ma = [sample[@"CurrentMA"] doubleValue];
        low = fmin(low, ma); high = fmax(high, ma);
        if (previous) {
            double t0 = [previous[@"Uptime"] doubleValue], t1 = [sample[@"Uptime"] doubleValue];
            double dt = t1 - t0;
            if (dt < 1.0 || dt > 10.0) return 0.0;
            double mean = ([previous[@"CurrentMA"] doubleValue] + ma) / 2.0;
            area += mean * dt; duration += dt;
            double recentDT = fmax(0.0, t1 - fmax(t0, lastTime - 15.0));
            recentArea += mean * recentDT; recentDuration += recentDT;
        }
        previous = sample;
    }
    if (high > low * 2.0 || duration <= 0.0 || recentDuration <= 0.0) return 0.0;
    double current = fmin(area / duration, recentArea / recentDuration);
    // The newest reading must still support the window; don't conceal a sudden drop.
    NSNumber *latest = SBCPUBatteryNumber(s[@"CurrentMA"]);
    if (!latest || latest.doubleValue < current * 0.5) return 0.0;
    return fmin(current, latest.doubleValue);
}

// Generic CC/CV allowance, not a calibrated battery/charger model or a deadline.
// Anchor to the currently observed stage to avoid applying past taper a second time.
static inline double SBCPUBatteryTaperWeightedRemaining(double maximum, double soc) {
    const double edges[] = {0.0, 0.80, 0.90, 0.95, 1.0};
    const double rates[] = {1.0, 0.65, 0.40, 0.20};
    NSUInteger stage = 0;
    while (stage < 3 && soc >= edges[stage + 1]) stage++;
    double weighted = 0.0;
    for (NSUInteger i = stage; i < 4; i++)
        weighted += fmax(0.0, edges[i + 1] - fmax(soc, edges[i])) * maximum * rates[stage] / rates[i];
    return weighted;
}

// Public display result is always explicit; no indefinite "calculating" state.
static inline NSString *SBCPUBatteryETAText(id snapshot, NSArray *history, NSTimeInterval now) {
    NSDictionary *s = SBCPUBatteryDictionary(snapshot);
    NSNumber *stamp = SBCPUBatteryNumber(s[@"Uptime"]);
    if (!stamp || !isfinite(now) || now < stamp.doubleValue || now - stamp.doubleValue > 15.0)
        return @"暂无实时充电数据";
    if (SBCPUBatteryFlag(s[@"Blocked"]) == 1) return @"已阻止充电";
    NSInteger external = SBCPUBatteryFlag(s[@"ExternalConnected"]);
    if (external == 0) return @"未连接电源";
    if (external != 1) return @"电源连接状态未知";
    if (SBCPUBatteryFlag(s[@"FullyCharged"]) == 1) return @"已充满";
    if (SBCPUBatteryFlag(s[@"Paused"]) == 1) return @"充电已暂停";
    NSInteger charging = SBCPUBatteryFlag(s[@"IsCharging"]);
    if (charging == 0) return @"已接电，未在充电";
    if (charging != 1) return @"充电状态未知";
    NSNumber *current = SBCPUBatteryNumber(s[@"CurrentMA"]);
    if (current && current.doubleValue <= 0.0) return @"未净充入，暂无法估算";
    NSNumber *system = SBCPUBatteryNumber(s[@"SystemMinutes"]);
    if (system && system.doubleValue >= 1.0 && system.doubleValue <= 1440.0)
        return [NSString stringWithFormat:@"约%.0f分钟（系统）", ceil(system.doubleValue / 5.0) * 5.0];
    NSNumber *remaining = SBCPUBatteryNumber(s[@"RemainingMAh"]);
    NSNumber *maximum = SBCPUBatteryNumber(s[@"MaximumMAh"]);
    NSNumber *soc = SBCPUBatteryNumber(s[@"SOC"]);
    if (remaining && remaining.doubleValue <= 0.0) return @"电量已满，等待充电完成";
    if (!current) return @"充电电流未知，暂无法估算";
    if (current.doubleValue < 100.0) return @"充电电流过低，暂无法估算";
    if (!remaining || !maximum || !soc || remaining.doubleValue <= 0.0 ||
        maximum.doubleValue <= 100.0 || soc.doubleValue < 0.0 || soc.doubleValue >= 1.0)
        return @"容量数据不足，暂无法估算";
    double sustained = SBCPUBatterySustainedCurrent(history, s);
    if (sustained <= 0.0) return @"电流采样不足或波动，暂无法估算";
    double linear = remaining.doubleValue / sustained * 60.0;
    double tapered = SBCPUBatteryTaperWeightedRemaining(maximum.doubleValue, soc.doubleValue) / sustained * 60.0;
    double lower = fmax(5.0, floor(linear / 5.0) * 5.0);
    double upper = ceil(fmax(linear * 1.6, tapered * 1.5) / 5.0) * 5.0;
    if (!isfinite(upper) || upper > 1440.0) return @"充电缓慢，暂无法可靠估算";
    upper = fmax(upper, lower + 5.0);
    return [NSString stringWithFormat:@"约%.0f–%.0f分钟（估算）", lower, upper];
}
#endif
