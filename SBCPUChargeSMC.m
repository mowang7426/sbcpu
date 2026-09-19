// SBCPUChargeSMC.m — AppleSMC 读写层实现（daemon 专用，root 运行）
// 关键语义（Battman daemon.c 注释）：
//   CH0C bit0: 电池充电开关（不影响 AC）；bit1: OBC 已接管充电
//   CH0I bit0: 外部供电流入开关；bit1: OBC/无 VBUS
//   CH0B: OBC managed charging；CH0J/CH0K: OBC managed AC
//   CH0R bit1: No VBUS（无外部供电时禁止写）
//   CHCE: ExternalConnected（也反映流入状态）
// 写前安全检查 + 只在实际状态变化时写入（缓存），避免无谓 SMC 写入。

#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <notify.h>
#include <pwd.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include "SBCPUChargeSMC.h"
#include "SBCPUChargeProtocol.h"

typedef struct SMCVersion {
    uint8_t  major;
    uint8_t  minor;
    uint8_t  build;
    uint16_t release;
} SMCVersion;

typedef struct SMCPLimitData {
    uint16_t version;
    uint16_t length;
    uint32_t cpuPLimit;
    uint32_t gpuPLimit;
    uint32_t memPLimit;
} SMCPLimitData;

typedef struct SMCKeyInfoData {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t  dataAttributes;
} SMCKeyInfoData;

/*
 * AppleSMC's user-client struct is ABI-sensitive. Battman uses the 168-byte
 * arm64 layout (bytes[120]); the previous SBCPU struct used a 164-byte
 * substitute layout by making `vers` a single byte. That makes every field
 * after `vers` land at the wrong offset and AppleSMC rejects the call with
 * kIOReturnBadArgument (0xe00002c2). Keep this layout byte-for-byte compatible
 * with Battman's libsmc implementation.
 */
typedef struct SMCParamStruct {
    uint32_t key;
    struct SMCParam {
        SMCVersion vers;
        SMCPLimitData pLimitData;
        SMCKeyInfoData keyInfo;
        uint8_t  result;
        uint8_t  status;
        uint8_t  data8;
        uint32_t data32;
        unsigned char bytes[120];
    } param;
} SMCParamStruct;

_Static_assert(sizeof(SMCParamStruct) == 168, "AppleSMC ABI must be 168 bytes");

enum {
    kSMCUserClientOpen,
    kSMCUserClientClose,
    kSMCHandleYPCEvent,
    kSMCReadKey = 5,
    kSMCWriteKey = 6,
    kSMCGetKeyInfo = 9
};

static io_connect_t gSMCConn = 0;
// 写缓存：只有状态真正变化才写 SMC（Battman CH0CCache/CH0ICache 思路）
static int gChargeCache = -1;
static int gPowerCache = -1;
// 最近一次 SMC 调用的原始 IOReturn（诊断用，0=成功）
static int32_t gLastSMCError = 0;

int32_t smc_last_error(void) { return gLastSMCError; }

IOReturn smc_open(void) {
    if (gSMCConn != 0) return kIOReturnSuccess;
    mach_port_t masterPort = 0;
    IOReturn mr = IOMasterPort(MACH_PORT_NULL, &masterPort);
    if (mr != kIOReturnSuccess) { gLastSMCError = mr; return mr; }
    io_service_t service = IOServiceGetMatchingService(masterPort, IOServiceMatching("AppleSMC"));
    if (service == IO_OBJECT_NULL) { gLastSMCError = kIOReturnNotFound; return kIOReturnNotFound; }
    IOReturn result = IOServiceOpen(service, mach_task_self(), 0, &gSMCConn);
    IOObjectRelease(service);
    if (result != kIOReturnSuccess) {
        gSMCConn = 0;
        gLastSMCError = result;   // 关键：权限不足时这里通常是 kIOReturnNotPermitted
        return result;
    }
    gChargeCache = -1;
    gPowerCache = -1;
    gLastSMCError = 0;
    return kIOReturnSuccess;
}

void smc_close(void) {
    if (gSMCConn != 0) {
        IOServiceClose(gSMCConn);
        gSMCConn = 0;
    }
}

bool smc_is_open(void) {
    return gSMCConn != 0;
}

static IOReturn smc_call(int index, SMCParamStruct *input, SMCParamStruct *output) {
    if (gSMCConn == 0) {
        IOReturn r = smc_open();
        if (r != kIOReturnSuccess) { gLastSMCError = r; return r; }
    }
    size_t inSize = sizeof(SMCParamStruct);
    size_t outSize = sizeof(SMCParamStruct);
    IOReturn r = IOConnectCallStructMethod(gSMCConn, index, input, inSize, output, &outSize);
    if (r != kIOReturnSuccess) gLastSMCError = r;
    return r;
}

