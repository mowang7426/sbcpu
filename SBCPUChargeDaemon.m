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
#import <CoreFoundation/CoreFoundation.h>
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
static void power_event_cb(int pct, bool charging, bool wireless, double temperatureC) {
    // 事件到达即决策（不依赖浮窗/SpringBoard）
    sb_engine_decide(pct, charging, wireless, temperatureC);
}

// ================= Socket 命令处理 =================
// Unix SOCK_STREAM 不保证一次 read/write 传完整结构体，统一用全量读写
static bool read_full(int fd, void *buf, size_t len) {
    size_t done = 0;
    while (done < len) {
        ssize_t n = read(fd, (uint8_t *)buf + done, len - done);
        if (n <= 0) {
            if (n < 0 && errno == EINTR) continue;
            return false;
        }
        done += (size_t)n;
    }
    return true;
}

static bool write_full(int fd, const void *buf, size_t len) {
    size_t done = 0;
    while (done < len) {
        ssize_t n = write(fd, (const uint8_t *)buf + done, len - done);
        if (n <= 0) {
            if (n < 0 && errno == EINTR) continue;
            return false;
        }
        done += (size_t)n;
    }
    return true;
}

static bool authorized_client(int fd) {
    uid_t peerUID = (uid_t)-1;
    gid_t peerGID = (gid_t)-1;
    if (getpeereid(fd, &peerUID, &peerGID) != 0) return false;
    if (peerUID == 0) return true;
    struct passwd *mobile = getpwnam("mobile");
    return mobile && peerUID == mobile->pw_uid;
}

