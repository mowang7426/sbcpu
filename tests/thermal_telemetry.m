// Compiles the production core recorder with read-only runtime mocks on macOS.
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <objc/runtime.h>
#import <os/lock.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <dlfcn.h>
#include <string.h>
static os_unfair_lock g_stateLock = OS_UNFAIR_LOCK_INIT;
static os_unfair_lock g_modeLock = OS_UNFAIR_LOCK_INIT;
static BOOL g_enabled = YES, g_cpuProtection = YES, g_blockNetworkThermalThrottle = YES;
static BOOL g_thermalBlockNotifPopup, g_thermalPreventDimmingEnabled;
static BOOL g_thermalPressureAutoProtectionEnabled = YES, g_thermalNominalAutoRecoveryEnabled = YES;
static BOOL g_lockScreenLowPowerEnabled = YES, g_pressureSafetyOverride;
static int g_userSelectedPowerMode, g_powerMode, g_currentPressureLevel;
static double g_pressureNominalSince;
static BOOL bootSettled(void) { return YES; }
static BOOL SBCPUThermalScreenIsLocked(void) { return NO; }
static BOOL SBCPUThermalScreenIsBlanked(void) { return NO; }
// Never create files in the test; production TWrite still computes its bounded ring.
static NSString *SBCPUThermalTelemetryPath(void) {
    return @"/sbcpu-test-nonexistent-directory/snapshot.plist";
}
#import "../SBCPUThermalTelemetry.h"
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); return 1; } } while (0)
int main(void) {
    @autoreleasepool {
        NSDictionary *absent = THook(@"SBCPUTestMissingClass", @"notPresent", TDecision);
        CHECK(![absent[@"methodPresent"] boolValue]);
        CHECK(![absent[@"implementationInCore"] boolValue]);
        CHECK(![absent[@"called"] boolValue]);
        CHECK([absent[@"result"] containsString:@"非失败"]);
        NSDictionary *supported = THook(@"NSObject", @"description", TDecision);
        CHECK([supported[@"methodPresent"] boolValue]);
        CHECK(![supported[@"implementationInCore"] boolValue]);
        TNote(TDecision, 0); TSet(TDecision, 2);
        NSDictionary *called = THook(@"NSObject", @"description", TDecision);
        CHECK([called[@"called"] boolValue] && [called[@"callCount"] unsignedLongLongValue] == 1);
        CHECK([called[@"lastCalledMono"] doubleValue] > 0);
        CHECK([called[@"result"] containsString:@"放行"]);
        CHECK(![called[@"implementationInCore"] boolValue]); // called does not fabricate installation
        CHECK([TResult(TPressure, 3, 1) containsString:@"未主动接管"]);
        CHECK([TResult(TPressure, 4, 1) containsString:@"守卫"]);
        CHECK([TResult(TPressure, 5, 1) containsString:@"读取失败"]);
        CHECK([TResult(TApply, 2, 1) containsString:@"全功率"]);
        CHECK([TResult(TDecision, 1, 1) containsString:@"效果未知"]);
        TConfig(@{@"powerMode":@"lowPower", @"thermalBlockNotifPopup":@YES});
        dispatch_sync(TGetQueue(), ^{});
        CHECK(TRevision == 1 && [TLoaded[@"powerMode"] isEqual:@"lowPower"]);
        CHECK(TLastLoadSucceeded && TLastSuccessWall > 0);
        double successWall = TLastSuccessWall;
        TFailedConfig(nil); dispatch_sync(TGetQueue(), ^{});
        CHECK(TRevision == 1 && [TLoaded[@"powerMode"] isEqual:@"lowPower"]);
        CHECK(!TLastLoadSucceeded && TLastSuccessWall == successWall);
        CHECK([TLoadStatus containsString:@"失败"]);
        g_powerMode = 1; g_userSelectedPowerMode = 2; g_pressureSafetyOverride = YES;
        NSDictionary *runtime = TRuntime();
        CHECK([runtime[@"effectiveMode"] isEqual:@"lowPower"]);
        CHECK([runtime[@"selectedMode"] isEqual:@"extremeFull"]);
        CHECK([runtime[@"pressureOverride"] boolValue]);
        CHECK([runtime[@"reason"] containsString:@"覆盖"]);
        uint64_t generation = atomic_load(&TGeneration);
        // Frequent calls aggregate once per write; bounded ring survives >80 events.
        for (int i = 0; i < 110; i++) {
            TNote(TPressure, 4); TSet(TPressure, 1);
            if (i == 0) { TNote(TPressure, 4); TSet(TPressure, 1); }
            TWrite(runtime, @[], NSDate.date.timeIntervalSince1970, SBCTMono());
            CHECK(TEvents.count <= 80);
            if (i == 0) CHECK([TEvents.firstObject[@"coalesced"] unsignedLongLongValue] == 2);
        }
        CHECK(TEvents.count == 80);
        CHECK(atomic_load(&TCounts[TPressure]) == 111);
        CHECK(TSeen[TPressure] == 111);
        CHECK([TEvents.lastObject[@"count"] unsignedLongLongValue] == 111);
        CHECK([TEvents.lastObject[@"result"] containsString:@"严重"]);
        CHECK(atomic_load(&TPending)); // one coalesced task, not a per-call task backlog
        CHECK(atomic_load(&TGeneration) > generation);
        CHECK(!TLoaded[@"unrecognized"]);
        puts("PASS: production core recorder: support vs install vs called, actual runtime modes, failed load retention, branch meanings, coalescing and <=80 events");
    }
    return 0;
}
