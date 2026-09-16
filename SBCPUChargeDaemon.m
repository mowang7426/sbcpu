// SBCPUChargeDaemon — SBCPUFloating 充电控制 root daemon
// 以 root 运行（launchd + ldid 签名带 AppleSMC entitlements），
// 监听 unix socket，替 SpringBoard 执行 AppleSMC CH0C/CH0I 写入。
// 架构参照 Battman：独立 daemon 才有权打开 AppleSMC。

#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/stat.h>
#import <errno.h>
#import <signal.h>
#import <unistd.h>
#import <fcntl.h>
#import <pthread.h>

// ================= SMC 层（与 Tweak.xm 同构） =================
typedef struct SMCKeyInfoData {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t dataAttributes;
} SMCKeyInfoData;

typedef struct SMCParamStruct {
    uint32_t key;
    struct SMCParam {
        uint8_t vers;
        uint8_t pLimitData[16];
        SMCKeyInfoData keyInfo;
        uint8_t result;
        uint8_t status;
        uint8_t data8;
        uint32_t data32;
        unsigned char bytes[120];
    } param;
} SMCParamStruct;

static io_connect_t gSMCConn = 0;

enum {
    kSMCUserClientOpen,
    kSMCUserClientClose,
    kSMCHandleYPCEvent,
    kSMCReadKey = 5,
    kSMCWriteKey = 6,
    kSMCGetKeyInfo = 9
};

static IOReturn smc_init(void) {
    if (gSMCConn != 0) return kIOReturnSuccess;
    mach_port_t masterPort = 0;
    if (IOMasterPort(MACH_PORT_NULL, &masterPort) != kIOReturnSuccess)
        return kIOReturnNotOpen;
    io_service_t service = IOServiceGetMatchingService(masterPort, IOServiceMatching("AppleSMC"));
    if (service == IO_OBJECT_NULL)
        return kIOReturnNotFound;
    IOReturn result = IOServiceOpen(service, mach_task_self(), 0, &gSMCConn);
    IOObjectRelease(service);
    if (result != kIOReturnSuccess) {
        gSMCConn = 0;
        return result;
    }
    return kIOReturnSuccess;
}

