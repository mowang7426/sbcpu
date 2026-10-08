#import "../sbcpuprefs/SBCPUThermalDiagnostics.h"
#include <assert.h>
static NSData *bytes(NSString *text) { return [text dataUsingEncoding:NSUTF8StringEncoding]; }
int main(void) {
    @autoreleasepool {
        assert([SBCDParseHeartbeat(bytes(@"1000000\n")) isEqual:@1000000]);
        for (NSString *bad in @[@"", @"0", @"-1", @"+1", @"1.2", @"1x", @"1\n2", @"18446744073709551616", @"☃"])
            assert(!SBCDParseHeartbeat(bytes(bad)));
        assert(!SBCDParseHeartbeat(nil));
        assert(!SBCDParseHeartbeat([NSMutableData dataWithLength:65]));
        assert([SBCDParseHeartbeat(bytes(@"18446744073709551615")) isEqual:@(UINT64_MAX)]);
        assert([SBCDHeartbeatState(nil, 1000) isEqual:@"missing"]);
        assert([SBCDHeartbeatState(@0, 1000) isEqual:@"malformed"]);
        assert([SBCDHeartbeatState(@1000001, 1000) isEqual:@"future"]);
        assert([SBCDHeartbeatState(@985000, 1000) isEqual:@"recent"]);
        assert([SBCDHeartbeatState(@984999, 1000) isEqual:@"stale"]);
        NSDictionary *defaults = @{@"thermalEngineEnabled": @YES, @"thermalPressureAutoProtectionEnabled": @YES,
            @"thermalLockScreenLowPowerEnabled": @YES, @"thermalNominalAutoRecoveryEnabled": @YES,
            @"thermalPreventDimmingEnabled": @NO, @"thermalBlockNotifPopup": @NO};
        for (NSString *key in defaults) {
            NSString *expected = [defaults[key] boolValue] ? @"开启（缺省）" : @"关闭（缺省）";
            assert([SBCDConfigValue(@{}, key, YES) isEqual:expected]);
            assert([SBCDConfigValue(@{key:@NO}, key, YES) isEqual:@"关闭（已保存）"]);
            assert([SBCDConfigValue(@{key:@YES}, key, YES) isEqual:@"开启（已保存）"]);
            assert([SBCDConfigValue(@{key:@"bad"}, key, YES) containsString:@"类型异常"]);
            assert([SBCDConfigValue(@{}, key, NO) containsString:@"不可读"]);
        }
        assert([SBCDConfigValue(@{}, @"powerMode", YES) isEqual:@"满频（缺省）"]);
        assert([SBCDConfigValue(@{@"powerMode":@"lowPower"}, @"powerMode", YES) isEqual:@"低功耗（已保存）"]);
        assert([SBCDConfigValue(@{@"powerMode":@"extremeFull"}, @"powerMode", YES) isEqual:@"极限满频（已保存）"]);
        assert([SBCDConfigValue(@{@"powerMode":@[]}, @"powerMode", YES) containsString:@"类型异常"]);
        assert([SBCDConfigValue(@{@"powerMode":@"secret"}, @"powerMode", YES) isEqual:@"未知（模式值异常）"]);
        assert(SBCDConfigConflict(@{@"thermalEngineEnabled":@NO}, YES, @1));
        assert(!SBCDConfigConflict(@{@"thermalEngineEnabled":@NO}, NO, @1));
        assert(!SBCDConfigConflict(@{@"thermalEngineEnabled":@YES}, YES, @1));
        assert(!SBCDConfigConflict(@{}, YES, @1));
        assert(!SBCDConfigConflict(@{@"thermalEngineEnabled":@NO}, YES, nil));
        puts("PASS: diagnostic reader defaults, malformed/missing/future/stale telemetry and cached mismatch policy (mock data, not device validation)");
    }
    return 0;
}
