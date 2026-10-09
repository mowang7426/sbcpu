// Verifies the production pure-text battery NET-current reader and formatter.
#import <Foundation/Foundation.h>
#import "../SBCPUTextOnlyCurrent.h"
#import "../SBCPUTextOnlyFormat.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    @autoreleasepool {
        assert(SBCPUTextOnlyBatteryCurrent(@{ @"Amperage": @(-387) }).integerValue == -387);
        assert(SBCPUTextOnlyBatteryCurrent(@{ @"Amperage": @(4028) }).integerValue == 4028);
        assert(SBCPUTextOnlyBatteryCurrent(@{ @"Amperage": @(0) }).integerValue == 0);
        assert(SBCPUTextOnlyBatteryCurrent(@{ @"BatteryData": @{ @"InstantAmperage": @(-215) } }).integerValue == -215);
        assert(SBCPUTextOnlyBatteryCurrent(@{ @"Amperage": @YES }) == nil);
        assert(SBCPUTextOnlyBatteryCurrent(@{}) == nil);
        assert(SBCPUTextOnlyBatteryCurrent(@{ @"Amperage": @(11000) }) == nil);
        assert([SBCPUTextOnlyCurrentText(@(-387), 10, 11) isEqual:@"-387mA"]);
        assert([SBCPUTextOnlyCurrentText(@(0), 10, 11) isEqual:@"0mA"]);
        assert([SBCPUTextOnlyCurrentText(nil, 10, 11) isEqual:@"--mA"]);
        assert([SBCPUTextOnlyCurrentText(@(200), 10, 14) isEqual:@"--mA"]);
        SBCPUTextOnlyFields fields = {0}; fields.current = YES;
        assert([SBCPUTextOnlyRow(fields, nil,nil,nil,nil,nil,@"-387mA",nil) isEqual:@"-387mA"]);
        assert([SBCPUTextOnlyRow(fields, nil,nil,nil,nil,nil,@"--mA",nil) isEqual:@"--mA"]);
        puts("PASS: pure-text signed net battery current and missing/stale handling");
    }
    return 0;
}
