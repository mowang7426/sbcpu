#import <Foundation/Foundation.h>
#import "../SBCPUTextOnlyFormat.h"
#include <assert.h>

static NSString *row(SBCPUTextOnlyFields flags) {
    return SBCPUTextOnlyRow(flags, @"12.5%", @"2400 MHz", @"60", @"82%",
        @"35.2°C", @"-480 mA", @[@{@"slot":@1,@"dbm":@"-88",@"carrier":@"Long Carrier"},
                                     @{@"slot":@2,@"dbm":@"-105",@"tech":@"5G"}]);
}
int main(void) {
    @autoreleasepool {
        SBCPUTextOnlyFields flags = {0};
        assert([row(flags) isEqualToString:@""]);
        flags.cpu = YES;
        assert([row(flags) isEqualToString:@"◉12.5%"]);
        flags.cpu = NO; flags.sim2 = YES;
        assert([row(flags) isEqualToString:@"S2-105dBm"]);
        flags.cpu = YES; flags.frequency = YES; flags.fps = YES;
        flags.battery = YES; flags.temperature = YES; flags.current = YES; flags.sim1 = YES;
        NSString *all = row(flags);
        assert([all isEqualToString:@"◉12.5% · 2400MHz · 60fps · ▰82% · 35.2°C · -480mA · S1-88dBm · S2-105dBm"]);
        assert([all rangeOfString:@"\n"].location == NSNotFound);
        for (NSString *bad in @[@"温控核心已运行", @"停充中", @"Long Carrier", @"5G", @"CPU", @"FPS"])
            assert([all rangeOfString:bad].location == NSNotFound);
        NSString *invalid = SBCPUTextOnlyRow(flags, @"NaN%", @"bad MHz", @"inf", nil,
            @"--°C", @"charging mA", @[@{@"slot":@1,@"dbm":@"5G"}]);
        assert([invalid isEqualToString:@"◉--% · --MHz · --fps · ▰--% · --°C · --mA · S1--dBm · S2--dBm"]);
        puts("PASS: selected order, all-off, invalid metrics, dual SIM and status isolation");
    }
    return 0;
}
