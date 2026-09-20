// SBCPUChargeProtocol.h — SBCPUFloating 充电控制协议（Tweak ↔ SBCPUChargeDaemon 共用）
// 架构：SpringBoard(Tweak) 只负责 UI/配置下发；SBCPUChargeDaemon(root) 负责
//       AppleSMC(CH0C/CH0I) + IOPMPowerSource 事件 + 迟滞状态机（Charge Engine）。
// 本头文件只含 C 结构/枚举，Tweak.xm 与 daemon 各文件均可安全 include。

#ifndef SBCPU_CHARGE_PROTOCOL_H
#define SBCPU_CHARGE_PROTOCOL_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------- 路径（roothide 与 rootful 均可访问；mobile 可写可读） ----------
#define SB_SOCKET_PATH          "/var/mobile/Library/Preferences/sbcpu_charge.sock"
#define SB_DAEMON_LOG_PATH      "/var/mobile/Library/Preferences/sbcpu_charge.log"
#define SB_DAEMON_LOCK_PATH     "/var/mobile/Library/Preferences/sbcpu_charge.lock"
// 与 daemon 单例锁分离：用于 mobile 设置页与 root daemon 的配置读改写互斥。
#define SB_PREF_WRITE_LOCK_PATH "/var/mobile/Library/Preferences/sbcpu_charge_prefs.lock"
#define SB_PREF_DOMAIN          "com.yourname.sbcpufloating"
#define SB_PREF_FILE            "/var/mobile/Library/Preferences/com.yourname.sbcpufloating.plist"

#define SB_MAGIC                0x53424350 // 'SBCP'
#define SB_DAEMON_VERSION       4          // V4.41：daemon 自愈、SMC 恢复与协议校验

// ---------- 命令（V1 扩展） ----------
enum {
    SB_CMD_PING            = 1,   // 心跳；value 返回 SMC 可用(1)/不可用(0)
    SB_CMD_SET_CHARGE      = 2,   // 手动阻止充电；value=0/1
    SB_CMD_SET_POWER       = 3,   // 手动阻止外部供电；value=0/1
    SB_CMD_GET_CHARGE      = 4,   // 读 CH0C 实际停充状态
    SB_CMD_GET_POWER       = 5,   // 读 CH0I 实际断供状态
    SB_CMD_SET_LIMITS      = 6,   // 下发智能充电配置（后跟 sb_limits_t）
    SB_CMD_GET_LIMITS      = 7,   // 读当前配置
    SB_CMD_REDECIDE        = 8,   // 立即读取电池并重新执行状态机
    SB_CMD_GET_STATUS      = 9,   // 读 daemon 状态（后跟 sb_status_t）
    SB_CMD_STOP            = 10   // 停止 daemon 并复位 SMC（卸载/禁用用）
};

// ---------- 基础消息 ----------
typedef struct {
    uint32_t magic;
    uint8_t  cmd;
    uint8_t  value;   // 简单命令参数
    uint16_t pad;
} sb_cmd_t; // 8 字节

typedef struct {
    uint32_t magic;
    int32_t  result;  // 0 成功；负值 = IOReturn；正值 = 自定义状态(见下)
    uint8_t  value;   // 简单返回值
    uint8_t  pad[3];
} sb_resp_t; // 12 字节

// ---------- 写入结果语义（result 正值） ----------
enum {
    SB_RESULT_OK              = 0,
    SB_RESULT_BUSY            = 1,  // 设备忙/无法完全接管
    SB_RESULT_OBC_TAKEN       = 2,  // 请求已发，但 OBC 托管（未强制覆盖）
    SB_RESULT_SMC_UNAVAILABLE = 3,  // AppleSMC 打不开
    SB_RESULT_NO_EXTERNAL_POWER = 4, // 未接外部电源
    SB_RESULT_UNSUPPORTED     = 5,  // 无线充电等不支持场景
    SB_RESULT_IO_ERROR        = 6
};

// ---------- SET_LIMITS 载荷（紧随 sb_cmd_t 后发送） ----------
typedef struct {
    uint8_t  smartChargeEnabled;  // 智能充电总开关
    uint8_t  chargeLimitEnabled;  // 充电限制开关（与智能充电同源，V1 合并）
    uint8_t  upperLimit;          // 停充上限 %
    uint8_t  lowerLimit;          // 回充下限 %
    uint8_t  drainMode;           // bit0=keep_ac(保留外部供电) bit1=override_obc(覆盖OBC)
    uint8_t  manualChargeBlock;   // 手动阻止充电（优先级最高）
    uint8_t  manualPowerBlock;    // 手动阻止外部供电
    uint8_t  scheduleEnabled;     // 充电计划开关（V1 预留，默认关）
    uint8_t  smartThermalEnabled; // 智能温度停充
    uint8_t  thermalUpperC;        // 温度上限 °C
    uint8_t  thermalLowerC;        // 温度下限 °C
} sb_limits_t; // 11 字节

// ---------- GET_STATUS 载荷（紧随 sb_resp_t 后发送） ----------
typedef struct {
    uint8_t  engineState;         // SBCPUChargeState
    uint8_t  batteryPercent;      // 当前电量 %
    uint8_t  chargeBlocked;       // CH0C 实际位
    uint8_t  powerBlocked;        // CH0I 实际位
    uint8_t  daemonRunning;       // 恒 1（能连上即运行中）
    uint8_t  smcAvailable;        // AppleSMC 是否打开
    uint8_t  charging;            // 是否接入外部电源（CHCE）
    uint8_t  wireless;            // 无线充电检测（port==2）
    uint8_t  upperLimit;
    uint8_t  lowerLimit;
    uint8_t  obcTaken;            // 当前是否 OBC 托管
    uint8_t  version;             // daemon 协议版本（SB_DAEMON_VERSION）
    int32_t  lastSMCError;        // 最近一次 SMC 调用的原始 IOReturn（0=无错误）
} sb_status_t; // 16 字节

#ifdef __cplusplus
}
#endif

#endif /* SBCPU_CHARGE_PROTOCOL_H */
