// SBCPUChargeEngine.m — 充电状态机实现 (V4.31 Stable)
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
#include <pthread.h>
#include <string.h>
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
// 智能充电限制的独立状态（不从 CH0C 反推；keepAC=NO 用 CH0I 停充时 CH0C 仍为 0）
static bool gLimitBlocked = false;        // 当前是否处于"达到上限停充"状态
static bool gLimitUsesPowerBlock = false;
static bool gPowerBlockUserReleased = false;
static bool gThermalBlocked = false;
static bool gScheduleBlocked = false;
static NSInteger gScheduleStage = 0;
static double gBatteryTemperatureC = -1.0;

// IOKit callbacks run on the daemon run-loop while socket commands arrive on a
// separate thread. Keep all state-machine mutations serialized. Recursive is
// intentional: sb_engine_redecide() may synchronously trigger the power callback.
static pthread_once_t gEngineMutexOnce = PTHREAD_ONCE_INIT;
static pthread_mutex_t gEngineMutex;
static void engine_mutex_init(void) {
    pthread_mutexattr_t attr;
    pthread_mutexattr_init(&attr);
    pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(&gEngineMutex, &attr);
    pthread_mutexattr_destroy(&attr);
}
static inline void engine_lock(void) {
    pthread_once(&gEngineMutexOnce, engine_mutex_init);
    pthread_mutex_lock(&gEngineMutex);
}
static inline void engine_unlock(void) {
    pthread_mutex_unlock(&gEngineMutex);
}

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
    // V1 deliberately uses one master switch. Treat smartChargeEnable as
    // authoritative so stale legacy chargeLimitEnabled values cannot keep the
    // engine active after the user turns Smart Charging off.
    c.chargeLimitEnabled = c.smartChargeEnabled;
    c.upperLimit = (uint8_t)pref_int(d, @"smartChargeUpperLimit", 80);
    c.lowerLimit = (uint8_t)pref_int(d, @"smartChargeLowerLimit", 70);
    c.keepAC = pref_bool(d, @"chargeKeepAC", true);
    c.overrideOBC = pref_bool(d, @"chargeOverrideOBC", false);
    c.manualChargeBlock = pref_bool(d, @"blockChargingEnable", false);
    c.manualPowerBlock = pref_bool(d, @"blockPowerEnable", false);
    c.scheduleEnabled = pref_bool(d, @"chargeScheduleEnabled", false);
    c.scheduleStartHour = (uint8_t)pref_int(d, @"chargeScheduleStartHour", 22);
    c.scheduleStartMinute = (uint8_t)pref_int(d, @"chargeScheduleStartMinute", 0);
    c.scheduleStage2Hour = (uint8_t)pref_int(d, @"chargeScheduleStage2Hour", 5);
    c.scheduleStage2Minute = (uint8_t)pref_int(d, @"chargeScheduleStage2Minute", 30);
    c.scheduleStage3Hour = (uint8_t)pref_int(d, @"chargeScheduleStage3Hour", 6);
    c.scheduleStage3Minute = (uint8_t)pref_int(d, @"chargeScheduleStage3Minute", 30);
    c.smartThermalEnabled = pref_bool(d, @"smartThermalChargeEnable", false);
    c.thermalUpperC = (uint8_t)pref_int(d, @"smartThermalUpperC", 42);
    c.thermalLowerC = (uint8_t)pref_int(d, @"smartThermalLowerC", 38);

    // 防御：上下限有效性
    if (c.upperLimit > 100) c.upperLimit = 100;
    if (c.lowerLimit > 99) c.lowerLimit = 99;
    if (c.upperLimit <= c.lowerLimit) { c.upperLimit = 80; c.lowerLimit = 70; }
    if (c.scheduleStartHour > 23) c.scheduleStartHour = 22;
    if (c.scheduleStartMinute > 59) c.scheduleStartMinute = 0;
    if (c.scheduleStage2Hour > 23) c.scheduleStage2Hour = 5;
    if (c.scheduleStage2Minute > 59) c.scheduleStage2Minute = 30;
    if (c.scheduleStage3Hour > 23) c.scheduleStage3Hour = 6;
    if (c.scheduleStage3Minute > 59) c.scheduleStage3Minute = 30;
    if (c.thermalUpperC > 60) c.thermalUpperC = 60;
    if (c.thermalLowerC < 25) c.thermalLowerC = 25;
    if (c.thermalUpperC <= c.thermalLowerC) { c.thermalUpperC = 42; c.thermalLowerC = 38; }

    if (cfg) *cfg = c;
    return true;
}

