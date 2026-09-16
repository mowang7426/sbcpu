// SBCPUChargeDaemon.m — SBCPU 充电控制 root daemon（Charge Engine V1）
// 架构：launchd 以 root 拉起 → AppleSMC(带 entitlements) + IOPMPowerSource 事件
//       → SBCPUChargeEngine 状态机 → 写 CH0C/CH0I。
// 监听 unix socket 供 SpringBoard(Tweak) 下发配置/手动控制/查询。
// 防多开：flock 锁文件。事件驱动，不做每秒轮询。

#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/stat.h>
#import <sys/file.h>
#import <pwd.h>
#import <errno.h>
#import <signal.h>
#import <unistd.h>
#import <fcntl.h>
#import <pthread.h>
#include "SBCPUChargeProtocol.h"
#include "SBCPUChargeSMC.h"
#include "SBCPUChargePowerSource.h"
#include "SBCPUChargeEngine.h"

// ================= 日志（写文件便于用户诊断） =================
static void sb_log(NSString *msg) {
    NSLog(@"[SBCPUChargeDaemon] %@", msg);
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

// ================= 防多开：flock 锁 =================
static int gLockFD = -1;
static bool acquire_singleton(void) {
    // 确保目录存在
    [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/mobile/Library/Preferences"
                              withIntermediateDirectories:YES attributes:nil error:nil];
    int fd = open(SB_DAEMON_LOCK_PATH, O_CREAT | O_RDWR, 0644);
    if (fd < 0) {
        sb_log([NSString stringWithFormat:@"open lock failed: %s", strerror(errno)]);
        return false;
    }
    if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
        sb_log(@"another daemon instance is running; exiting");
        close(fd);
        return false;
    }
    gLockFD = fd;
    return true;
}

// ================= 电池事件 → 引擎 =================
static void power_event_cb(int pct, bool charging, bool wireless) {
    // 事件到达即决策（不依赖浮窗/SpringBoard）
    sb_engine_decide(pct, charging, wireless);
}

