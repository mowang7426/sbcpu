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
#import "SBCPUChargeStore.h"
#include "SBCPUChargeDayNight.h"

static SBCPUChargeConfig gCfg = {0};
static SBCPUChargeState gState = SBCPUChargeStateUnknown;
static int gBatteryPercent = -1;
static bool gWireless = false;
static bool gSmcAvailable = false;
static bool gOBC = false;
static bool gManualChargeBlock = false;  // 手动状态持久于内存（daemon 生命周期）
static bool gManualPowerBlock = false;
// 智能充电限制的独立状态（不从 CH0C 反推；keepAC=NO 用 CH0I 停充时 CH0C 仍为 0）
static bool gLimitInitialized = false;
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

static NSInteger sb_schedule_stage_for_minute(BOOL enabled, NSInteger start, NSInteger final,
                                               NSInteger now, NSInteger *target) {
    if (target) *target = 0;
    if (!enabled) return 0;
    start = (start % 1440 + 1440) % 1440;
    final = (final % 1440 + 1440) % 1440;
    now = (now % 1440 + 1440) % 1440;
    if (start == final) return 0; // invalid equal boundaries: fail safe to hold
    if (start > final) {
        // Cross midnight: start..midnight and midnight..final are the 70% window.
        if (now >= start || now < final) {
            if (target) *target = 70;
            return 1;
        }
        if (target) *target = 100;
        return 2;
    }
    // Same-day plan: hold before start, then 70% until final, then 100% phase.
    if (now < start) return 0;
    if (now < final) {
        if (target) *target = 70;
        return 1;
    }
    if (target) *target = 100;
    return 2;
}