static void handle_client(int fd) {
    if (!authorized_client(fd)) return;
    sb_cmd_t cmd;
    if (!read_full(fd, &cmd, sizeof(cmd))) return;

    sb_resp_t resp = {0};
    resp.magic = SB_MAGIC;
    resp.result = SB_RESULT_IO_ERROR;
    resp.value = 0;

    if (cmd.magic != SB_MAGIC) {
        resp.result = SB_RESULT_IO_ERROR;
        write_full(fd, &resp, sizeof(resp));
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
            if (!read_full(fd, &lim, sizeof(lim))) {
                resp.result = SB_RESULT_IO_ERROR;
                break;
            }
            int prefLock = open(SB_PREF_WRITE_LOCK_PATH, O_CREAT | O_RDWR, 0644);
            if (prefLock >= 0) flock(prefLock, LOCK_EX);
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
            d[@"smartThermalChargeEnable"] = @(lim.smartThermalEnabled ? YES : NO);
            d[@"smartThermalUpperC"] = @(lim.thermalUpperC);
            d[@"smartThermalLowerC"] = @(lim.thermalLowerC);
            [d writeToFile:@SB_PREF_FILE atomically:YES];
            if (prefLock >= 0) { flock(prefLock, LOCK_UN); close(prefLock); }
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
            write_full(fd, &resp, sizeof(resp));
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
                lim.smartThermalEnabled = cfg.smartThermalEnabled;
                lim.thermalUpperC = cfg.thermalUpperC;
                lim.thermalLowerC = cfg.thermalLowerC;
                write_full(fd, &lim, sizeof(lim));
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
            st.version = SB_DAEMON_VERSION;
            st.lastSMCError = smc_last_error();
            resp.result = SB_RESULT_OK;
            resp.value = st.engineState;
            write_full(fd, &resp, sizeof(resp));
            write_full(fd, &st, sizeof(st));
            return;
        }
        case SB_CMD_STOP: {
            // STOP 会执行 SMC 复位并退出，只允许 root/launchd 侧使用。
            uid_t peerUID = (uid_t)-1;
            gid_t peerGID = (gid_t)-1;
            if (getpeereid(fd, &peerUID, &peerGID) != 0 || peerUID != 0) {
                resp.result = SB_RESULT_IO_ERROR;
                break;
            }
            sb_log(@"STOP requested by root; reset SMC and exit");
            sb_engine_shutdown();
            resp.result = SB_RESULT_OK;
            write_full(fd, &resp, sizeof(resp));
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
    write_full(fd, &resp, sizeof(resp));
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

// 信号处理器只设置标志；不在异步信号上下文调用 CFRunLoopStop。
// 主循环通过短周期 timer 观察标志并执行 SMC 复位。
static volatile sig_atomic_t gShouldExit = 0;
static void sbcpu_on_term(int sig) {
    (void)sig;
    gShouldExit = 1;
}

static void signal_watchdog_cb(CFRunLoopTimerRef timer, void *info) {
    (void)timer; (void)info;
    if (gShouldExit) CFRunLoopStop(CFRunLoopGetMain());
}

// 兜底 watchdog：IOKit 电源通知事件驱动不可用时，10 秒轮询一次仍保证充电控制工作，
// 同时保证主 runloop 有事件源不会立即返回（否则 daemon 秒退、launchd 反复重启）
static void poll_watchdog_cb(CFRunLoopTimerRef timer, void *info) {
    (void)timer; (void)info;
    sb_power_poll_once();
}

int main(int argc, char *argv[]) {
    signal(SIGPIPE, SIG_IGN);
    signal(SIGCHLD, SIG_IGN);
    signal(SIGTERM, sbcpu_on_term);
    signal(SIGINT, sbcpu_on_term);

    // 最早期诊断（不依赖锁/目录）：确认 launchd 是否真的拉起了本进程、身份与版本
    NSLog(@"[SBCPUChargeDaemon] launched uid=%d euid=%d ver=%d argv=%s",
          (int)getuid(), (int)geteuid(), SB_DAEMON_VERSION, argc > 0 ? argv[0] : "(null)");

    @autoreleasepool {
        if (!acquire_singleton()) {
            // 另一个实例仍持锁时，报告失败；KeepAlive 会继续观察，
            // 避免异常残留导致 daemon 永久消失。
            return 1;
        }
        sb_log([NSString stringWithFormat:@"===== daemon starting uid=%d euid=%d ver=%d argv=%s =====",
                (int)getuid(), (int)geteuid(), SB_DAEMON_VERSION, argc > 0 ? argv[0] : "?"]);
        // 已取得单例锁，旧 socket 只能是异常残留；清理后再创建服务。
        unlink(SB_SOCKET_PATH);

        // 引擎初始化：打开 SMC + 读配置 + 启动即决策（SMC 失败也继续，保持 socket 存活）
        sb_engine_init();

        // 事件驱动：订阅电池变化，通知源挂主 run loop
        sb_power_subscribe(power_event_cb);

        // socket 服务线程
        pthread_t tid;
        int threadResult = pthread_create(&tid, NULL, socket_server, NULL);
        if (threadResult == 0) {
            pthread_detach(tid);
        } else {
            sb_log([NSString stringWithFormat:@"failed to create socket thread: %s", strerror(threadResult)]);
        }

        // 主线程跑 CFRunLoop：电源事件在此派发（iOS 无 IONotificationPortSetDispatchQueue）
        CFRunLoopSourceRef src = sb_power_runloop_source();
        if (src) {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, kCFRunLoopCommonModes);
        }
        // 兜底 watchdog：无论如何主 runloop 都有常驻 timer（10s），
        // 避免 IOKit 通知不可用时 CFRunLoopRun 因无事件源立即返回导致 daemon 秒退。
        CFRunLoopTimerRef wdt = CFRunLoopTimerCreate(kCFAllocatorDefault,
            CFAbsoluteTimeGetCurrent() + 5.0, 10.0, 0, 0,
            (CFRunLoopTimerCallBack)poll_watchdog_cb, NULL);
        if (wdt) {
            CFRunLoopAddTimer(CFRunLoopGetMain(), wdt, kCFRunLoopCommonModes);
            CFRelease(wdt);
        }
        CFRunLoopTimerRef sigTimer = CFRunLoopTimerCreate(kCFAllocatorDefault,
            CFAbsoluteTimeGetCurrent() + 0.25, 0.25, 0, 0,
            (CFRunLoopTimerCallBack)signal_watchdog_cb, NULL);
        if (sigTimer) {
            CFRunLoopAddTimer(CFRunLoopGetMain(), sigTimer, kCFRunLoopCommonModes);
            CFRelease(sigTimer);
        }
        CFRunLoopRun(); // 常驻（launchd KeepAlive 兜底）

        // runloop 被信号停止：优雅复位充电状态后正常退出（卸载/升级场景）
        if (gShouldExit) {
            sb_log(@"SIGTERM received; resetting CH0C/CH0I then exit");
            sb_engine_shutdown();
            unlink(SB_SOCKET_PATH);
            if (gLockFD >= 0) { flock(gLockFD, LOCK_UN); close(gLockFD); gLockFD = -1; }
            return 0; // 成功退出，KeepAlive(SuccessfulExit=false) 不重启
        }
        return 1; // 不可达：异常退出让 launchd 重启
    }
}
