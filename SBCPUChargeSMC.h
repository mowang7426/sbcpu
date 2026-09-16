// SBCPUChargeSMC.h — AppleSMC 读写层（daemon 专用，root 运行）
// 参照 Battman libsmc.c：SMCParamStruct / IOConnectCallStructMethod。
// 提供：打开/关闭、读写、安全检查(CHCE/CH0R)、OBC 处理、写缓存。

#ifndef SBCPU_CHARGE_SMC_H
#define SBCPU_CHARGE_SMC_H

#include <stdint.h>
#include <stdbool.h>
#include <IOKit/IOReturn.h>

#ifdef __cplusplus
extern "C" {
#endif

// 打开 AppleSMC（需 root + com.apple.private.applesmc.user-access entitlement）
IOReturn smc_open(void);
void     smc_close(void);
bool     smc_is_open(void);

// 底层读写（size 为实际字节数；CH0C/CH0I 为 1 字节，CH0R 为 4 字节）
IOReturn smc_read_key(uint32_t key, void *bytes, int32_t *size);
IOReturn smc_write_key(uint32_t key, const void *bytes, uint32_t size);

// 充电控制（写前安全检查：CHCE 外部连接 + CH0R No-VBUS）
// inhibit: 1=停充/断供；overrideOBC: 1=强制覆盖 OBC（写 CH0B + 关闭 topoff）
// 返回 0 成功；负值 IOReturn；正值见 SB_RESULT_* 语义（SB_RESULT_OBC_TAKEN 等）
int  smc_set_charge_block(bool inhibit, bool overrideOBC);
int  smc_set_power_block(bool inhibit, bool overrideOBC);

// 读实际状态（bit0）
bool smc_get_charge_blocked(void);
bool smc_get_power_blocked(void);

// 外部电源是否连接（CHCE）
bool smc_external_connected(void);

// 当前是否 OBC 托管（读 CH0C/CH0I bit1）
bool smc_obc_taken_charge(void);
bool smc_obc_taken_power(void);

// 复位：恢复 CH0C/CH0I = 允许（卸载/停用时调用）
IOReturn smc_reset_all(void);

#ifdef __cplusplus
}
#endif

#endif /* SBCPU_CHARGE_SMC_H */