void sb_engine_init(void) {
    engine_lock();
    IOReturn oret = smc_open();
    gSmcAvailable = (oret == kIOReturnSuccess);
    if (!gSmcAvailable) {
        engine_log(@"AppleSMC open failed: 0x%08x (uid=%d); engine disabled", (unsigned)oret, (int)getuid());
        gState = SBCPUChargeStateError;
        engine_unlock();
        return;
    }
    engine_log(@"AppleSMC opened OK (uid=%d)", (int)getuid());
    if (!sb_engine_load_config(&gCfg)) {
        engine_log(@"No preferences yet; engine idle");
        gState = SBCPUChargeStateUnknown;
        engine_unlock();
        return;
    }
    // 启动立即决策一次（不等下一次电池事件）
    sb_engine_redecide();
    engine_unlock();
}

void sb_engine_shutdown(void) {
    engine_lock();
    // 恢复我们自己的 inhibit 状态并停止。Do not force-disable Apple's OBC
    // during unload; leaving system-managed charging alone is the safer exit.
    if (gSmcAvailable) {
        (void)smc_set_charge_block(false, false);
        (void)smc_set_power_block(false, false);
    }
    smc_close();
    gState = SBCPUChargeStateUnknown;
    gLimitBlocked = false;
    gLimitUsesPowerBlock = false;
    engine_unlock();
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
    engine_lock();
    if (!engine_ensure_smc()) { engine_unlock(); return SB_RESULT_SMC_UNAVAILABLE; }
    int r = smc_set_charge_block(block, gCfg.overrideOBC);
    if (r == SB_RESULT_OK) {
        gManualChargeBlock = block;
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
    engine_unlock();
    return r;
}

int sb_engine_manual_power_block(bool block) {
    engine_lock();
    if (!engine_ensure_smc()) { engine_unlock(); return SB_RESULT_SMC_UNAVAILABLE; }
    int r = smc_set_power_block(block, gCfg.overrideOBC);
    if (r == SB_RESULT_OK) {
        gManualPowerBlock = block;
        gCfg.manualPowerBlock = block;
        NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:@SB_PREF_FILE];
        if (d) {
            d[@"blockPowerEnable"] = @(block);
            [d writeToFile:@SB_PREF_FILE atomically:YES];
        }
        gState = block ? SBCPUChargeStateBlocked : SBCPUChargeStateCharging;
        if (!block) {
            // 手动恢复供电必须压过当前自动停充的瞬时状态：清掉易失的自动停充标记，
            // 并在回充下限前暂缓自动 CH0I 重施，避免刚恢复又立刻断供。
            gLimitBlocked = false;
            gLimitUsesPowerBlock = false;
            gPowerBlockUserReleased = true;
            engine_log(@"manual power release: cleared CH0I and suspended automatic power block until recharge threshold");
        }
        engine_log(@"manual power block -> %d (0x%x)", block, r);
    }
    engine_unlock();
    return r;
}