bool sb_engine_load_config(SBCPUChargeConfig *cfg) {
    NSDictionary *d = SBChargeRead();
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
    c.dayNightAutoEnabled = pref_bool(d, @"chargeDayNightAutoEnable", false);
    c.dayStartHour = (uint8_t)pref_int(d, @"chargeDayStartHour", 8);
    c.dayStartMinute = (uint8_t)pref_int(d, @"chargeDayStartMinute", 0);
    c.nightStartHour = (uint8_t)pref_int(d, @"chargeNightStartHour", 22);
    c.nightStartMinute = (uint8_t)pref_int(d, @"chargeNightStartMinute", 0);
    c.smartThermalEnabled = pref_bool(d, @"smartThermalChargeEnable", false);
    c.thermalUpperC = (uint8_t)pref_int(d, @"smartThermalUpperC", 42);
    c.thermalLowerC = (uint8_t)pref_int(d, @"smartThermalLowerC", 38);

    // 防御：上下限有效性
    if (c.upperLimit > 100) c.upperLimit = 100;
    if (c.lowerLimit > 99) c.lowerLimit = 99;
    if (c.upperLimit < 1) c.upperLimit = 1;
    if (c.upperLimit <= c.lowerLimit) c.lowerLimit = c.upperLimit - 1;
    if (c.scheduleStartHour > 23) c.scheduleStartHour = 22;
    if (c.scheduleStartMinute > 59) c.scheduleStartMinute = 0;
    if (c.scheduleStage2Hour > 23) c.scheduleStage2Hour = 5;
    if (c.scheduleStage2Minute > 59) c.scheduleStage2Minute = 30;
    if (c.scheduleStage3Hour > 23) c.scheduleStage3Hour = 6;
    if (c.scheduleStage3Minute > 59) c.scheduleStage3Minute = 30;
    if (c.dayStartHour > 23) c.dayStartHour = 8;
    if (c.dayStartMinute > 59) c.dayStartMinute = 0;
    if (c.nightStartHour > 23) c.nightStartHour = 22;
    if (c.nightStartMinute > 59) c.nightStartMinute = 0;
    if (c.dayStartHour * 60 + c.dayStartMinute == c.nightStartHour * 60 + c.nightStartMinute)
        c.dayNightAutoEnabled = false; // store rejects this; fail safe for old files
    if (c.dayNightAutoEnabled) {
        NSDateComponents *now = [[NSCalendar currentCalendar] components:(NSCalendarUnitHour | NSCalendarUnitMinute) fromDate:[NSDate date]];
        int minute = (int)(now.hour * 60 + now.minute);
        bool day = sb_charge_is_daytime(minute, c.dayStartHour * 60 + c.dayStartMinute,
                                        c.nightStartHour * 60 + c.nightStartMinute);
        c.smartChargeEnabled = day;
        c.chargeLimitEnabled = day;
        c.scheduleEnabled = !day;
    }
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
    int r = smc_manual_charge_block(block, gCfg.overrideOBC);
    if (r == SB_RESULT_OK) {
        gManualChargeBlock = block;
        gCfg.manualChargeBlock = block;
        // 同步回偏好，UI 重启后仍生效
        if (!SBChargePatch(@{@"blockChargingEnable": @(block)})) {
            engine_log(@"manual state persistence failed");
            engine_unlock(); return SB_RESULT_IO_ERROR;
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
    int r = smc_manual_power_block(block, gCfg.overrideOBC);
    if (r == SB_RESULT_OK) {
        gManualPowerBlock = block;
        gCfg.manualPowerBlock = block;
        if (!SBChargePatch(@{@"blockPowerEnable": @(block)})) {
            engine_log(@"manual state persistence failed");
            engine_unlock(); return SB_RESULT_IO_ERROR;
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

        // Only charge-limit edits reset its hysteresis/temporary manual override.
        // Unrelated UI saves must not release a valid 60/55 hold at 58%.
        bool limitChanged = oldCfg.smartChargeEnabled != gCfg.smartChargeEnabled ||
            oldCfg.upperLimit != gCfg.upperLimit || oldCfg.lowerLimit != gCfg.lowerLimit;
        if (limitChanged) {
            gLimitInitialized = true;
            gPowerBlockUserReleased = false;
            gLimitBlocked = gCfg.smartChargeEnabled && pct >= gCfg.upperLimit;
            gLimitUsesPowerBlock = gLimitBlocked;
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

    // 夜间计划只有两个充电窗口：开始时充至70%，最终时间后解除夜间阻止并充至100%。
    NSInteger scheduleTarget = 0;
    NSInteger minuteOfDay = 0;
    if (gCfg.scheduleEnabled) {
        NSDateComponents *now = [[NSCalendar currentCalendar] components:(NSCalendarUnitHour | NSCalendarUnitMinute) fromDate:[NSDate date]];
        minuteOfDay = now.hour * 60 + now.minute;
    }
    NSInteger scheduleStage = sb_schedule_stage_for_minute(
        gCfg.scheduleEnabled,
        gCfg.scheduleStartHour * 60 + gCfg.scheduleStartMinute,
        gCfg.scheduleStage3Hour * 60 + gCfg.scheduleStage3Minute,
        minuteOfDay, &scheduleTarget);
    NSInteger previousScheduleStage = gScheduleStage;
    if (scheduleStage != gScheduleStage) {
        gScheduleStage = scheduleStage;
        gScheduleBlocked = false;
    }
    if (!gCfg.scheduleEnabled) {
        gScheduleBlocked = false;
    } else if (scheduleStage == 0) {
        // 首个充电时段开始之前维持计划停充。
        gScheduleBlocked = true;
    } else {
        // 每个计划阶段均按目标电量计算请求；到最终时间进入100%窗口，
        // pct<100 必须释放夜间CH0C，避免沿用85%阶段或旧周期的阻止状态。
        gScheduleBlocked = (pct >= scheduleTarget);
        if (scheduleStage == 2 && scheduleStage != previousScheduleStage && pct < 100)
            gScheduleBlocked = false;
    }

    // No early return for a manual request, wireless, or ExternalConnected=false:
    // CH0I itself can remove that signal. Each bit must still get its release.
    // Use checked reads: a failed read is NOT a cleared hardware bit.
    uint8_t chargeValue = 0, powerValue = 0;
    int32_t chargeSize = 1, powerSize = 1;
    IOReturn chargeRead = smc_read_key('CH0C', &chargeValue, &chargeSize);
    IOReturn powerRead = smc_read_key('CH0I', &powerValue, &powerSize);
    bool actualChargeBlock = chargeRead == kIOReturnSuccess && (chargeValue & 1);
    bool actualPowerBlock = powerRead == kIOReturnSuccess && (powerValue & 1);

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

    // Compute both independent requests before writing either bit.
    // In particular, manual CH0C must not prevent automatic CH0I recovery.
    if (!gCfg.smartChargeEnabled) {
        gLimitBlocked = false;
        gPowerBlockUserReleased = false;
    } else if (pct >= 0 && pct <= gCfg.lowerLimit) {
        gLimitBlocked = false;
        gPowerBlockUserReleased = false;
    } else if (gPowerBlockUserReleased) {
        gLimitBlocked = false;
    } else if (pct >= gCfg.upperLimit) {
        gLimitBlocked = true;
    } else if (!gLimitInitialized && actualPowerBlock && !gCfg.manualPowerBlock) {
        // Recover the hold after a daemon restart, but only inside the band.
        gLimitBlocked = true;
    }
    if (powerRead == kIOReturnSuccess) gLimitInitialized = true;
    gLimitUsesPowerBlock = gLimitBlocked;
    bool chargeBlockRequested = gCfg.manualChargeBlock || gThermalBlocked || gScheduleBlocked;
    bool powerBlockRequested = gCfg.manualPowerBlock || gLimitBlocked;
    // Wireless excludes new automatic power inhibition, never a release.
    if (wireless && !gCfg.manualPowerBlock) powerBlockRequested = false;

    int powerResult = SB_RESULT_OK, chargeResult = SB_RESULT_OK;
    // Restore AC first; CH0C can then be applied with a real external source.
    // Setters verify hardware and retry on the next watchdog after failure.
    if (!powerBlockRequested)
        powerResult = smc_set_power_block(false, gCfg.overrideOBC);
    if (!chargeBlockRequested)
        chargeResult = smc_set_charge_block(false, gCfg.overrideOBC);
    if (chargeBlockRequested)
        chargeResult = smc_set_charge_block(true, gCfg.overrideOBC);
    if (powerBlockRequested)
        powerResult = smc_set_power_block(true, gCfg.overrideOBC);

    gOBC = powerResult == SB_RESULT_OBC_TAKEN || chargeResult == SB_RESULT_OBC_TAKEN;
    SBCPUChargeState nextState;
    if ((powerResult != SB_RESULT_OK && powerResult != SB_RESULT_NO_EXTERNAL_POWER && powerResult != SB_RESULT_OBC_TAKEN) ||
        (chargeResult != SB_RESULT_OK && chargeResult != SB_RESULT_NO_EXTERNAL_POWER && chargeResult != SB_RESULT_OBC_TAKEN))
        nextState = SBCPUChargeStateError;
    else if (gOBC) nextState = SBCPUChargeStateOBCControlled;
    else if ((powerBlockRequested && powerResult == SB_RESULT_OK) ||
             (chargeBlockRequested && chargeResult == SB_RESULT_OK))
        nextState = SBCPUChargeStateBlocked;
    else if (wireless && gCfg.smartChargeEnabled) nextState = SBCPUChargeStateUnsupported;
    else if (!smc_external_connected()) nextState = SBCPUChargeStateNoPower;
    else nextState = SBCPUChargeStateCharging;
    if (nextState != gState || powerResult != SB_RESULT_OK || chargeResult != SB_RESULT_OK ||
        actualPowerBlock != powerBlockRequested || actualChargeBlock != chargeBlockRequested) {
        engine_log(@"decision pct=%d limits=%d/%d ext=%d manual=%d/%d thermal=%d schedule=%d request C/I=%d/%d result C/I=%d/%d state=%d",
            pct, gCfg.upperLimit, gCfg.lowerLimit, charging, gCfg.manualChargeBlock, gCfg.manualPowerBlock,
            gThermalBlocked, gScheduleBlocked, chargeBlockRequested, powerBlockRequested,
            chargeResult, powerResult, nextState);
    }
    gState = nextState;
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
