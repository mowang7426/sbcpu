// SBCPUChargeEngine.m — 充电状态机实现
// 优先级（Battman 方案）：
//   1. 安全状态（未插电 / SMC 不可用 / 无线充电不支持）→ 不写
//   2. 手动阻止充电（manualChargeBlock）→ CH0C = inhibit
//   3. 手动阻止外部供电（manualPowerBlock）→ CH0I = inhibit
//   4. 智能充电限制（smartChargeEnabled + 上限/下限）→ 迟滞控制
//   5. 正常充电
// 迟滞：pct >= upper → 停充；pct <= lower → 恢复；中间保持当前状态。
// 写缓存由 SMC 层负责（状态不变不写）。

#import <Foundation/Foundation.h>
#import <notify.h>
#import <unistd.h>
#include <stdarg.h>
#include "SBCPUChargeEngine.h"
#include "SBCPUChargeSMC.h"
#include "SBCPUChargePowerSource.h"
#include "SBCPUChargeProtocol.h"

static SBCPUChargeConfig gCfg = {0};
static SBCPUChargeState gState = SBCPUChargeStateUnknown;
static int gBatteryPercent = -1;
static bool gWireless = false;
static bool gSmcAvailable = false;
static bool gOBC = false;
static bool gManualChargeBlock = false;  // 手动状态持久于内存（daemon 生命周期）
static bool gManualPowerBlock = false;

// 日志（仅状态变化/错误时写，避免刷屏）
static void engine_log(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[SBCPUChargeEngine] %@", msg);
    @try {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:@SB_DAEMON_LOG_PATH];
        if (!fh) {
            [[NSFileManager defaultManager] createFileAtPath:@SB_DAEMON_LOG_PATH contents:nil attributes:nil];
            fh = [NSFileHandle fileHandleForWritingAtPath:@SB_DAEMON_LOG_PATH];
        }
        if (fh) {
            NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], msg];
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    } @catch (NSException *e) {}
}

// 从偏好 plist 读取（daemon root 直接读文件；mobile 域 root 读 CFPreferences 会串域）
static bool pref_bool(NSDictionary *d, NSString *key, bool def) {
    id v = d[key];
    if ([v isKindOfClass:[NSNumber class]])
        return [v boolValue];
    if ([v isKindOfClass:[NSString class]])
        return [[v lowercaseString] isEqualToString:@"true"] || [v integerValue] != 0;
    return def;
}

static long pref_int(NSDictionary *d, NSString *key, long def) {
    id v = d[key];
    if ([v isKindOfClass:[NSNumber class]]) return [v longValue];
    if ([v isKindOfClass:[NSString class]]) return [v longLongValue];
    return def;
}

bool sb_engine_load_config(SBCPUChargeConfig *cfg) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:@SB_PREF_FILE];
    if (!d) return false;

    SBCPUChargeConfig c = {0};
    c.smartChargeEnabled = pref_bool(d, @"smartChargeEnable", false);
    c.chargeLimitEnabled = pref_bool(d, @"chargeLimitEnabled", c.smartChargeEnabled);
    c.upperLimit = (uint8_t)pref_int(d, @"smartChargeUpperLimit", 80);
    c.lowerLimit = (uint8_t)pref_int(d, @"smartChargeLowerLimit", 70);
    c.keepAC = pref_bool(d, @"chargeKeepAC", true);
    c.overrideOBC = pref_bool(d, @"chargeOverrideOBC", false);
    c.manualChargeBlock = pref_bool(d, @"blockChargingEnable", false);
    c.manualPowerBlock = pref_bool(d, @"blockPowerEnable", false);
    c.scheduleEnabled = pref_bool(d, @"chargeScheduleEnabled", false);

    // 防御：上下限有效性
    if (c.upperLimit > 100) c.upperLimit = 100;
    if (c.lowerLimit > 99) c.lowerLimit = 99;
    if (c.upperLimit <= c.lowerLimit) { c.upperLimit = 80; c.lowerLimit = 70; }

    if (cfg) *cfg = c;
    return true;
}