static IOReturn smc_call(int index, SMCParamStruct *input, SMCParamStruct *output) {
    if (gSMCConn == 0) {
        IOReturn r = smc_init();
        if (r != kIOReturnSuccess) return r;
    }
    size_t inSize = sizeof(SMCParamStruct);
    size_t outSize = sizeof(SMCParamStruct);
    return IOConnectCallStructMethod(gSMCConn, index, input, inSize, output, &outSize);
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

static IOReturn smc_read(uint32_t key, void *bytes, int32_t *size) {
    SMCParamStruct in = {0};
    SMCParamStruct out = {0};
    in.key = key;
    IOReturn r = smc_get_keyinfo(key, &in.param.keyInfo);
    if (r != kIOReturnSuccess) return r;
    if (*size < (int32_t)in.param.keyInfo.dataSize)
        *size = (int32_t)in.param.keyInfo.dataSize;
    in.param.data8 = kSMCReadKey;
    r = smc_call(kSMCHandleYPCEvent, &in, &out);
    if (r != kIOReturnSuccess) return r;
    memcpy(bytes, out.param.bytes, *size);
    return kIOReturnSuccess;
}

static IOReturn smc_write(uint32_t key, void *bytes, uint32_t size) {
    SMCParamStruct in = {0};
    SMCParamStruct out = {0};
    IOReturn r = smc_get_keyinfo(key, &in.param.keyInfo);
    if (r != kIOReturnSuccess) return r;
    if (in.param.keyInfo.dataSize > size) return -1;
    in.param.data8 = kSMCWriteKey;
    in.key = key;
    memcpy(in.param.bytes, bytes, in.param.keyInfo.dataSize);
    return smc_call(kSMCHandleYPCEvent, &in, &out);
}

// CH0C=停充(保留AC), CH0I=阻止外部供电；写前安全检查（外部连接 + VBUS）
static IOReturn set_charge_block(BOOL inhibit, BOOL overrideOBC) {
    uint8_t chce = 0;
    int32_t sz = 1;
    if (smc_read('CHCE', &chce, &sz) != kIOReturnSuccess) return kIOReturnIOError;
    if (!chce) return kIOReturnNotReady;

    uint32_t ch0r = 0;
    int32_t sz4 = 4;
    if (smc_read('CH0R', &ch0r, &sz4) == kIOReturnSuccess && (ch0r & (1 << 1)))
        return kIOReturnNotReady;

    uint8_t cur = 0;
    int32_t sz1 = 1;
    if (smc_read('CH0C', &cur, &sz1) != kIOReturnSuccess) return kIOReturnIOError;
    BOOL obcTaken = NO;
    if (cur & (1 << 1)) {
        if (overrideOBC) {
            smc_write('CH0B', &inhibit, 1);
        } else {
            obcTaken = YES;
        }
    }
    if (inhibit != (cur & 1)) {
        IOReturn r = smc_write('CH0C', &inhibit, 1);
        if (r != kIOReturnSuccess) return r;
    }
    return obcTaken ? kIOReturnCannotLock : kIOReturnSuccess;
}

static IOReturn set_power_block(BOOL inhibit, BOOL overrideOBC) {
    uint8_t chce = 0;
    int32_t sz = 1;
    if (smc_read('CHCE', &chce, &sz) != kIOReturnSuccess) return kIOReturnIOError;
    if (!chce) return kIOReturnNotReady;

    uint32_t ch0r = 0;
    int32_t sz4 = 4;
    if (smc_read('CH0R', &ch0r, &sz4) == kIOReturnSuccess && (ch0r & (1 << 1)))
        return kIOReturnNotReady;

    uint8_t cur = 0;
    int32_t sz1 = 1;
    if (smc_read('CH0I', &cur, &sz1) != kIOReturnSuccess) return kIOReturnIOError;
    if (cur & (1 << 1)) {
        if (!overrideOBC) return kIOReturnCannotLock;
    }
    if (inhibit != (cur & 1)) {
        IOReturn r = smc_write('CH0I', &inhibit, 1);
        if (r != kIOReturnSuccess) return r;
    }
    return kIOReturnSuccess;
}

static BOOL get_charge_blocked(void) {
    uint8_t v = 0;
    int32_t sz = 1;
    if (smc_read('CH0C', &v, &sz) == kIOReturnSuccess)
        return (v & 1) != 0;
    return NO;
}

static BOOL get_power_blocked(void) {
    uint8_t v = 0;
    int32_t sz = 1;
    if (smc_read('CH0I', &v, &sz) == kIOReturnSuccess)
        return (v & 1) != 0;
    return NO;
}

// ================= Socket 协议 =================
#define SB_MAGIC 0x53424350 // 'SBCP'
typedef struct {
    uint32_t magic;
    uint8_t  cmd;    // 1=setCharge 2=setPower 3=getCharge 4=getPower 5=ping
    uint8_t  value;  // set 时 0/1
    uint16_t pad;
} sb_cmd_t;

typedef struct {
    uint32_t magic;
    int32_t  result; // 0 成功，否则 IOReturn 负值/错误码
    uint8_t  value;  // get 时返回状态
    uint8_t  pad[3];
} sb_resp_t;

enum {
    SB_CMD_SET_CHARGE = 1,
    SB_CMD_SET_POWER  = 2,
    SB_CMD_GET_CHARGE = 3,
    SB_CMD_GET_POWER  = 4,
    SB_CMD_PING       = 5
};

#define SB_SOCKET_PATH "/var/mobile/Library/Preferences/sbcpu_charge.sock"

static void sb_log(NSString *msg) {
    NSLog(@"[SBCPUChargeDaemon] %@", msg);
    // 同时写文件，便于用户诊断（/var/mobile 对 mobile/root 都可写）
    @try {
        NSString *line = [NSString stringWithFormat:@"[%@] %@\n",
            [NSDate date], msg];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:@"/var/mobile/Library/Preferences/sbcpu_charge.log"];
        if (!fh) {
            [[NSFileManager defaultManager] createFileAtPath:@"/var/mobile/Library/Preferences/sbcpu_charge.log" contents:nil attributes:nil];
            fh = [NSFileHandle fileHandleForWritingAtPath:@"/var/mobile/Library/Preferences/sbcpu_charge.log"];
        }
        if (fh) {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    } @catch (NSException *e) {}
}

static void handle_client(int fd) {
    sb_cmd_t cmd;
    ssize_t n = read(fd, &cmd, sizeof(cmd));
    if (n != (ssize_t)sizeof(cmd)) return;

    sb_resp_t resp = {0};
    resp.magic = SB_MAGIC;
    resp.result = -1;
    resp.value = 0;

    if (cmd.magic != SB_MAGIC) {
        resp.result = kIOReturnBadArgument;
    } else {
        switch (cmd.cmd) {
            case SB_CMD_SET_CHARGE: {
                resp.result = set_charge_block(cmd.value != 0, NO);
                resp.value = (uint8_t)get_charge_blocked();
                break;
            }
            case SB_CMD_SET_POWER: {
                resp.result = set_power_block(cmd.value != 0, NO);
                resp.value = (uint8_t)get_power_blocked();
                break;
            }
            case SB_CMD_GET_CHARGE: {
                resp.result = 0;
                resp.value = (uint8_t)get_charge_blocked();
                break;
            }
            case SB_CMD_GET_POWER: {
                resp.result = 0;
                resp.value = (uint8_t)get_power_blocked();
                break;
            }
            case SB_CMD_PING: {
                resp.result = 0;
                resp.value = (gSMCConn != 0);
                break;
            }
            default:
                resp.result = kIOReturnBadArgument;
                break;
        }
    }
    write(fd, &resp, sizeof(resp));
}

static void *socket_server(void *arg) {
    (void)arg;
    unlink(SB_SOCKET_PATH);

    int sfd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (sfd < 0) {
        sb_log([NSString stringWithFormat:@"socket() failed: %s", strerror(errno)]);
        return NULL;
    }

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, SB_SOCKET_PATH, sizeof(addr.sun_path) - 1);

    if (bind(sfd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        sb_log([NSString stringWithFormat:@"bind() failed: %s", strerror(errno)]);
        close(sfd);
        return NULL;
    }
    // SpringBoard(mobile) 需要能连接
    chmod(SB_SOCKET_PATH, 0666);

    if (listen(sfd, 8) < 0) {
        sb_log([NSString stringWithFormat:@"listen() failed: %s", strerror(errno)]);
        close(sfd);
        return NULL;
    }

    sb_log(@"socket server listening");
    for (;;) {
        int cfd = accept(sfd, NULL, NULL);
        if (cfd < 0) {
            if (errno == EINTR) continue;
            sb_log([NSString stringWithFormat:@"accept() failed: %s", strerror(errno)]);
            continue;
        }
        handle_client(cfd);
        close(cfd);
    }
    return NULL;
}

int main(int argc, char *argv[]) {
    (void)argc; (void)argv;
    signal(SIGPIPE, SIG_IGN);
    signal(SIGCHLD, SIG_IGN);

    @autoreleasepool {
        sb_log(@"starting...");

        IOReturn r = smc_init();
        if (r != kIOReturnSuccess) {
            sb_log([NSString stringWithFormat:@"AppleSMC open failed: 0x%x", r]);
        } else {
            sb_log(@"AppleSMC opened OK");
        }

        // 保持 SMC 连接常驻，同时开 socket 服务线程
        pthread_t tid;
        if (pthread_create(&tid, NULL, socket_server, NULL) != 0) {
            sb_log(@"failed to create socket thread");
        }
        pthread_detach(tid);

        // 主线程常驻
        for (;;) {
            sleep(3600);
        }
    }
    return 0;
}
