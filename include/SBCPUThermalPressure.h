#ifndef CPUTHERMAL_THERMAL_PRESSURE_H
#define CPUTHERMAL_THERMAL_PRESSURE_H

#import <Foundation/Foundation.h>
#import <notify.h>
#import <dlfcn.h>
#import <os/base.h>

// ============================================================================
// 热压力级别枚举（对应 OSThermalPressureLevel）
// 移植自 Battman thermal.h
// ============================================================================
typedef NS_ENUM(NSInteger, SBCPUThermalPressureLevel) {
    SBCPUThermalPressureLevelError    = -1,
    SBCPUThermalPressureLevelNominal  = 0,   // 正常
    SBCPUThermalPressureLevelLight    = 10,  // 轻微
    SBCPUThermalPressureLevelModerate = 20,  // 中等
    SBCPUThermalPressureLevelHeavy    = 30,  // 严重
    SBCPUThermalPressureLevelTrapping = 40,  // 临界
    SBCPUThermalPressureLevelSleeping = 50,  // 休眠

    SBCPUThermalPressureLevelUnknown  = 999
};

// ============================================================================
// 热通知级别枚举（对应 OSThermalNotificationLevel）
// 移植自 Battman thermal.h
// ============================================================================
typedef NS_ENUM(NSInteger, SBCPUThermalNotifLevel) {
    SBCPUThermalNotifLevelAny             = -1,
    SBCPUThermalNotifLevelNormal          = 0,
    SBCPUThermalNotifLevel70PercentTorch  = 1,
    SBCPUThermalNotifLevel70PercentBL     = 2,
    SBCPUThermalNotifLevel50PercentTorch  = 3,
    SBCPUThermalNotifLevel50PercentBL     = 4,
    SBCPUThermalNotifLevelDisableTorch    = 5,
    SBCPUThermalNotifLevel25PercentBL     = 6,
    SBCPUThermalNotifLevelDisableMapsHalo = 7,
    SBCPUThermalNotifLevelAppTerminate    = 8,
    SBCPUThermalNotifLevelDeviceRestart   = 9,
    SBCPUThermalNotifLevelReady           = 10,

    SBCPUThermalNotifLevelUnknown         = 999
};

// ============================================================================
// 系统通知名称
// ============================================================================
// kOSThermalNotificationPressureLevelName (系统导出符号)
// 实际值: "com.apple.system.thermalpressurelevel"
__OSX_AVAILABLE_STARTING(__MAC_10_10, __IPHONE_7_0)
extern const char *const kOSThermalNotificationPressureLevelName;

// ============================================================================
// 获取热压力字符串描述
// ============================================================================
static inline const char *SBCPUThermalPressureString(SBCPUThermalPressureLevel pressure) {
    switch (pressure) {
        case SBCPUThermalPressureLevelNominal:  return "Nominal";
        case SBCPUThermalPressureLevelLight:    return "Light";
        case SBCPUThermalPressureLevelModerate: return "Moderate";
        case SBCPUThermalPressureLevelHeavy:    return "Heavy";
        case SBCPUThermalPressureLevelTrapping: return "Trapping";
        case SBCPUThermalPressureLevelSleeping: return "Sleeping";
        default:                              return "Unknown";
    }
}