static IOReturn smc_get_keyinfo(uint32_t key, SMCKeyInfoData *keyInfo) {
    SMCParamStruct in = {0};
    SMCParamStruct out = {0};
    in.key = key;
    in.param.data8 = kSMCGetKeyInfo;
    IOReturn r = smc_call(kSMCHandleYPCEvent, &in, &out);
    if (r == kIOReturnSuccess && out.param.keyInfo.dataSize == 0)
        r = kIOReturnError;
    if (r == kIOReturnSuccess && keyInfo)
        *keyInfo = out.param.keyInfo;
    return r;
}

IOReturn smc_read_key(uint32_t key, void *bytes, int32_t *size) {
    if (!size || *size < 0) return kIOReturnBadArgument;

    SMCParamStruct in = {0};
    SMCParamStruct out = {0};
    in.key = key;

    IOReturn r = smc_get_keyinfo(key, &in.param.keyInfo);
    if (r != kIOReturnSuccess) return r;

    uint32_t dataSize = in.param.keyInfo.dataSize;
    if (dataSize == 0 || dataSize > sizeof(out.param.bytes)) {
        return kIOReturnBadArgument;
    }

    // The caller owns the destination buffer. Never enlarge *size and then
    // memcpy past that buffer: several SMC keys are larger than 1 byte.
    if ((uint32_t)*size < dataSize || (dataSize > 0 && !bytes)) {
        *size = (int32_t)dataSize;
        return kIOReturnNoSpace;
    }

    in.param.data8 = kSMCReadKey;
    r = smc_call(kSMCHandleYPCEvent, &in, &out);
    if (r != kIOReturnSuccess) return r;

    memcpy(bytes, out.param.bytes, dataSize);
    *size = (int32_t)dataSize;
    return kIOReturnSuccess;
}

IOReturn smc_write_key(uint32_t key, const void *bytes, uint32_t size) {
    SMCParamStruct in = {0};
    SMCParamStruct out = {0};
    IOReturn r = smc_get_keyinfo(key, &in.param.keyInfo);
    if (r != kIOReturnSuccess) return r;
    uint32_t dataSize = in.param.keyInfo.dataSize;
    if (dataSize == 0 || dataSize > sizeof(in.param.bytes)) return kIOReturnBadArgument;
    if (dataSize > size || (dataSize > 0 && !bytes)) return kIOReturnBadArgument;
    in.param.data8 = kSMCWriteKey;
    in.key = key;
    memcpy(in.param.bytes, bytes, dataSize);
    r = smc_call(kSMCHandleYPCEvent, &in, &out);
    if (r != kIOReturnSuccess) return r;
    /* IOConnectCallStructMethod can succeed while the SMC firmware rejects
       the command; result==0 is the SMC-level success value. */
    if (out.param.result != 0) {
        gLastSMCError = kIOReturnError;
        NSLog(@"[SBCPUChargeSMC] SMC rejected write key=0x%08x result=0x%02x", key, out.param.result);
        return kIOReturnError;
    }
    return kIOReturnSuccess;
}

bool smc_external_connected(void) {
    uint8_t chce = 0;
    int32_t sz = 1;
    if (smc_read_key('CHCE', &chce, &sz) != kIOReturnSuccess) return false;
    return chce != 0;
}

bool smc_obc_taken_charge(void) {
    uint8_t v = 0;
    int32_t sz = 1;
    if (smc_read_key('CH0C', &v, &sz) == kIOReturnSuccess)
        return (v & (1 << 1)) != 0;
    return false;
}

bool smc_obc_taken_power(void) {
    uint8_t v = 0;
    int32_t sz = 1;
    if (smc_read_key('CH0I', &v, &sz) == kIOReturnSuccess)
        return (v & (1 << 1)) != 0;
    return false;
}

// 关闭 iOS 优化电池充电（OBC topoff protection），让 CH0C 写不被系统抢回
static bool obc_switch(bool on) {
    // Match Battman's safe OBC preference path: temporarily drop to mobile so
    // CFPreferences writes the mobile user's domain rather than root's domain.
    struct passwd *pw = getpwnam("mobile");
    if (!pw) return false;

    uid_t orig_euid = geteuid();
    gid_t orig_egid = getegid();
    bool ok = false;

    if (setegid(pw->pw_gid) != 0) {
        return false;
    }
    if (seteuid(pw->pw_uid) != 0) {
        (void)setegid(orig_egid);
        return false;
    }

    CFStringRef domain = CFSTR("com.apple.smartcharging.topoffprotection");
    CFStringRef key = CFSTR("enabled");
    int onValue = on ? 1 : 0;
    CFNumberRef value = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &onValue);
    if (value) {
        CFPreferencesSetValue(key, value, domain,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        CFRelease(value);
        ok = CFPreferencesSynchronize(domain,
                                      kCFPreferencesCurrentUser,
                                      kCFPreferencesAnyHost);
        if (!ok) {
            ok = CFPreferencesAppSynchronize(domain);
        }
        if (ok) {
            notify_post("com.apple.smartcharging.defaultschanged");
        }
    }

    // Always restore daemon credentials before returning.
    if (seteuid(orig_euid) != 0) ok = false;
    if (setegid(orig_egid) != 0) ok = false;
    return ok;
}

