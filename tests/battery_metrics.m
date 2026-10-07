#import "../SBCPUBatteryMetrics.h"
#include <stdio.h>
#include <float.h>
#include <stdlib.h>

static NSUInteger SBCPUChecks = 0;
static void SBCPUCheck(BOOL condition, NSString *message) {
    SBCPUChecks++;
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}
static NSMutableDictionary *SBCPURaw(void) {
    return [@{@"ExternalConnected": @YES, @"IsCharging": @YES, @"FullyCharged": @NO,
              @"AppleRawMaxCapacity": @3000, @"AppleRawCurrentCapacity": @1500,
              @"Amperage": @1000} mutableCopy];
}
static NSMutableArray *SBCPUWindow(NSDictionary *raw) {
    NSMutableArray *history = [NSMutableArray array];
    for (NSUInteger i = 0; i <= 6; i++)
        SBCPUBatteryAppendSample(history, SBCPUBatterySnapshot(raw, 100.0 + 5.0 * i));
    return history;
}
static NSString *SBCPUText(NSDictionary *raw, NSArray *history) {
    return SBCPUBatteryETAText(SBCPUBatterySnapshot(raw, 130.0), history, 130.0);
}
static void SBCPUTestManufacturer(void) {
    SBCPUCheck([SBCPUBatteryManufacturer(nil) isEqual:@"厂商未知"], @"missing manufacturer");
    NSArray *bad = @[@42, @YES, [NSNull null], @[], @{}, @"", @"  ", @"unknown", @"(null)",
                    @"N/A", @"0", @"Apple\nSMP", @"Apple\u202e"];
    for (id value in bad)
        SBCPUCheck([SBCPUBatteryManufacturer(value) isEqual:@"厂商未知"], @"invalid manufacturer type/text");
    const unichar embeddedName[] = {'A', 'p', 'p', 'l', 'e', 0, 'S', 'M', 'P'};
    NSString *nameWithNUL = [NSString stringWithCharacters:embeddedName length:sizeof(embeddedName) / sizeof(embeddedName[0])];
    SBCPUCheck([SBCPUBatteryManufacturer(nameWithNUL) isEqual:@"厂商未知"], @"embedded NUL in NSString rejected");
    SBCPUCheck([SBCPUBatteryManufacturer(@"  apple Inc.  ") isEqual:@"Apple"], @"explicit Apple alias");
    for (NSString *vendor in @[@"SMP", @"DSY", @"ATL", @"Sunwoda", @"德赛电池", @"Apple supplier"])
        SBCPUCheck([SBCPUBatteryManufacturer(vendor) isEqual:vendor], @"supplier not mapped to consumer brand");
    const UInt8 padded[] = {'S', 'M', 'P', 0, 0};
    CFDataRef data = CFDataCreate(kCFAllocatorDefault, padded, sizeof(padded));
    id bridged = CFBridgingRelease(data);
    SBCPUCheck([SBCPUBatteryManufacturer(bridged) isEqual:@"SMP"], @"CFData padded ASCII");
    const unsigned char binary[] = {0xff, 0xfe, 0x41, 0x00};
    SBCPUCheck([SBCPUBatteryManufacturer([NSData dataWithBytes:binary length:sizeof(binary)])
                isEqual:@"厂商未知"], @"malformed/non-UTF8 CFData");
    const unsigned char embedded[] = {'A', 0, 'B'};
    SBCPUCheck([SBCPUBatteryManufacturer([NSData dataWithBytes:embedded length:sizeof(embedded)])
                isEqual:@"厂商未知"], @"embedded NUL rejected");
    SBCPUCheck([SBCPUBatteryManufacturer([NSMutableData dataWithLength:300]) isEqual:@"厂商未知"], @"oversize CFData");
    SBCPUCheck([SBCPUBatteryManufacturer([@"A" stringByPaddingToLength:200 withString:@"A" startingAtIndex:0])
                isEqual:@"厂商未知"], @"oversize string");
    SBCPUCheck([SBCPUBatteryManufacturerFromProperties(@{@"Serial": @"APPLE-SMP-123", @"Manufacturer": @123})
                isEqual:@"厂商未知"], @"serial never used for brand");
    SBCPUCheck([SBCPUBatteryManufacturerFromProperties(@{@"BatteryData": @{@"Manufacturer": @"ATL"}})
                isEqual:@"ATL"], @"explicit nested manufacturer");
    SBCPUCheck([SBCPUBatteryManufacturerFromProperties(@{@"Manufacturer": @"Apple", @"BatteryData": @{@"Manufacturer": @"ATL"}})
                isEqual:@"ATL"], @"battery-pack maker takes priority over generic device maker");
    SBCPUCheck([SBCPUBatteryManufacturerFromProperties(@{@"BatteryData": @{@"ManufacturerName": @"SMP"}})
                isEqual:@"SMP"], @"explicit manufacturer name alias field");
    SBCPUCheck([SBCPUBatteryManufacturerFromProperties(@{@"BatteryData": [NSNull null]})
                isEqual:@"厂商未知"], @"malformed nested dictionary");
}
static void SBCPUTestSnapshot(void) {
    NSDictionary *s = SBCPUBatterySnapshot(SBCPURaw(), 100.0);
    SBCPUCheck([s[@"RemainingMAh"] doubleValue] == 1500.0, @"raw mAh subtraction");
    SBCPUCheck([s[@"SOC"] doubleValue] == 0.5, @"raw SOC");
    SBCPUCheck([s[@"Manufacturer"] isEqual:@"厂商未知"], @"snapshot never defaults Apple");
    s = SBCPUBatterySnapshot(@{@"NominalChargeCapacity": @3000, @"MaxCapacity": @100,
                               @"CurrentCapacity": @50}, 100.0);
    SBCPUCheck([s[@"RemainingMAh"] doubleValue] == 1500.0, @"percentage/mAh unit separation");
    s = SBCPUBatterySnapshot(@{@"NominalChargeCapacity": @3200, @"MaxCapacity": @3000,
                               @"CurrentCapacity": @0}, 100.0);
    SBCPUCheck([s[@"RemainingMAh"] doubleValue] == 3000.0, @"native mAh pair incl zero uses own maximum");
    s = SBCPUBatterySnapshot(@{@"DesignCapacity": @3000, @"CurrentCapacity": @50}, 100.0);
    SBCPUCheck(!s[@"RemainingMAh"], @"design capacity not invented as full capacity");
    s = SBCPUBatterySnapshot(@{@"AppleRawMaxCapacity": @3000, @"CurrentCapacity": @50}, 100.0);
    SBCPUCheck(!s[@"RemainingMAh"], @"ambiguous current units not guessed");
    s = SBCPUBatterySnapshot(@{@"AppleRawMaxCapacity": @3000, @"AppleRawCurrentCapacity": @4000}, 100.0);
    SBCPUCheck(!s[@"RemainingMAh"], @"current greater than full is invalid");
    s = SBCPUBatterySnapshot(@{@"Amperage": @(-1000)}, 100.0);
    SBCPUCheck([s[@"CurrentMA"] doubleValue] == -1000.0, @"net discharge never becomes charging via fabs");
    s = SBCPUBatterySnapshot(@{@"Amperage": @(INFINITY), @"InstantAmperage": @1200}, 100.0);
    SBCPUCheck([s[@"CurrentMA"] doubleValue] == 1200.0, @"valid signed alternate current");
    for (id bad in @[[NSNull null], @[], @"invalid", @{@"BatteryData": @[], @"AdapterDetails": @0}]) {
        s = SBCPUBatterySnapshot(bad, 100.0);
        SBCPUCheck(SBCPUBatteryFlag(s[@"ExternalConnected"]) == -1, @"missing != disconnected");
        SBCPUCheck(!s[@"RemainingMAh"], @"malformed properties safe");
    }
    SBCPUCheck(SBCPUBatteryFlag(@2) == -1 && SBCPUBatteryFlag(@"YES") == -1, @"strict tri-state flags");
    SBCPUCheck(!SBCPUBatteryNumber(@YES) && !SBCPUBatteryNumber(@(NAN)), @"boolean/nonfinite not numeric metrics");
}
static void SBCPUTestStatesAndSystem(void) {
    NSMutableDictionary *raw = SBCPURaw();
    raw[@"AvgTimeToFull"] = @47;
    SBCPUCheck([SBCPUText(raw, @[]) isEqual:@"约50分钟（系统）"], @"valid system estimate coarsely rounded");
    raw[@"AvgTimeToFull"] = @900;
    SBCPUCheck([SBCPUText(raw, @[]) isEqual:@"约900分钟（系统）"], @"valid slow system estimate not rejected at 600");
    raw[@"AvgTimeToFull"] = @2.5; raw[@"TimeToFull"] = @40;
    SBCPUCheck([SBCPUText(raw, @[]) isEqual:@"约40分钟（系统）"], @"malformed first key uses explicit full-time alternate");
    [raw removeObjectForKey:@"TimeToFull"];
    for (id bad in @[@0, @(-1), @65535, @4294967295ULL, @(DBL_MAX), @(NAN), @"45", @YES, [NSNull null], @[]]) {
        raw[@"AvgTimeToFull"] = bad;
        NSString *text = SBCPUText(raw, @[]);
        SBCPUCheck(![text containsString:@"系统"] && ![text containsString:@"计算中"], @"sentinel/type rejected with finite explicit state");
    }
    raw[@"AvgTimeToFull"] = @50;
    raw[@"ExternalConnected"] = @NO;
    SBCPUCheck([SBCPUText(raw, @[]) isEqual:@"未连接电源"], @"disconnect ignores stale system ETA");
    raw[@"SBCPUChargeBlocked"] = @YES;
    SBCPUCheck([SBCPUText(raw, @[]) isEqual:@"已阻止充电"], @"actual CH0I block can mask external power");
    [raw removeObjectForKey:@"SBCPUChargeBlocked"]; raw[@"ExternalConnected"] = @YES;
    raw[@"FullyCharged"] = @YES;
    SBCPUCheck([SBCPUText(raw, @[]) isEqual:@"已充满"], @"full beats system ETA");
    raw[@"FullyCharged"] = @NO; raw[@"SBCPUChargePaused"] = @YES; raw[@"IsCharging"] = @NO;
    SBCPUCheck([SBCPUText(raw, @[]) isEqual:@"充电已暂停"], @"known pause beats inactive charging");
    [raw removeObjectForKey:@"SBCPUChargePaused"];
    SBCPUCheck([SBCPUText(raw, @[]) isEqual:@"已接电，未在充电"], @"inactive charging does not guess pause cause");
    [raw removeObjectForKey:@"IsCharging"];
    SBCPUCheck([SBCPUText(raw, @[]) isEqual:@"充电状态未知"], @"absent charging flag not guessed from system ETA");
    [raw removeObjectForKey:@"ExternalConnected"];
    SBCPUCheck([SBCPUText(raw, @[]) isEqual:@"电源连接状态未知"], @"absent external flag explicit");
    raw = SBCPURaw(); raw[@"Amperage"] = @(-500); raw[@"AvgTimeToFull"] = @50;
    SBCPUCheck([SBCPUText(raw, @[]) isEqual:@"未净充入，暂无法估算"], @"negative net current invalidates misleading ETA");
    raw[@"Amperage"] = @50; [raw removeObjectForKey:@"AvgTimeToFull"];
    SBCPUCheck([SBCPUText(raw, @[]) containsString:@"过低"], @"low current not extrapolated");
    raw = SBCPURaw(); raw[@"AppleRawCurrentCapacity"] = @3000;
    SBCPUCheck([SBCPUText(raw, @[]) isEqual:@"电量已满，等待充电完成"], @"100 percent not proof of FullyCharged");
    SBCPUCheck([SBCPUBatteryETAText(SBCPUBatterySnapshot(raw, 100.0), @[], 116.0)
                isEqual:@"暂无实时充电数据"], @"stale cached snapshot expires");
    SBCPUCheck([SBCPUBatteryETAText(SBCPUBatterySnapshot(raw, 100.0), @[], 99.0)
                isEqual:@"暂无实时充电数据"], @"future/backward clock rejected");
    SBCPUCheck([SBCPUBatteryETAText(nil, @[], 100.0) isEqual:@"暂无实时充电数据"], @"nil snapshot explicit");
}
static void SBCPUTestSustainedFallback(void) {
    NSMutableDictionary *raw = SBCPURaw();
    NSMutableArray *history = SBCPUWindow(raw);
    NSDictionary *s = SBCPUBatterySnapshot(raw, 130.0);
    SBCPUCheck(history.count == 7 && SBCPUBatterySustainedCurrent(history, s) == 1000.0, @"30s positive window sufficient");
    SBCPUCheck([SBCPUText(raw, history) isEqual:@"约90–225分钟（估算）"], @"mAh/current plus future taper range");
    SBCPUCheck(SBCPUBatteryTaperWeightedRemaining(3000, 0.5) > 1500.0, @"future taper adds time");
    SBCPUCheck(fabs(SBCPUBatteryTaperWeightedRemaining(3000, 0.95) - 150.0) < 0.00001, @"observed final stage not double tapered");
    raw[@"AvgTimeToFull"] = @35;
    SBCPUCheck([SBCPUText(raw, history) isEqual:@"约35分钟（系统）"], @"system beats heuristic fallback");
    [raw removeObjectForKey:@"AvgTimeToFull"];
    [history removeLastObject];
    SBCPUCheck(![SBCPUText(raw, history) containsString:@"（估算）"], @"25s insufficient despite positive instant current");
    history = [NSMutableArray array];
    for (NSUInteger i = 0; i < 100; i++) SBCPUBatteryAppendSample(history, s);
    SBCPUCheck(history.count == 1, @"repeated cached timestamp cannot manufacture confidence");
    history = SBCPUWindow(raw); raw[@"Amperage"] = @(-1000);
    SBCPUBatteryAppendSample(history, SBCPUBatterySnapshot(raw, 135.0));
    SBCPUCheck(history.count == 0, @"discharge breaks positive window");
    raw = SBCPURaw(); history = SBCPUWindow(raw); raw[@"ExternalConnected"] = @NO;
    SBCPUBatteryAppendSample(history, SBCPUBatterySnapshot(raw, 135.0)); raw[@"ExternalConnected"] = @YES;
    SBCPUBatteryAppendSample(history, SBCPUBatterySnapshot(raw, 140.0));
    SBCPUCheck(history.count == 1, @"unplug/replug resets session");
    history = SBCPUWindow(raw); raw[@"SBCPUChargePaused"] = @YES;
    SBCPUBatteryAppendSample(history, SBCPUBatterySnapshot(raw, 135.0));
    SBCPUCheck(history.count == 0, @"pause clears historical current");
    [raw removeObjectForKey:@"SBCPUChargePaused"]; history = SBCPUWindow(raw);
    SBCPUBatteryAppendSample(history, SBCPUBatterySnapshot(raw, 160.0));
    SBCPUCheck(history.count == 1, @"suspend/long gap resets window");
    history = SBCPUWindow(raw); raw[@"AdapterDetails"] = @{@"SerialString": @"new-adapter"};
    SBCPUBatteryAppendSample(history, SBCPUBatterySnapshot(raw, 135.0));
    SBCPUCheck(history.count == 1, @"adapter replacement resets window");
    SBCPUBatteryAppendSample(history, SBCPUBatterySnapshot(raw, 120.0));
    SBCPUCheck(history.count == 1, @"monotonic clock rollback resets window");
}
static void SBCPUTestBoundsAndNoise(void) {
    NSMutableDictionary *raw = SBCPURaw();
    NSMutableArray *history = [NSMutableArray array];
    for (NSUInteger i = 0; i <= 200; i++)
        SBCPUBatteryAppendSample(history, SBCPUBatterySnapshot(raw, 100.0 + i));
    SBCPUCheck(history.count == 64, @"bounded memory at high sampling cadence");
    history = [NSMutableArray array];
    for (NSUInteger i = 0; i <= 50; i++)
        SBCPUBatteryAppendSample(history, SBCPUBatterySnapshot(raw, 100.0 + 5.0 * i));
    SBCPUCheck(history.count == 25, @"bounded 120s history");
    history = [NSMutableArray array];
    for (NSUInteger i = 0; i <= 6; i++) {
        raw[@"Amperage"] = i % 2 == 0 ? @1000 : @300;
        SBCPUBatteryAppendSample(history, SBCPUBatterySnapshot(raw, 100.0 + 5.0 * i));
    }
    SBCPUCheck(![SBCPUText(raw, history) containsString:@"（估算）"], @"unstable current not a precise ETA");
    raw = SBCPURaw(); history = SBCPUWindow(raw); raw[@"Amperage"] = @300;
    SBCPUCheck(![SBCPUText(raw, history) containsString:@"（估算）"], @"sudden drop not concealed by previous average");
    raw = SBCPURaw(); raw[@"AppleRawMaxCapacity"] = @20000; raw[@"AppleRawCurrentCapacity"] = @0; raw[@"Amperage"] = @100;
    history = SBCPUWindow(raw);
    SBCPUCheck([SBCPUText(raw, history) isEqual:@"充电缓慢，暂无法可靠估算"], @"absurd long fallback not capped as a deadline");
    raw = SBCPURaw(); [raw removeObjectForKey:@"AppleRawMaxCapacity"];
    SBCPUCheck([SBCPUText(raw, SBCPUWindow(raw)) containsString:@"容量数据不足"], @"missing real capacity cannot use device spec");
    raw = SBCPURaw(); [raw removeObjectForKey:@"Amperage"];
    SBCPUCheck([SBCPUText(raw, @[]) containsString:@"电流未知"], @"no invented 150mA current");
    raw[@"AvgTimeToFull"] = @30;
    SBCPUCheck([SBCPUText(raw, @[]) isEqual:@"约30分钟（系统）"], @"valid system ETA does not require synthetic current");
    raw = SBCPURaw(); raw[@"Amperage"] = @18446744073709551615ULL;
    SBCPUCheck(![SBCPUText(raw, @[]) containsString:@"（估算）"], @"wrapped unsigned current not absolute-valued");
}
int main(void) {
    @autoreleasepool {
        SBCPUTestManufacturer();
        SBCPUTestSnapshot();
        SBCPUTestStatesAndSystem();
        SBCPUTestSustainedFallback();
        SBCPUTestBoundsAndNoise();
        printf("PASS: %lu battery metrics checks\n", (unsigned long)SBCPUChecks);
    }
    return 0;
}