// ============================================================================
// 获取当前热压力级别
// 移植自 Battman thermal.c -> thermal_pressure()
// ============================================================================
static inline SBCPUThermalPressureLevel SBCPUThermalGetPressureLevel(void) {
    int token;
    uint64_t level;

    if (notify_register_check(kOSThermalNotificationPressureLevelName, &token)) {
        return SBCPUThermalPressureLevelError;
    }
    if (notify_get_state(token, &level)) {
        notify_cancel(token);
        return SBCPUThermalPressureLevelError;
    }
    notify_cancel(token);

    if (level == 0)
        return SBCPUThermalPressureLevelNominal;

    if (level < 10) {
        // macOS 风格 (1-4)
        switch (level) {
            case 1:  return SBCPUThermalPressureLevelModerate;
            case 2:  return SBCPUThermalPressureLevelHeavy;
            case 3:  return SBCPUThermalPressureLevelTrapping;
            case 4:  return SBCPUThermalPressureLevelSleeping;
            default: return SBCPUThermalPressureLevelUnknown;
        }
    } else {
        // iOS 风格 (10-50)
        switch (level) {
            case 10: return SBCPUThermalPressureLevelLight;
            case 20: return SBCPUThermalPressureLevelModerate;
            case 30: return SBCPUThermalPressureLevelHeavy;
            case 40: return SBCPUThermalPressureLevelTrapping;
            case 50: return SBCPUThermalPressureLevelSleeping;
            default: return SBCPUThermalPressureLevelUnknown;
        }
    }
}

// ============================================================================
// 强制设置热压力级别
// 移植自 Battman thermal.c -> set_thermal_pressure()
//
// 通过 notify_set_state + notify_post 直接修改系统热压力通知状态，
// 所有监听 kOSThermalNotificationPressureLevelName 的组件都会收到变化。
// ============================================================================
static inline int SBCPUThermalSetPressureLevel(SBCPUThermalPressureLevel pressure) {
    uint64_t level = 0;
    uint64_t currentLevel = UINT64_MAX;
    int token = 0;

    if (notify_register_check(kOSThermalNotificationPressureLevelName, &token))
        return -1; // 不支持

    // iOS 风格编码 (10, 20, 30, 40, 50)
    switch (pressure) {
        case SBCPUThermalPressureLevelLight:    level = 10; break;
        case SBCPUThermalPressureLevelModerate: level = 20; break;
        case SBCPUThermalPressureLevelHeavy:    level = 30; break;
        case SBCPUThermalPressureLevelTrapping: level = 40; break;
        case SBCPUThermalPressureLevelSleeping: level = 50; break;
        default:                              level = 0;  break; // Nominal
    }

    // 状态未变化时不重复广播，避免唤醒所有热状态监听者。
    if (notify_get_state(token, &currentLevel) == 0 && currentLevel == level) {
        notify_cancel(token);
        return 0;
    }
    if (notify_set_state(token, level)) {
        notify_cancel(token);
        return 1; // 设置失败
    }

    if (notify_post(kOSThermalNotificationPressureLevelName)) {
        notify_cancel(token);
        return 2; // 设置成功但通知发送失败
    }

    notify_cancel(token);
    return 0;
}

// ============================================================================
// 强制热压力为 Nominal（一键调用）
// ============================================================================
static inline int SBCPUThermalForceNominalPressure(void) {
    return SBCPUThermalSetPressureLevel(SBCPUThermalPressureLevelNominal);
}

// ============================================================================
// 读取最大触发温度（thermalmonitord 设置的值）
// 移植自 Battman thermal.c -> thermal_max_trigger_temperature()
// 单位：摄氏度
// ============================================================================
static inline float SBCPUThermalGetMaxTriggerTemperature(void) {
    int token;
    uint64_t level;

    if (notify_register_check("com.apple.system.maxthermalsensorvalue", &token))
        return -1.0f;
    if (notify_get_state(token, &level)) {
        notify_cancel(token);
        return -1.0f;
    }
    notify_cancel(token);

    return (float)level / 100.0f;
}

// ============================================================================
// 读取阳光暴露状态
// 移植自 Battman thermal.c -> thermal_solar_state()
// 返回值: 0=无暴露, 1=车窗暴露, 2=直接阳光暴露
// ============================================================================
static inline int SBCPUThermalGetSolarState(void) {
    int token;
    uint64_t level;

    if (notify_register_check("com.apple.system.thermalsunlightstate", &token))
        return 0;
    if (notify_get_state(token, &level)) {
        notify_cancel(token);
        return 0;
    }
    notify_cancel(token);

    return (int)level;
}

// ============================================================================
// 热通知级别控制（通过 dlopen 调用私有 SPI）
// 移植自 Battman thermal.c
// ============================================================================