int smc_set_charge_block(bool inhibit, bool overrideOBC) {
    uint8_t cur = 0;
    int32_t sz = 1;

    /*
     * IMPORTANT: release is a different safety class from inhibit.
     *
     * When CH0C/CH0I is actively forcing a charging state, the SMC can report
     * CH0R.bit1 (No VBUS) even though a physical charger is still attached.
     * The old code rejected *both* set and clear operations when that bit was
     * set, which could strand the device in a blocked state.
     *
     * Clearing our own inhibit bit is the recovery operation and must be
     * allowed even when CHCE/CH0R temporarily describe the current power flow
     * as unavailable. This matches Battman's restore path, which writes zero
     * directly to CH0C/CH0I.
     */
    if (!inhibit) {
        if (smc_read_key('CH0C', &cur, &sz) != kIOReturnSuccess) {
            NSLog(@"[SBCPUChargeSMC] read CH0C for recovery failed 0x%08x", smc_last_error());
            return SB_RESULT_IO_ERROR;
        }
        uint8_t zero = 0;
        if ((cur & 1) || gChargeCache != 0) {
            IOReturn r = smc_write_key('CH0C', &zero, 1);
            if (r != kIOReturnSuccess) {
                NSLog(@"[SBCPUChargeSMC] recovery write CH0C=0 failed 0x%08x", smc_last_error());
                return SB_RESULT_IO_ERROR;
            }
        }
        gChargeCache = 0;
        return SB_RESULT_OK;
    }

    // 安全：只有在真正准备“阻止充电”时，才要求外部电源/VBUS存在。
    uint8_t chce = 0;
    if (smc_read_key('CHCE', &chce, &sz) != kIOReturnSuccess) {
        NSLog(@"[SBCPUChargeSMC] read CHCE failed 0x%08x", smc_last_error());
        return SB_RESULT_IO_ERROR;
    }
    if (!chce) return SB_RESULT_NO_EXTERNAL_POWER;

    uint32_t ch0r = 0;
    int32_t sz4 = 4;
    if (smc_read_key('CH0R', &ch0r, &sz4) == kIOReturnSuccess && (ch0r & (1 << 1)))
        return SB_RESULT_NO_EXTERNAL_POWER;

    if (smc_read_key('CH0C', &cur, &sz) != kIOReturnSuccess) {
        NSLog(@"[SBCPUChargeSMC] read CH0C failed 0x%08x", smc_last_error());
        return SB_RESULT_IO_ERROR;
    }

    // OBC 已接管充电：不强制则标记 OBC 托管；强制则先关闭 OBC。
    if (cur & (1 << 1)) {
        if (!overrideOBC) return SB_RESULT_OBC_TAKEN;
        if (!obc_switch(false)) {
            NSLog(@"[SBCPUChargeSMC] failed to disable OBC before CH0C write");
            return SB_RESULT_IO_ERROR;
        }
        uint8_t obcValue = inhibit ? 1 : 0;
        IOReturn obcWrite = smc_write_key('CH0B', &obcValue, sizeof(obcValue));
        if (obcWrite != kIOReturnSuccess) {
            NSLog(@"[SBCPUChargeSMC] write CH0B=%d failed 0x%08x", inhibit, smc_last_error());
            return SB_RESULT_IO_ERROR;
        }
    }

    int target = 1;
    if (((cur & 1) != target) || gChargeCache != target) {
        uint8_t chargeValue = inhibit ? 1 : 0;
        IOReturn r = smc_write_key('CH0C', &chargeValue, sizeof(chargeValue));
        if (r != kIOReturnSuccess) {
            NSLog(@"[SBCPUChargeSMC] write CH0C=%d failed 0x%08x", inhibit, smc_last_error());
            return SB_RESULT_IO_ERROR;
        }
    }
    gChargeCache = target;
    return SB_RESULT_OK;
}