// 核心决策
void sb_engine_decide(int pct, bool charging, bool wireless, double temperatureC) {
    engine_lock();
    if (pct >= 0) gBatteryPercent = pct;
    if (temperatureC > 0.0 && temperatureC < 100.0) gBatteryTemperatureC = temperatureC;
    gWireless = wireless;
    if (!engine_ensure_smc()) {
        gState = SBCPUChargeStateError;
        engine_unlock();
        return;
    }

    // 重读配置（每次决策都读，保证 UI 改动即时生效）
    SBCPUChargeConfig newCfg = gCfg;
    (void)sb_engine_load_config(&newCfg);
    bool cfgChanged = memcmp(&newCfg, &gCfg, sizeof(SBCPUChargeConfig)) != 0;
    if (cfgChanged) {
        SBCPUChargeConfig oldCfg = gCfg;
        gCfg = newCfg;
        bool oldManualPowerBlock = gManualPowerBlock;
        gManualChargeBlock = gCfg.manualChargeBlock;
        gManualPowerBlock = gCfg.manualPowerBlock;
        if (oldManualPowerBlock && !gManualPowerBlock) {
            // 用户明确关闭“阻止外部供电”：即使当前电量仍高于智能停充上限，也不要马上被智能规则重新断供。
            gPowerBlockUserReleased = true;
            (void)smc_set_power_block(false, oldCfg.overrideOBC);
            engine_log(@"manual power block released by user; temporarily suppress CH0I limit until recharge threshold");
        } else if (gManualPowerBlock) {
            gPowerBlockUserReleased = false;
        }

        // If the user moved the limit above the current SoC, or changed the
        // drain mode while already blocked, do not carry the old hysteresis
        // decision forever. Release the previous key and let this invocation
        // evaluate the new configuration from scratch.
        if (!gCfg.smartChargeEnabled || pct < gCfg.upperLimit ||
            oldCfg.keepAC != gCfg.keepAC) {
            if (gLimitUsesPowerBlock) {
                (void)smc_set_power_block(false, oldCfg.overrideOBC);
            }
            gLimitBlocked = false;
            gLimitUsesPowerBlock = false;
        }

        bool scheduleConfigChanged = oldCfg.scheduleEnabled != gCfg.scheduleEnabled ||
            oldCfg.scheduleStartHour != gCfg.scheduleStartHour || oldCfg.scheduleStartMinute != gCfg.scheduleStartMinute ||
            oldCfg.scheduleStage2Hour != gCfg.scheduleStage2Hour || oldCfg.scheduleStage2Minute != gCfg.scheduleStage2Minute ||
            oldCfg.scheduleStage3Hour != gCfg.scheduleStage3Hour || oldCfg.scheduleStage3Minute != gCfg.scheduleStage3Minute;
        if (scheduleConfigChanged) {
            gScheduleBlocked = false;
            gScheduleStage = 0;
        }
        if (gThermalBlocked && (!gCfg.smartThermalEnabled || oldCfg.smartThermalEnabled != gCfg.smartThermalEnabled || oldCfg.thermalUpperC != gCfg.thermalUpperC || oldCfg.thermalLowerC != gCfg.thermalLowerC)) {
            gThermalBlocked = false;
        }

        engine_log(@"config updated: smart=%d upper=%d lower=%d keepAC=%d obc=%d",
            gCfg.smartChargeEnabled, gCfg.upperLimit, gCfg.lowerLimit, gCfg.keepAC, gCfg.overrideOBC);
    }

    // 夜间计划独立使用 CH0C。阶段切换时重置上一阶段的迟滞状态，避免70%阶段的阻止状态锁住85%/100%阶段。
    NSInteger scheduleStage = 0, scheduleTarget = 0;
    if (gCfg.scheduleEnabled) {
        NSDateComponents *now = [[NSCalendar currentCalendar] components:(NSCalendarUnitHour | NSCalendarUnitMinute) fromDate:[NSDate date]];
        NSInteger minuteOfDay = now.hour * 60 + now.minute;
        NSInteger start = gCfg.scheduleStartHour * 60 + gCfg.scheduleStartMinute;
        NSInteger stage2 = gCfg.scheduleStage2Hour * 60 + gCfg.scheduleStage2Minute;
        NSInteger stage3 = gCfg.scheduleStage3Hour * 60 + gCfg.scheduleStage3Minute;
        BOOL overnight = start > stage2;
        if ((overnight && (minuteOfDay >= start || minuteOfDay < stage2)) || (!overnight && minuteOfDay >= start && minuteOfDay < stage2)) { scheduleStage = 1; scheduleTarget = 70; }
        else if (minuteOfDay >= stage2 && minuteOfDay < stage3) { scheduleStage = 2; scheduleTarget = 85; }
        else { scheduleStage = 3; scheduleTarget = 100; }
    }
    if (!gCfg.scheduleEnabled || scheduleStage != gScheduleStage) {
        if (gScheduleStage != scheduleStage) gScheduleBlocked = false;
        gScheduleStage = scheduleStage;
    }
    if (scheduleStage && pct >= scheduleTarget) gScheduleBlocked = true;
    else if (scheduleStage && pct <= MAX(0, scheduleTarget - 2)) gScheduleBlocked = false;

    if (gCfg.smartChargeEnabled && gLimitBlocked && !gCfg.manualChargeBlock && !gCfg.manualPowerBlock &&
        pct >= 0 && pct <= gCfg.lowerLimit) {
        int rr = smc_set_power_block(false, gCfg.overrideOBC);
        if (rr == SB_RESULT_OK) {
            gLimitBlocked = false; gLimitUsesPowerBlock = false;
            gPowerBlockUserReleased = false;
            engine_log(@"smart recovery before power check: pct=%d <= %d -> release CH0I", pct, gCfg.lowerLimit);
        }
    }

    // 夜间计划 CH0C 导致电源状态暂时报告断开时，也必须进入下方恢复决策。
    // 温控 CH0C 阻止同理，控制请求在安全检查后会重算/解除。

    // 温度迟滞由下方统一计算并合并 CH0C 请求；在安全状态分支前不直接清位。
    // 优先级 1：安全状态。
    // CH0I/CH0C 生效后，IOPMPowerSource 可能暂时报告 ExternalConnected=false。
    // 只要存在我们自己的 inhibit 或待处理状态，不能提前 return，否则恢复/重应用会卡死。
    bool actualChargeBlock = smc_get_charge_blocked();
    bool actualPowerBlock = smc_get_power_blocked();
    bool controlActive = actualChargeBlock || actualPowerBlock ||
        gManualChargeBlock || gManualPowerBlock ||
        gCfg.manualChargeBlock || gCfg.manualPowerBlock ||
        gLimitBlocked || gThermalBlocked || gScheduleBlocked;
    if ((!charging || !smc_external_connected()) && !controlActive) {
        if (gState != SBCPUChargeStateNoPower) {
            gState = SBCPUChargeStateNoPower;
            engine_log(@"no external power; idle (pct=%d)", pct);
        }
        engine_unlock();
        return;
    }

    // 无线充电：底层不可靠控制 → 不假装成功
    if (wireless && gCfg.smartChargeEnabled) {
        if (gState != SBCPUChargeStateUnsupported) {
            gState = SBCPUChargeStateUnsupported;
            engine_log(@"wireless charging detected; limit unsupported");
        }
        engine_unlock();
        return;
    }

    // 优先级 2：手动阻止充电
    if (gManualChargeBlock || gCfg.manualChargeBlock) {
        gOBC = smc_obc_taken_charge();
        int r = smc_set_charge_block(true, gCfg.overrideOBC);
        if (r == SB_RESULT_OK) gState = SBCPUChargeStateBlocked;
        else if (r == SB_RESULT_OBC_TAKEN) gState = SBCPUChargeStateOBCControlled;
        engine_unlock();
        return;
    }
    // 手动阻止外部供电
    if (gManualPowerBlock || gCfg.manualPowerBlock) {
        gOBC = smc_obc_taken_power();
        int r = smc_set_power_block(true, gCfg.overrideOBC);
        if (r == SB_RESULT_OK) gState = SBCPUChargeStateBlocked;
        else if (r == SB_RESULT_OBC_TAKEN) gState = SBCPUChargeStateOBCControlled;
        engine_unlock();
        return;
    }

    // 智能温控保持原有 CH0C 温度迟滞；只更新自己的请求，不直接清除其他功能的 CH0C。
    if (gCfg.smartThermalEnabled && gBatteryTemperatureC > 0.0) {
        if (!gThermalBlocked && gBatteryTemperatureC >= gCfg.thermalUpperC) {
            gThermalBlocked = true;
            engine_log(@"thermal limit: %.1fC >= %dC -> request CH0C", gBatteryTemperatureC, gCfg.thermalUpperC);
        } else if (gThermalBlocked && gBatteryTemperatureC <= gCfg.thermalLowerC) {
            gThermalBlocked = false;
            engine_log(@"thermal recovery: %.1fC <= %dC -> release thermal request", gBatteryTemperatureC, gCfg.thermalLowerC);
        }
    } else if (gThermalBlocked) {
        gThermalBlocked = false;
        engine_log(@"thermal feature disabled/unavailable -> release thermal request");
    }

    // 夜间计划与温控共同使用 CH0C，但分别维护请求；任一开启且触发就保持阻止充电。
    // 夜间计划与温控共享 CH0C 位，但各自只持有独立请求；活动任一项就保持停充。
    bool chargeBlockRequested = gThermalBlocked || gScheduleBlocked ||
        ((gManualChargeBlock || gCfg.manualChargeBlock) && smc_get_charge_blocked());
    bool chargeBlockedNow = smc_get_charge_blocked();
    if (chargeBlockRequested && !chargeBlockedNow) {
        int r = smc_set_charge_block(true, gCfg.overrideOBC);
        if (r == SB_RESULT_OK) {
            gState = SBCPUChargeStateBlocked;
            engine_log(@"CH0C applied: thermal=%d schedule=%d stage=%ld pct=%d", gThermalBlocked, gScheduleBlocked, (long)gScheduleStage, pct);
        } else if (r == SB_RESULT_OBC_TAKEN) { gState = SBCPUChargeStateOBCControlled; }
    } else if (!chargeBlockRequested && chargeBlockedNow) {
        int r = smc_set_charge_block(false, gCfg.overrideOBC);
        if (r == SB_RESULT_OK) engine_log(@"CH0C released: no enabled feature requests charge block");
    }

    // 智能停充保留原有独立逻辑：只由 smartChargeEnable 控制，沿用 CH0I 与用户上下限迟滞。
    if (gCfg.smartChargeEnabled) {
        if (gPowerBlockUserReleased) {
            if (pct <= gCfg.lowerLimit) gPowerBlockUserReleased = false;
            else if (smc_get_power_blocked()) (void)smc_set_power_block(false, gCfg.overrideOBC);
        }
        if (pct >= 0 && pct <= gCfg.lowerLimit && gLimitBlocked) {
            int rr = smc_set_power_block(false, gCfg.overrideOBC);
            if (rr == SB_RESULT_OK) {
                gLimitBlocked = false; gLimitUsesPowerBlock = false;
                engine_log(@"smart recovery: pct=%d <= %d -> release CH0I", pct, gCfg.lowerLimit);
            }
        } else if (!gLimitBlocked && !gPowerBlockUserReleased && pct >= gCfg.upperLimit) {
            gLimitUsesPowerBlock = true;
            int r = smc_set_power_block(true, gCfg.overrideOBC);
            if (r == SB_RESULT_OK) { gLimitBlocked = true; gState = SBCPUChargeStateBlocked; engine_log(@"smart limit: pct=%d >= %d -> CH0I", pct, gCfg.upperLimit); }
            else if (r == SB_RESULT_OBC_TAKEN) gState = SBCPUChargeStateOBCControlled;
        } else if (gLimitBlocked && pct > gCfg.lowerLimit) {
            if (!smc_get_power_blocked()) (void)smc_set_power_block(true, gCfg.overrideOBC);
        } else if (!gPowerBlockUserReleased && pct < gCfg.upperLimit && smc_get_power_blocked()) {
            // daemon 重启后软件迟滞状态会丢失；仅在普通智能停充启用且低于上限时清旧 CH0I。
            (void)smc_set_power_block(false, gCfg.overrideOBC);
        }
    } else {
        if (gLimitBlocked || smc_get_power_blocked()) (void)smc_set_power_block(false, gCfg.overrideOBC);
        gLimitBlocked = false; gLimitUsesPowerBlock = false;
    }

    // 仅夜间计划/温控/普通智能停充均未触发时才报告正常充电；不清除其他仍有效的控制请求。
    if (!chargeBlockRequested && !gLimitBlocked && !gManualChargeBlock && !gManualPowerBlock) {
        if (gState != SBCPUChargeStateCharging) gState = SBCPUChargeStateCharging;
    }
    engine_unlock();
}

