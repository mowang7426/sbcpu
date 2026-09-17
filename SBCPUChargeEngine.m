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
static bool gLimitUsesPowerBlock = false; // 本次停充用的是 CH0I（keepAC=NO）而非 CH0C

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

    // 防御：上下限有效性
    if (c.upperLimit > 100) c.upperLimit = 100;
    if (c.lowerLimit > 99) c.lowerLimit = 99;
    if (c.upperLimit <= c.lowerLimit) { c.upperLimit = 80; c.lowerLimit = 70; }

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
        engine_log(@"manual power block -> %d (0x%x)", block, r);
    }
    engine_unlock();
    return r;
}

// 核心决策
void sb_engine_decide(int pct, bool charging, bool wireless) {
    engine_lock();
    if (pct >= 0) gBatteryPercent = pct;
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
        gManualChargeBlock = gCfg.manualChargeBlock;
        gManualPowerBlock = gCfg.manualPowerBlock;

        // If the user moved the limit above the current SoC, or changed the
        // drain mode while already blocked, do not carry the old hysteresis
        // decision forever. Release the previous key and let this invocation
        // evaluate the new configuration from scratch.
        if (gLimitBlocked &&
            (!gCfg.smartChargeEnabled || pct < gCfg.upperLimit ||
             oldCfg.keepAC != gCfg.keepAC)) {
            if (gLimitUsesPowerBlock) {
                (void)smc_set_power_block(false, oldCfg.overrideOBC);
            } else {
                (void)smc_set_charge_block(false, oldCfg.overrideOBC);
            }
            gLimitBlocked = false;
            gLimitUsesPowerBlock = false;
        }

        engine_log(@"config updated: smart=%d upper=%d lower=%d keepAC=%d obc=%d",
            gCfg.smartChargeEnabled, gCfg.upperLimit, gCfg.lowerLimit, gCfg.keepAC, gCfg.overrideOBC);
    }

    // V4.31：CH0I 停充后，IOPMPowerSource 的 ExternalConnected/charging
    // 会变成 false。因此“安全状态”检查不能挡在回充判断之前。
    // 只要智能停充已启用、没有手动断供，并且电量已经跌到回充下限，
    // 先无条件清除我们自己的 CH0I，再重新采样一次电源状态。
    // 这样 85% -> 82% 时不会因为 CH0I=1 导致系统一直停在 NoPower。
    if (gCfg.smartChargeEnabled && !gCfg.manualChargeBlock && !gCfg.manualPowerBlock &&
        pct >= 0 && pct <= gCfg.lowerLimit) {
        bool shouldReleaseLimit = gLimitBlocked || smc_get_power_blocked();
        if (shouldReleaseLimit) {
            int rr = smc_set_power_block(false, gCfg.overrideOBC);
            if (rr == SB_RESULT_OK) {
                gLimitBlocked = false;
                gLimitUsesPowerBlock = false;
                gState = SBCPUChargeStateCharging;
                engine_log(@"smart recovery: pct=%d <= %d -> RELEASE CH0I before power-state gate", pct, gCfg.lowerLimit);
                // 重新读取 ExternalConnected/charging；如果物理充电器仍在，
                // 同一次事件即可继续走正常充电状态机。
                sb_power_poll_once();
                engine_unlock();
                return;
            } else {
                engine_log(@"smart recovery: pct=%d <= %d but CH0I release failed result=%d", pct, gCfg.lowerLimit, rr);
            }
        }
    }

    // 优先级 1：安全状态
    if (!charging || !smc_external_connected()) {
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

    // 优先级 3：智能充电限制（迟滞，独立状态变量，不从 CH0C 反推）
    if (gCfg.smartChargeEnabled || gCfg.chargeLimitEnabled) {
        gOBC = smc_obc_taken_charge();
        if (!gLimitBlocked && pct >= gCfg.upperLimit) {
            // V4.30/V4.31: 智能停充触发后直接切断外部供电（CH0I=1）。
            // 这样“已阻止”与实际充电器输入路径一致，避免 CH0C inhibit
            // 后仍存在小额外部输入/系统维持电流的歧义。
            // keepAC 不再决定智能停充的执行路径；它仍保留在配置协议中以
            // 兼容旧版 UI，但 Charge Engine 的智能停充统一使用 CH0I。
            int r = smc_set_power_block(true, gCfg.overrideOBC);
            gLimitUsesPowerBlock = true;
            if (r == SB_RESULT_OK) {
                gLimitBlocked = true;
                if (gState != SBCPUChargeStateBlocked) {
                    gState = SBCPUChargeStateBlocked;
                    engine_log(@"limit reached: pct=%d >= %d -> BLOCKED (%s)",
                        pct, gCfg.upperLimit, gLimitUsesPowerBlock ? "CH0I" : "CH0C");
                }
            } else if (r == SB_RESULT_OBC_TAKEN) {
                gState = SBCPUChargeStateOBCControlled;
                engine_log(@"OBC took over at limit (pct=%d)", pct);
            }
        } else if (gLimitBlocked && pct <= gCfg.lowerLimit) {
            // 降到下限 → 恢复充电（按之前停充用的 key 复位）
            int r;
            if (gLimitUsesPowerBlock) {
                r = smc_set_power_block(false, gCfg.overrideOBC);
            } else {
                r = smc_set_charge_block(false, gCfg.overrideOBC);
            }
            if (r == SB_RESULT_OK) {
                gLimitBlocked = false;
                gLimitUsesPowerBlock = false;
                if (gState != SBCPUChargeStateCharging) {
                    gState = SBCPUChargeStateCharging;
                    engine_log(@"resume: pct=%d <= %d -> CHARGING", pct, gCfg.lowerLimit);
                }
            } else if (r == SB_RESULT_OBC_TAKEN) {
                gState = SBCPUChargeStateOBCControlled;
            }
        } else if (gLimitBlocked) {
            // Hysteresis middle band: keep the logical state, but reconcile the
            // actual SMC bit. iOS/OBC can reset CH0C/CH0I while unplugged or
            // during a daemon restart; the software flag alone is not enough.
            bool actualBlocked = gLimitUsesPowerBlock
                ? smc_get_power_blocked()
                : smc_get_charge_blocked();
            if (!actualBlocked) {
                int r = gLimitUsesPowerBlock
                    ? smc_set_power_block(true, gCfg.overrideOBC)
                    : smc_set_charge_block(true, gCfg.overrideOBC);
                if (r == SB_RESULT_OK) {
                    engine_log(@"re-applied active limit at pct=%d after SMC state drift", pct);
                } else if (r == SB_RESULT_OBC_TAKEN) {
                    gState = SBCPUChargeStateOBCControlled;
                }
            }
        } else {
            // Daemon restart/reload: gLimitBlocked is volatile, while CH0C/CH0I
            // can still contain the previous inhibit bit. At or below the upper
            // threshold we explicitly converge to normal charging.
            bool staleChargeBlock = smc_get_charge_blocked();
            bool stalePowerBlock = smc_get_power_blocked();
            if (pct < gCfg.upperLimit && (staleChargeBlock || stalePowerBlock)) {
                if (staleChargeBlock) (void)smc_set_charge_block(false, gCfg.overrideOBC);
                if (stalePowerBlock) (void)smc_set_power_block(false, gCfg.overrideOBC);
            }
        }
        // 中间区间（lower < pct < upper）：保持迟滞；智能停充使用 CH0I，持续校验外部供电阻断状态。
        engine_unlock();
        return;
    }

    // 优先级 4：无限制 → 正常充电
    if (gLimitBlocked) {
        gLimitBlocked = false;
        gLimitUsesPowerBlock = false;
        engine_log(@"limit disabled; reset limit state");
    }
    if (gState != SBCPUChargeStateCharging) {
        gState = SBCPUChargeStateCharging;
        engine_log(@"no limit active; ensure charging (pct=%d)", pct);
    }
    if (smc_get_charge_blocked() || smc_get_power_blocked()) {
        (void)smc_set_charge_block(false, gCfg.overrideOBC);
        (void)smc_set_power_block(false, gCfg.overrideOBC);
    }
    engine_unlock();
}

void sb_engine_redecide(void) {
    engine_lock();
    (void)sb_engine_load_config(&gCfg);
    gManualChargeBlock = gCfg.manualChargeBlock;
    gManualPowerBlock = gCfg.manualPowerBlock;
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