int smc_set_power_block(bool inhibit, bool overrideOBC) {
    uint8_t cur = 0;
    int32_t sz = 1;

    // 释放 CH0I 是恢复外部供电的最高优先级操作：不依赖 CHCE/CH0R。
    // CH0I=1 时系统可能把 CHCE 报成 0，因此不能用“无外部电源”阻止恢复。
    if (!inhibit) {
        if (smc_read_key('CH0I', &cur, &sz) != kIOReturnSuccess) {
            NSLog(@"[SBCPUChargeSMC] read CH0I for recovery failed 0x%08x", smc_last_error());
            return SB_RESULT_IO_ERROR;
        }
        uint8_t zero = 0;
        for (int attempt = 0; attempt < 3; ++attempt) {
            if ((cur & 1) == 0 && gPowerCache == 0) break;
            IOReturn r = smc_write_key('CH0I', &zero, 1);
            if (r != kIOReturnSuccess) {
                NSLog(@"[SBCPUChargeSMC] recovery write CH0I=0 failed 0x%08x", smc_last_error());
                return SB_RESULT_IO_ERROR;
            }
            cur = 0;
            int32_t verifySize = 1;
            if (smc_read_key('CH0I', &cur, &verifySize) == kIOReturnSuccess && (cur & 1) == 0) {
                gPowerCache = 0;
                return SB_RESULT_OK;
            }
            usleep(50000);
        }
        gPowerCache = 0;
        return ((cur & 1) == 0) ? SB_RESULT_OK : SB_RESULT_IO_ERROR;
    }

    // 先读 CH0I。如果已经是 1，说明断供已经生效；即使 CHCE=0 也应视为成功，
    // 否则 UI 会出现“未检测到外部电源”但实际上已经被断供的假错误。
    if (smc_read_key('CH0I', &cur, &sz) != kIOReturnSuccess) {
        NSLog(@"[SBCPUChargeSMC] read CH0I failed 0x%08x", smc_last_error());
        return SB_RESULT_IO_ERROR;
    }
    if (cur & 1) {
        gPowerCache = 1;
        return SB_RESULT_OK;
    }

    // 真正首次执行断供时才要求外部电源存在。
    uint8_t chce = 0;
    if (smc_read_key('CHCE', &chce, &sz) != kIOReturnSuccess) {
        NSLog(@"[SBCPUChargeSMC] read CHCE failed 0x%08x", smc_last_error());
        return SB_RESULT_IO_ERROR;
    }
    if (!chce) return SB_RESULT_NO_EXTERNAL_POWER;

    uint32_t ch0r = 0;
    int32_t sz4 = 4;
    if (smc_read_key('CH0R', &ch0r, &sz4) == kIOReturnSuccess && (ch0r & (1 << 1)))
        return SB_RESULT_NO_EXTERNAL_POWER;

    if (cur & (1 << 1)) {
        if (!overrideOBC) return SB_RESULT_OBC_TAKEN;
        if (!obc_switch(false)) {
            NSLog(@"[SBCPUChargeSMC] failed to disable OBC before CH0I write");
            return SB_RESULT_IO_ERROR;
        }
    }

    uint8_t one = 1;
    for (int attempt = 0; attempt < 3; ++attempt) {
        IOReturn r = smc_write_key('CH0I', &one, 1);
        if (r != kIOReturnSuccess) {
            NSLog(@"[SBCPUChargeSMC] write CH0I=1 failed 0x%08x", smc_last_error());
            return SB_RESULT_IO_ERROR;
        }
        uint8_t verify = 0;
        int32_t verifySize = 1;
        if (smc_read_key('CH0I', &verify, &verifySize) == kIOReturnSuccess && (verify & 1)) {
            gPowerCache = 1;
            return SB_RESULT_OK;
        }
        usleep(50000);
    }
    return SB_RESULT_IO_ERROR;
}

bool smc_get_charge_blocked(void) {
    uint8_t v = 0;
    int32_t sz = 1;
    if (smc_read_key('CH0C', &v, &sz) == kIOReturnSuccess)
        return (v & 1) != 0;
    return false;
}

bool smc_get_power_blocked(void) {
    uint8_t v = 0;
    int32_t sz = 1;
    if (smc_read_key('CH0I', &v, &sz) == kIOReturnSuccess)
        return (v & 1) != 0;
    return false;
}

IOReturn smc_reset_all(void) {
    IOReturn r1 = kIOReturnSuccess, r2 = kIOReturnSuccess;
    uint8_t zero = 0;
    if (smc_external_connected()) {
        r1 = smc_write_key('CH0C', &zero, 1);
        r2 = smc_write_key('CH0I', &zero, 1);
    }
    gChargeCache = 0;
    gPowerCache = 0;
    return (r1 == kIOReturnSuccess && r2 == kIOReturnSuccess) ? kIOReturnSuccess : kIOReturnError;
}