void sb_engine_init(void) {
    IOReturn oret = smc_open();
    gSmcAvailable = (oret == kIOReturnSuccess);
    if (!gSmcAvailable) {
        engine_log(@"AppleSMC open failed: 0x%08x (uid=%d); engine disabled", (unsigned)oret, (int)getuid());
        gState = SBCPUChargeStateError;
        return;
    }
    engine_log(@"AppleSMC opened OK (uid=%d)", (int)getuid());
    if (!sb_engine_load_config(&gCfg)) {
        engine_log(@"No preferences yet; engine idle");
        gState = SBCPUChargeStateUnknown;
        return;
    }
    // 启动立即决策一次（不等下一次电池事件）
    sb_engine_redecide();
}

void sb_engine_shutdown(void) {
    // 恢复充电并停止（卸载/停用场景）
    if (gSmcAvailable) {
        (void)smc_set_charge_block(false, true);
        (void)smc_set_power_block(false, true);
    }
    smc_close();
    gState = SBCPUChargeStateUnknown;
}

// 按需确保 SMC 已打开：启动时若临时失败，后续命令/事件到来时自动重连（自愈）
static bool engine_ensure_smc(void) {
    if (gSmcAvailable && smc_is_open()) return true;
    IOReturn r = smc_open();
    if (r == kIOReturnSuccess) {
        gSmcAvailable = true;
        engine_log(@"AppleSMC (re)opened OK (uid=%d)", (int)getuid());
        return true;
    }
    gSmcAvailable = false;
    return false;
}

int sb_engine_manual_charge_block(bool block) {
    gManualChargeBlock = block;
    if (!engine_ensure_smc()) return SB_RESULT_SMC_UNAVAILABLE;
    int r = smc_set_charge_block(block, gCfg.overrideOBC);
    if (r == SB_RESULT_OK) {
        gCfg.manualChargeBlock = block;
        // 同步回偏好，UI 重启后仍生效
        NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:@SB_PREF_FILE];
        if (d) {
            d[@"blockChargingEnable"] = @(block);
            [d writeToFile:@SB_PREF_FILE atomically:YES];
        }
        gState = block ? SBCPUChargeStateBlocked : SBCPUChargeStateCharging;
        engine_log(@"manual charge block -> %d (0x%x)", block, r);
    }
    return r;
}

int sb_engine_manual_power_block(bool block) {
    gManualPowerBlock = block;
    if (!engine_ensure_smc()) return SB_RESULT_SMC_UNAVAILABLE;
    int r = smc_set_power_block(block, gCfg.overrideOBC);
    if (r == SB_RESULT_OK) {
        gCfg.manualPowerBlock = block;
        NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:@SB_PREF_FILE];
        if (d) {
            d[@"blockPowerEnable"] = @(block);
            [d writeToFile:@SB_PREF_FILE atomically:YES];
        }
        gState = block ? SBCPUChargeStateBlocked : SBCPUChargeStateCharging;
        engine_log(@"manual power block -> %d (0x%x)", block, r);
    }
    return r;
}

