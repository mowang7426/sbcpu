// SBCPUChargePowerSource.h — IOPMPowerSource 事件监听（daemon 专用）
// 参照 Battman pmnotification.c：IOServiceAddMatchingNotification 订阅电池状态变化。
// 事件驱动：不做每秒轮询；daemon 启动时主动触发一次当前电量判断。

#ifndef SBCPU_CHARGE_POWER_SOURCE_H
#define SBCPU_CHARGE_POWER_SOURCE_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// 电池事件回调
typedef void (*SBCPUPowerEventCallback)(int batteryPercent, bool charging, bool wireless, double temperatureC);

// 订阅 IOPMPowerSource 事件；回调在通知到达时同步执行（run loop 上下文）
void sb_power_subscribe(SBCPUPowerEventCallback cb);

// 把 IOKit 通知源挂到 daemon 主 run loop（iOS 标准模式）；返回 source
CFRunLoopSourceRef sb_power_runloop_source(void);

// 启动时主动读取一次当前电量并立即触发回调（launchd 拉起后不等事件）
void sb_power_poll_once(void);

// 读取当前电量（0-100，读失败返回 -1）
int  sb_power_read_percent(void);

// 当前是否接入外部电源（CHCE）
bool sb_power_external_connected(void);

// 当前是否无线充电（适配器端口 2）
bool sb_power_wireless(void);

#ifdef __cplusplus
}
#endif

#endif /* SBCPU_CHARGE_POWER_SOURCE_H */