void sb_engine_redecide(void) {
    // 不要在这里提前覆盖 gCfg；统一交给 sb_engine_decide() 比较旧/新配置，
    // 否则会跳过配置迁移、手动释放和迟滞状态重置。
    engine_lock();
    sb_power_poll_once();
    engine_unlock();
}

// ---------- 查询 ----------
SBCPUChargeState sb_engine_state(void) { engine_lock(); SBCPUChargeState v = gState; engine_unlock(); return v; }
uint8_t sb_engine_battery_percent(void) { engine_lock(); uint8_t v = (uint8_t)(gBatteryPercent < 0 ? 0 : gBatteryPercent); engine_unlock(); return v; }
bool sb_engine_charge_blocked(void) { engine_lock(); bool v = smc_get_charge_blocked(); engine_unlock(); return v; }
bool sb_engine_power_blocked(void) { engine_lock(); bool v = smc_get_power_blocked(); engine_unlock(); return v; }
bool sb_engine_smc_available(void) { engine_lock(); bool v = engine_ensure_smc(); engine_unlock(); return v; }
bool sb_engine_obc_taken(void) { engine_lock(); bool v = gOBC; engine_unlock(); return v; }
bool sb_engine_wireless(void) { engine_lock(); bool v = gWireless; engine_unlock(); return v; }
