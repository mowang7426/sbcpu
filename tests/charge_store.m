#import "../SBCPUChargeStore.h"
#include <assert.h>
int main(void) {
 @autoreleasepool {
  NSDictionary *legacy = @{@"smartChargeEnable": @YES, @"smartChargeUpperLimit": @80, @"smartChargeLowerLimit": @70, @"unrelated": @1};
  assert([legacy writeToFile:@SBCPU_CHARGE_LEGACY atomically:YES]);
  assert([SBChargeRead()[@"smartChargeEnable"] boolValue]);
  assert(SBChargePatch(@{@"smartChargeUpperLimit": @55}));
  assert([SBChargeRead()[@"smartChargeLowerLimit"] intValue] == 54);
  assert(SBChargePatch(@{@"smartChargeLowerLimit": @50}));
  // Simulate cfprefsd / stale SpringBoard rewriting the old domain.
  NSDictionary *stale = @{@"smartChargeEnable": @NO, @"smartChargeUpperLimit": @80};
  assert([stale writeToFile:@SBCPU_CHARGE_LEGACY atomically:YES]);
  assert([SBChargeRead()[@"smartChargeEnable"] boolValue]);
  assert([SBChargeRead()[@"smartChargeUpperLimit"] intValue] == 55);
  assert([SBChargeRead()[@"smartChargeLowerLimit"] intValue] == 50);
  assert(SBChargePatch(@{@"blockPowerEnable": @YES}));
  assert(SBChargePatch(@{@"chargeScheduleEnabled": @YES}));
  assert(SBChargePatch(@{@"blockPowerEnable": @NO}));
  assert([SBChargeRead()[@"smartChargeEnable"] boolValue]);
  assert([SBChargeRead()[@"smartChargeUpperLimit"] intValue] == 55);
  assert([SBChargeRead()[@"chargeScheduleEnabled"] boolValue]);
  assert(!SBChargeRead()[@"unrelated"]);
  assert(SBChargePatch(@{@"chargeDayStartHour": @8, @"chargeDayStartMinute": @0,
                         @"chargeNightStartHour": @22, @"chargeNightStartMinute": @0}));
  assert(!SBChargePatch(@{@"chargeDayStartHour": @22, @"chargeDayStartMinute": @0}));
  assert([SBChargeRead()[@"chargeDayStartHour"] intValue] == 8);
  assert(SBChargePatch(@{@"chargeDayNightAutoEnable": @YES}));
  assert([SBChargeRead()[@"chargeDayNightAutoEnable"] boolValue]);
  NSLog(@"PASS: native charge store migration, stale overwrite isolation and per-key merge");
 }
 return 0;
}
