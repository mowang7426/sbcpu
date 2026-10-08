#ifndef SBCPU_THERMAL_PREFERENCE_UI_H
#define SBCPU_THERMAL_PREFERENCE_UI_H

#import <Foundation/Foundation.h>

// UI-only policy. Import SBCPUThermalPaths.h before this header in controllers.
static inline BOOL SBCPUIsThermalPreference(NSString *key) {
    return [@[@"thermalEngineEnabled", @"powerMode", @"thermalPressureAutoProtectionEnabled",
              @"thermalLockScreenLowPowerEnabled", @"thermalNominalAutoRecoveryEnabled",
              @"thermalPreventDimmingEnabled", @"thermalBlockNotifPopup"] containsObject:key];
}

static inline id SBCPUThermalPreferenceValue(NSDictionary *prefs, NSString *key, id specifierDefault) {
    if (prefs[key]) return prefs[key];
    if (specifierDefault) return specifierDefault;
    if ([key isEqualToString:@"powerMode"]) return @"fullPower";
    if ([key isEqualToString:@"thermalPreventDimmingEnabled"] ||
        [key isEqualToString:@"thermalBlockNotifPopup"]) return @NO;
    return SBCPUIsThermalPreference(key) ? @YES : nil;
}

static inline BOOL SBCPUSaveThermalPreference(NSString *key, id value) {
    NSMutableDictionary *prefs = [SBCPUThermalReadPrefs() mutableCopy] ?: [NSMutableDictionary dictionary];
    prefs[key] = value ?: SBCPUThermalPreferenceValue(nil, key, nil);
    // Never publish a failed write (especially the power-mode state notification).
    if (!SBCPUThermalWritePrefs(prefs)) return NO;
    notify_post("com.yourname.sbcpufloating/settingsChanged");
    notify_post("com.yourname.sbcpufloating.prefschanged");
    if ([key isEqualToString:@"powerMode"]) SBCPUThermalPostPowerMode(prefs[key]);
    return YES;
}

#endif