// 核心决策
void sb_engine_decide(int pct, bool charging, bool wireless) {
    if (pct >= 0) gBatteryPercent = pct;
    gWireless = wireless;
    if (!engine_ensure_smc()) {
        gState = SBCPUChargeStateError;
        return;
    }

    // 优先级 1：安全状态
    if (!charging || !smc_external_connected()) {
        if (gState != SBCPUChargeStateNoPower) {
            gState = SBCPUChargeStateNoPower;
            engine_log(@"no external power; idle (pct=%d)", pct);
        }
        return;
    }

    // 重读配置（每次决策都读，保证 UI 改动即时生效）
    SBCPUChargeConfig newCfg = gCfg;
    (void)sb_engine_load_config(&newCfg);
    bool cfgChanged = memcmp(&newCfg, &gCfg, sizeof(SBCPUChargeConfig)) != 0;
    if (cfgChanged) {
        gCfg = newCfg;
        engine_log(@"config updated: smart=%d upper=%d lower=%d keepAC=%d obc=%d",
            gCfg.smartChargeEnabled, gCfg.upperLimit, gCfg.lowerLimit, gCfg.keepAC, gCfg.overrideOBC);
    }

    // 无线充电：底层不可靠控制 → 不假装成功
    if (wireless && gCfg.smartChargeEnabled) {
        if (gState != SBCPUChargeStateUnsupported) {
            gState = SBCPUChargeStateUnsupported;
            engine_log(@"wireless charging detected; limit unsupported");
        }
        return;
    }

    // 优先级 2：手动阻止充电
    if (gManualChargeBlock || gCfg.manualChargeBlock) {
        gOBC = smc_obc_taken_charge();
        int r = smc_set_charge_block(true, gCfg.overrideOBC);
        if (r == SB_RESULT_OK) gState = SBCPUChargeStateBlocked;
        else if (r == SB_RESULT_OBC_TAKEN) gState = SBCPUChargeStateOBCControlled;
        return;
    }
    // 手动阻止外部供电
    if (gManualPowerBlock || gCfg.manualPowerBlock) {
        gOBC = smc_obc_taken_power();
        int r = smc_set_power_block(true, gCfg.overrideOBC);
        if (r == SB_RESULT_OK) gState = SBCPUChargeStateBlocked;
        else if (r == SB_RESULT_OBC_TAKEN) gState = SBCPUChargeStateOBCControlled;
        return;
    }

    // 优先级 3：智能充电限制（迟滞）
    if (gCfg.smartChargeEnabled || gCfg.chargeLimitEnabled) {
        bool blocked = smc_get_charge_blocked();
        gOBC = smc_obc_taken_charge();
        if (!blocked && pct >= gCfg.upperLimit) {
            // 达到上限 → 停充（保留 AC 用 CH0C；不保留 AC 用 CH0I）
            int r;
            if (gCfg.keepAC) {
                r = smc_set_charge_block(true, gCfg.overrideOBC);
            } else {
                r = smc_set_power_block(true, gCfg.overrideOBC);
            }
            if (r == SB_RESULT_OK) {
                if (gState != SBCPUChargeStateBlocked) {
                    gState = SBCPUChargeStateBlocked;
                    engine_log(@"limit reached: pct=%d >= %d -> BLOCKED", pct, gCfg.upperLimit);
                }
            } else if (r == SB_RESULT_OBC_TAKEN) {
                gState = SBCPUChargeStateOBCControlled;
                engine_log(@"OBC took over at limit (pct=%d)", pct);
            }
        } else if (blocked && pct <= gCfg.lowerLimit) {
            // 降到下限 → 恢复充电
            int r = smc_set_charge_block(false, gCfg.overrideOBC);
            if (r == SB_RESULT_OK) {
                if (gState != SBCPUChargeStateCharging) {
                    gState = SBCPUChargeStateCharging;
                    engine_log(@"resume: pct=%d <= %d -> CHARGING", pct, gCfg.lowerLimit);
                }
            } else if (r == SB_RESULT_OBC_TAKEN) {
                gState = SBCPUChargeStateOBCControlled;
            }
        }
        // 中间区间：保持当前状态（迟滞）
        return;
    }

    // 优先级 4：无限制 → 正常充电
    if (gState != SBCPUChargeStateCharging) {
        gState = SBCPUChargeStateCharging;
        engine_log(@"no limit active; ensure charging (pct=%d)", pct);
    }
    if (smc_get_charge_blocked() || smc_get_power_blocked()) {
        (void)smc_set_charge_block(false, true);
        (void)smc_set_power_block(false, true);
    }
}

void sb_engine_redecide(void) {
    (void)sb_engine_load_config(&gCfg);
    gManualChargeBlock = gCfg.manualChargeBlock;
    gManualPowerBlock = gCfg.manualPowerBlock;
    sb_power_poll_once();
}

// ---------- 查询 ----------
SBCPUChargeState sb_engine_state(void) { return gState; }
uint8_t sb_engine_battery_percent(void) { return (uint8_t)(gBatteryPercent < 0 ? 0 : gBatteryPercent); }
bool sb_engine_charge_blocked(void) { return smc_get_charge_blocked(); }
bool sb_engine_power_blocked(void) { return smc_get_power_blocked(); }
bool sb_engine_smc_available(void) { return engine_ensure_smc(); }
bool sb_engine_obc_taken(void) { return gOBC; }
bool sb_engine_wireless(void) { return gWireless; }
