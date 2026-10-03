#pragma once
#import <Foundation/Foundation.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
// Separate from the CFPreferences domain: cfprefsd must never rewrite this file.
#ifndef SBCPU_CHARGE_STORE
#define SBCPU_CHARGE_STORE "/var/mobile/Library/Preferences/sbcpu_charge_config.plist"
#endif
#ifndef SBCPU_CHARGE_STORE_LOCK
#define SBCPU_CHARGE_STORE_LOCK "/var/mobile/Library/Preferences/sbcpu_charge_config.lock"
#endif
#ifndef SBCPU_CHARGE_LEGACY
#define SBCPU_CHARGE_LEGACY "/var/mobile/Library/Preferences/com.yourname.sbcpufloating.plist"
#endif
static inline BOOL SBChargeKey(NSString *key) {
    return [key hasPrefix:@"smartCharge"] || [key hasPrefix:@"smartThermal"] ||
        [key hasPrefix:@"chargeSchedule"] || [key hasPrefix:@"chargeDayNight"] ||
        [key hasPrefix:@"chargeDayStart"] || [key hasPrefix:@"chargeNightStart"] || [ @[@"chargeLimitEnabled", @"chargeMarqueeStyle", @"screenRecordingHighFrameRateEnabled", @"chargeKeepAC", @"chargeOverrideOBC", @"blockChargingEnable", @"blockPowerEnable"] containsObject:key];
}
static inline NSMutableDictionary *SBChargeRead(void) {
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:@SBCPU_CHARGE_STORE];
    if (d) return d;
    // Migration is read-only until the first successful edit. Do not populate
    // defaults on root startup before mobile preferences become available.
    NSDictionary *legacy = [NSDictionary dictionaryWithContentsOfFile:@SBCPU_CHARGE_LEGACY];
    d = [NSMutableDictionary dictionary];
    for (NSString *key in legacy) if (SBChargeKey(key)) d[key] = legacy[key];
    return d;
}
static inline BOOL SBChargePatch(NSDictionary *patch) {
    int fd = open(SBCPU_CHARGE_STORE_LOCK, O_CREAT | O_RDWR, 0666);
    if (fd < 0) return NO;
    if (geteuid() == 0) { fchown(fd, 501, 501); fchmod(fd, 0666); }
    if (flock(fd, LOCK_EX) != 0) { close(fd); return NO; }
    NSMutableDictionary *d = SBChargeRead();
    for (NSString *key in patch) if (SBChargeKey(key)) d[key] = patch[key];
    if (patch[@"smartChargeEnable"]) d[@"chargeLimitEnabled"] = d[@"smartChargeEnable"];
    /* Day/night automation has one unambiguous policy. Reject equal boundaries
       while holding the lock, so two writers cannot publish an invalid pair. */
    if (patch[@"chargeDayStartHour"] || patch[@"chargeDayStartMinute"] ||
        patch[@"chargeNightStartHour"] || patch[@"chargeNightStartMinute"] ||
        ([patch[@"chargeDayNightAutoEnable"] boolValue] && patch[@"chargeDayNightAutoEnable"] != nil)) {
        NSInteger day = [d[@"chargeDayStartHour"] ?: @8 integerValue] * 60 + [d[@"chargeDayStartMinute"] ?: @0 integerValue];
        NSInteger night = [d[@"chargeNightStartHour"] ?: @22 integerValue] * 60 + [d[@"chargeNightStartMinute"] ?: @0 integerValue];
        if (day < 0 || day >= 1440 || night < 0 || night >= 1440 || day == night) {
            flock(fd, LOCK_UN); close(fd); return NO;
        }
    }
    NSInteger upper = [(d[@"smartChargeUpperLimit"] ?: @80) integerValue];
    NSInteger lower = [(d[@"smartChargeLowerLimit"] ?: @70) integerValue];
    if (lower >= upper) {
        if (patch[@"smartChargeUpperLimit"]) d[@"smartChargeLowerLimit"] = @(MAX(0, upper - 1));
        else if (patch[@"smartChargeLowerLimit"]) d[@"smartChargeUpperLimit"] = @(MIN(100, lower + 1));
    }
    upper = [(d[@"smartThermalUpperC"] ?: @42) integerValue];
    lower = [(d[@"smartThermalLowerC"] ?: @38) integerValue];
    if (lower >= upper) {
        if (patch[@"smartThermalUpperC"]) d[@"smartThermalLowerC"] = @(MAX(25, upper - 1));
        else if (patch[@"smartThermalLowerC"]) d[@"smartThermalUpperC"] = @(MIN(60, lower + 1));
    }
    BOOL ok = [d writeToFile:@SBCPU_CHARGE_STORE atomically:YES];
    if (ok && geteuid() == 0) {
        ok = chown(SBCPU_CHARGE_STORE, 501, 501) == 0 && chmod(SBCPU_CHARGE_STORE, 0644) == 0;
    }
    NSDictionary *verified = [NSDictionary dictionaryWithContentsOfFile:@SBCPU_CHARGE_STORE];
    ok = ok && [verified isEqualToDictionary:d];
    flock(fd, LOCK_UN); close(fd);
    return ok;
}