// 动态解析热通知函数
static inline void *SBCPUThermalLoadThermalNotificationLib(void) {
    static void *handle = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        handle = dlopen("/System/Library/PrivateFrameworks/ThermalNotification.framework/ThermalNotification", RTLD_NOW | RTLD_LOCAL);
        if (!handle) {
            // 回退: 可能在 libSystem 中
            handle = dlopen("/usr/lib/libThermalNotification.dylib", RTLD_NOW | RTLD_LOCAL);
        }
    });
    return handle;
}

// 获取当前热通知级别
static inline int SBCPUThermalGetCurrentNotifLevel(void) {
    static int (*func)(void) = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *handle = SBCPUThermalLoadThermalNotificationLib();
        if (handle) {
            func = (int (*)(void))dlsym(handle, "OSThermalNotificationCurrentLevel");
        }
    });
    if (!func) return -1;
    return func();
}

// 获取指定行为的热通知级别
static inline int SBCPUThermalNotifLevelForBehavior(int behavior) {
    static int (*func)(int) = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *handle = SBCPUThermalLoadThermalNotificationLib();
        if (handle) {
            func = (int (*)(int))dlsym(handle, "_OSThermalNotificationLevelForBehavior");
        }
    });
    if (!func) return -1;
    return func(behavior);
}

// 设置指定行为的热通知级别
static inline void SBCPUThermalSetNotifLevelForBehavior(int level) {
    static void (*func)(int) = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *handle = SBCPUThermalLoadThermalNotificationLib();
        if (handle) {
            func = (void (*)(int))dlsym(handle, "_OSThermalNotificationSetLevelForBehavior");
        }
    });
    if (func) {
        func(level);
    }
}

// 获取当前通知级别对应的枚举值
static inline SBCPUThermalNotifLevel SBCPUThermalGetNotifLevel(void) {
    int rawLevel = SBCPUThermalGetCurrentNotifLevel();
    if (rawLevel < 0) return SBCPUThermalNotifLevelUnknown;

    // 查询所有已知行为对应的通知级别
    for (int i = 0; i < SBCPUThermalNotifLevelUnknown; i++) {
        if (SBCPUThermalNotifLevelForBehavior(i) == rawLevel)
            return (SBCPUThermalNotifLevel)i;
    }

    return SBCPUThermalNotifLevelUnknown;
}

// 强制热通知级别为 Normal
static inline void SBCPUThermalForceNormalNotifLevel(void) {
    int token = 0;
    uint64_t currentLevel = UINT64_MAX;
    if (notify_register_check("com.apple.system.thermalnotification", &token) == 0) {
        if (notify_get_state(token, &currentLevel) != 0 || currentLevel != 0) {
            notify_set_state(token, 0);  // Normal
            notify_post("com.apple.system.thermalnotification");
        }
        notify_cancel(token);
    }
}

// ============================================================================
// 组合调用：同时强制压力 Nominal + 通知 Normal
// ============================================================================
static inline void SBCPUThermalForceNominalCombined(void) {
    SBCPUThermalForceNominalPressure();
    SBCPUThermalForceNormalNotifLevel();
}

// ============================================================================
// 热压力检查 & 日志（用于调试）
// ============================================================================
static inline void SBCPUThermalLogPressureStatus(void) {
    SBCPUThermalPressureLevel pressure = SBCPUThermalGetPressureLevel();
    float maxTemp = SBCPUThermalGetMaxTriggerTemperature();
    int solarState = SBCPUThermalGetSolarState();
    int notifLevel = SBCPUThermalGetCurrentNotifLevel();

    NSLog(@"[SBCPUThermalPressure] 压力=%s(%ld) 最高触发温度=%.1f°C 阳光暴露=%d 通知级别=%d",
          SBCPUThermalPressureString(pressure), (long)pressure,
          maxTemp, solarState, notifLevel);
}

#endif /* CPUTHERMAL_THERMAL_PRESSURE_H */