// ================= Socket 命令处理 =================
static void handle_client(int fd) {
    sb_cmd_t cmd;
    ssize_t n = read(fd, &cmd, sizeof(cmd));
    if (n != (ssize_t)sizeof(cmd)) return;

    sb_resp_t resp = {0};
    resp.magic = SB_MAGIC;
    resp.result = SB_RESULT_IO_ERROR;
    resp.value = 0;

    if (cmd.magic != SB_MAGIC) {
        resp.result = SB_RESULT_IO_ERROR;
        write(fd, &resp, sizeof(resp));
        return;
    }

    switch (cmd.cmd) {
        case SB_CMD_PING: {
            resp.result = SB_RESULT_OK;
            resp.value = sb_engine_smc_available() ? 1 : 0;
            break;
        }
        case SB_CMD_SET_CHARGE: { // 手动阻止充电
            int r = sb_engine_manual_charge_block(cmd.value != 0);
            resp.result = r;
            resp.value = sb_engine_charge_blocked() ? 1 : 0;
            break;
        }
        case SB_CMD_SET_POWER: { // 手动阻止外部供电
            int r = sb_engine_manual_power_block(cmd.value != 0);
            resp.result = r;
            resp.value = sb_engine_power_blocked() ? 1 : 0;
            break;
        }
        case SB_CMD_GET_CHARGE: {
            resp.result = SB_RESULT_OK;
            resp.value = sb_engine_charge_blocked() ? 1 : 0;
            break;
        }
        case SB_CMD_GET_POWER: {
            resp.result = SB_RESULT_OK;
            resp.value = sb_engine_power_blocked() ? 1 : 0;
            break;
        }
        case SB_CMD_SET_LIMITS: {
            // 读取载荷并写入偏好（engine 下次决策自动生效）
            sb_limits_t lim;
            ssize_t rn = read(fd, &lim, sizeof(lim));
            if (rn != (ssize_t)sizeof(lim)) {
                resp.result = SB_RESULT_IO_ERROR;
                break;
            }
            NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:@SB_PREF_FILE];
            if (!d) d = [NSMutableDictionary dictionary];
            d[@"smartChargeEnable"] = @(lim.smartChargeEnabled ? YES : NO);
            d[@"chargeLimitEnabled"] = @(lim.chargeLimitEnabled ? YES : NO);
            d[@"smartChargeUpperLimit"] = @(lim.upperLimit);
            d[@"smartChargeLowerLimit"] = @(lim.lowerLimit);
            d[@"chargeKeepAC"] = @((lim.drainMode & 1) ? YES : NO);
            d[@"chargeOverrideOBC"] = @((lim.drainMode & 2) ? YES : NO);
            d[@"blockChargingEnable"] = @(lim.manualChargeBlock ? YES : NO);
            d[@"blockPowerEnable"] = @(lim.manualPowerBlock ? YES : NO);
            d[@"chargeScheduleEnabled"] = @(lim.scheduleEnabled ? YES : NO);
            [d writeToFile:@SB_PREF_FILE atomically:YES];
            sb_log([NSString stringWithFormat:@"limits set: smart=%d upper=%d lower=%d keepAC=%d obc=%d",
                lim.smartChargeEnabled, lim.upperLimit, lim.lowerLimit,
                (lim.drainMode & 1) != 0, (lim.drainMode & 2) != 0]);
            // 立即重新决策
            sb_engine_redecide();
            resp.result = SB_RESULT_OK;
            break;
        }
        case SB_CMD_GET_LIMITS: {
            SBCPUChargeConfig cfg;
            bool ok = sb_engine_load_config(&cfg);
            resp.result = ok ? SB_RESULT_OK : SB_RESULT_IO_ERROR;
            write(fd, &resp, sizeof(resp));
            if (ok) {
                sb_limits_t lim = {0};
                lim.smartChargeEnabled = cfg.smartChargeEnabled;
                lim.chargeLimitEnabled = cfg.chargeLimitEnabled;
                lim.upperLimit = cfg.upperLimit;
                lim.lowerLimit = cfg.lowerLimit;
                lim.drainMode = (cfg.keepAC ? 1 : 0) | (cfg.overrideOBC ? 2 : 0);
                lim.manualChargeBlock = cfg.manualChargeBlock;
                lim.manualPowerBlock = cfg.manualPowerBlock;
                lim.scheduleEnabled = cfg.scheduleEnabled;
                write(fd, &lim, sizeof(lim));
            }
            return; // 已写 resp
        }
        case SB_CMD_REDECIDE: {
            sb_engine_redecide();
            resp.result = SB_RESULT_OK;
            break;
        }
        case SB_CMD_GET_STATUS: {
            sb_status_t st = {0};
            st.engineState = (uint8_t)sb_engine_state();
            st.batteryPercent = sb_engine_battery_percent();
            st.chargeBlocked = sb_engine_charge_blocked();
            st.powerBlocked = sb_engine_power_blocked();
            st.daemonRunning = 1;
            st.smcAvailable = sb_engine_smc_available();
            st.charging = smc_external_connected();
            st.wireless = sb_engine_wireless();
            SBCPUChargeConfig cfg;
            if (sb_engine_load_config(&cfg)) {
                st.upperLimit = cfg.upperLimit;
                st.lowerLimit = cfg.lowerLimit;
            }
            st.obcTaken = sb_engine_obc_taken();
            resp.result = SB_RESULT_OK;
            resp.value = st.engineState;
            write(fd, &resp, sizeof(resp));
            write(fd, &st, sizeof(st));
            return;
        }
        case SB_CMD_STOP: {
            sb_log(@"STOP requested; reset SMC and exit");
            sb_engine_shutdown();
            resp.result = SB_RESULT_OK;
            write(fd, &resp, sizeof(resp));
            // 清锁后退出
            if (gLockFD >= 0) {
                flock(gLockFD, LOCK_UN);
                close(gLockFD);
                gLockFD = -1;
            }
            exit(0);
        }
        default:
            resp.result = SB_RESULT_IO_ERROR;
            break;
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
    // root:mobile 0660；SpringBoard(mobile) 在 mobile 组，可连可读写
    chmod(SB_SOCKET_PATH, 0660);
    // 保险：确保 mobile 能连（0660 + mobile 组）
    struct passwd *pw = getpwnam("mobile");
    if (pw) chown(SB_SOCKET_PATH, 0, pw->pw_gid);

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
        if (!acquire_singleton()) return 0;
        sb_log(@"===== SBCPUChargeDaemon starting =====");

        // 引擎初始化：打开 SMC + 读配置 + 启动即决策
        sb_engine_init();

        // 事件驱动：订阅电池变化，通知源挂主 run loop
        sb_power_subscribe(power_event_cb);

        // socket 服务线程
        pthread_t tid;
        if (pthread_create(&tid, NULL, socket_server, NULL) != 0) {
            sb_log(@"failed to create socket thread");
        }
        pthread_detach(tid);

        // 主线程跑 CFRunLoop：电源事件在此派发（iOS 无 IONotificationPortSetDispatchQueue）
        CFRunLoopSourceRef src = sb_power_runloop_source();
        if (src) {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, kCFRunLoopCommonModes);
        }
        CFRunLoopRun(); // 常驻（launchd KeepAlive 兜底）
        return 1; // 不可达：异常退出让 launchd 重启
    }
    return 0;
}
