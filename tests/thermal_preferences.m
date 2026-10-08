// Exercise the actual UI policy with an isolated store and notification spies.
#import <Foundation/Foundation.h>
#include <assert.h>
#include <string.h>
static NSDictionary *store;
static NSMutableArray *events;
static BOOL writeOK;
static NSDictionary *SBCPUThermalReadPrefs(void) { return store; }
static BOOL SBCPUThermalWritePrefs(NSDictionary *prefs) {
    [events addObject:@"write"];
    if (!writeOK) return NO;
    store = [prefs copy];
    return YES;
}
static int notify_post(const char *name) {
    [events addObject:[NSString stringWithUTF8String:name]];
    return 0;
}
static int SBCPUThermalPostPowerMode(NSString *mode) {
    assert([store[@"powerMode"] isEqual:mode]);
    [events addObject:[@"mode:" stringByAppendingString:mode]];
    return 0;
}
#import "../sbcpuprefs/SBCPUThermalPreferenceUI.h"
int main(void) {
    @autoreleasepool {
        NSDictionary *defaults = @{@"thermalEngineEnabled": @YES,
            @"thermalPressureAutoProtectionEnabled": @YES, @"thermalLockScreenLowPowerEnabled": @YES,
            @"thermalNominalAutoRecoveryEnabled": @YES, @"thermalPreventDimmingEnabled": @NO,
            @"thermalBlockNotifPopup": @NO, @"powerMode": @"fullPower"};
        for (NSString *key in defaults) {
            assert(SBCPUIsThermalPreference(key));
            assert([SBCPUThermalPreferenceValue(nil, key, nil) isEqual:defaults[key]]);
            assert([SBCPUThermalPreferenceValue(@{}, key, nil) isEqual:defaults[key]]);
            assert([SBCPUThermalPreferenceValue(@{}, key, @"specifier") isEqual:@"specifier"]);
            assert([SBCPUThermalPreferenceValue(@{key: @NO}, key, @YES) isEqual:@NO]);
            assert([SBCPUThermalPreferenceValue(@{key: @YES}, key, @NO) isEqual:@YES]);
        }
        assert(!SBCPUIsThermalPreference(@"other"));
        assert(!SBCPUThermalPreferenceValue(nil, @"other", nil));
        events = [NSMutableArray array];
        for (NSString *key in defaults) {
            store = @{@"unrelated": @42, @"powerMode": @"fullPower", @"thermalBlockNotifPopup": @NO};
            NSDictionary *before = store;
            id value = [key isEqual:@"powerMode"] ? @"lowPower" : @YES;
            writeOK = NO;
            [events removeAllObjects];
            assert(!SBCPUSaveThermalPreference(key, value));
            assert([store isEqual:before]);
            assert(([events isEqual:@[@"write"]]));
            // A reload after failure still reads the persisted value / missing-key default.
            assert([SBCPUThermalPreferenceValue(store, key, nil) isEqual:before[key] ?: defaults[key]]);
            writeOK = YES;
            [events removeAllObjects];
            assert(SBCPUSaveThermalPreference(key, value));
            assert([store[key] isEqual:value] && [store[@"unrelated"] isEqual:@42]);
            NSArray *expected = @[@"write", @"com.yourname.sbcpufloating/settingsChanged",
                                  @"com.yourname.sbcpufloating.prefschanged"];
            if ([key isEqual:@"powerMode"]) expected = [expected arrayByAddingObject:@"mode:lowPower"];
            assert([events isEqual:expected]);
        }
        store = nil;
        assert(SBCPUSaveThermalPreference(@"powerMode", nil));
        assert([store[@"powerMode"] isEqual:@"fullPower"]);
        assert(SBCPUSaveThermalPreference(@"thermalBlockNotifPopup", nil));
        assert([store[@"thermalBlockNotifPopup"] isEqual:@NO]);
        puts("PASS: actual thermal UI defaults, missing keys, write failure and notification ordering (stubbed store; not device validation)");
    }
    return 0;
}
