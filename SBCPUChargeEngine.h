// SBCPUChargeEngine.h — 充电状态机（daemon 专用）
// 职责：读偏好配置 → 按优先级决策 → 经 SMC 层写 CH0C/CH0I。
// 完全独立于 SpringBoard 浮窗：浮窗关闭、SpringBoard 重启都不影响。

#ifndef SBCPU_CHARGE_ENGINE_H
#define SBCPU_CHARGE_ENGINE_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// 引擎状态（对外可读）
typedef enum {
    SBCPUChargeStateUnknown      = 0,
    SBCPUChargeStateCharging     = 1,  // 正常充电（未限制）
    SBCPUChargeStateBlocked      = 2,  // 已停充/已断供
    SBCPUChargeStateOBCControlled = 3, // OBC 托管（未强制覆盖）
    SBCPUChargeStateNoPower      = 4,  // 未接外部电源
    SBCPUChargeStateUnsupported  = 5,  // 无线充电等不支持场景
    SBCPUChargeStateError        = 6
} SBCPUChargeState;

// 引擎配置（与偏好一一对应）
typedef struct {
    bool smartChargeEnabled;   // 智能充电总开关
    bool chargeLimitEnabled;   // 充电限制开关（V1 与智能充电同源）
    uint8_t upperLimit;        // 停充上限 %
    uint8_t lowerLimit;        // 回充下限 %
    bool keepAC;               // drain_config bit0：保留外部供电（只停充不切断 AC）
    bool overrideOBC;          // drain_config bit1：强制覆盖 OBC
    bool manualChargeBlock;    // 手动阻止充电（优先级最高）
    bool manualPowerBlock;     // 手动阻止外部供电
    bool scheduleEnabled;      // 充电计划（V1 预留）
    bool smartThermalEnabled;  // 智能温度停充
    uint8_t thermalUpperC;     // 温度上限 °C
    uint8_t thermalLowerC;     // 温度下限 °C
} SBCPUChargeConfig;

// 引擎初始化/收尾
void sb_engine_init(void);
void sb_engine_shutdown(void);   // 恢复充电并停止

// 读配置（从偏好文件）；返回是否成功
bool sb_engine_load_config(SBCPUChargeConfig *cfg);

// 核心决策：根据电量/电源状态执行一次状态机（事件驱动入口）
// pct: 0-100；charging: 是否接入外部电源；wireless: 是否无线充电
void sb_engine_decide(int pct, bool charging, bool wireless, double temperatureC);

// 立即重读配置并决策（配置变化后调用）
void sb_engine_redecide(void);

// 手动控制（直接覆盖状态机；随后状态机会按配置重新收敛）
int sb_engine_manual_charge_block(bool block);
int sb_engine_manual_power_block(bool block);

// 查询状态
SBCPUChargeState sb_engine_state(void);
uint8_t sb_engine_battery_percent(void);
bool sb_engine_charge_blocked(void);
bool sb_engine_power_blocked(void);
bool sb_engine_smc_available(void);
bool sb_engine_obc_taken(void);
bool sb_engine_wireless(void);

#ifdef __cplusplus
}
#endif

#endif /* SBCPU_CHARGE_ENGINE_H */
