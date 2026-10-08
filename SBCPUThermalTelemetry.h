// Logging only. No control writes/notifications, no changes to hook signatures.
#import "include/SBCPUTelemetryFormat.h"
#include <sys/stat.h>
#include <errno.h>
#import "include/SBCPUWriterStatus.h"

enum { TPressure, TSleep, TWake, TRecovery, TApply, TDecision, TNotification, TPressureNotification, TDisplay, TInit, TCommonCPU, TMitigationCPU, TSensors, TRouteCount };
static const char *TNames[] = {"热压力评估", "锁屏降功耗", "唤醒恢复", "正常温度恢复", "运行模式应用", "决策树", "高温通知", "热压力通知", "IOKit 单属性写入（背光分支分类）", "构造初始化", "CommonProduct CPU", "MitigationController CPU", "HID温度事件"};
static _Atomic(uint64_t) TCounts[TRouteCount], TLastNS[TRouteCount];
static _Atomic(int) TDecisions[TRouteCount];
static _Atomic(bool) TPending = false;
static _Atomic(uint64_t) TGeneration = 0;
static dispatch_queue_t TQueue;
static NSDictionary *TLoaded;
static NSString *TLoadStatus = @"尚未读取", *TSession;
static uint64_t TRevision, TSequence, TSeen[TRouteCount];
static double TLoadWall, TLastSuccessWall;
static BOOL TLastLoadSucceeded;
static NSMutableArray *TEvents;
static void TSchedule(void);
static void TNote(int route, int decision) {
    if (route < 0 || route >= TRouteCount) return;
    if (route == TInit && decision == 0) SBCTWriterPublish(SBCTHello, 0, 0);
    atomic_fetch_add_explicit(&TCounts[route], 1, memory_order_relaxed);
    atomic_store_explicit(&TDecisions[route], decision, memory_order_relaxed);
    atomic_store_explicit(&TLastNS[route], (uint64_t)(SBCTMono() * 1e9), memory_order_relaxed);
    atomic_fetch_add_explicit(&TGeneration, 1, memory_order_relaxed);
    TSchedule();
}
static dispatch_queue_t TGetQueue(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        TQueue = dispatch_queue_create("com.sbcpu.thermal.telemetry", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
        TSession = NSUUID.UUID.UUIDString; TEvents = [NSMutableArray array];
    });
    return TQueue;
}
static void TSet(int route, int decision) {
    if (route < 0 || route >= TRouteCount) return;
    atomic_store_explicit(&TDecisions[route], decision, memory_order_relaxed);
    atomic_fetch_add_explicit(&TGeneration, 1, memory_order_relaxed);
    TSchedule();
}
static void TConfig(NSDictionary *d) {
    NSDictionary *loaded = d.count ? SBCTConfig(d) : nil;
    double wall = NSDate.date.timeIntervalSince1970;
    dispatch_async(TGetQueue(), ^{
        TLoadWall = wall;
        TLoadStatus = loaded ? @"读取成功" : @"读取失败或空配置；沿用内存状态";
        TLastLoadSucceeded = loaded != nil;
        if (loaded) { TLoaded = loaded; TRevision++; TLastSuccessWall = wall; }
    });
    atomic_fetch_add_explicit(&TGeneration, 1, memory_order_relaxed);
    TSchedule();
}
// Failed reads retain the last successfully loaded revision and the live state.
static void TFailedConfig(NSDictionary *d) {
    if (!d || d.count == 0) TConfig(nil);
}
// Results describe control-flow evidence only, never measured thermal/hardware effects.
static NSString *TResult(int route, int decision, uint64_t count) {
    if (!count) return @"从未触发（非失败）";
    if (decision == 4) return @"既有守卫未满足：未进入处理分支";
    if (decision == 5) return @"系统热压力读取失败：沿用既有早退";
    if (route == TPressure) {
        if (decision == 1) return @"已进入严重热压力分支（是否切换见覆盖标志）";
        if (decision == 2) return @"已进入正常压力分支（恢复仍受既有条件约束）";
        if (decision == 3) return @"极限满频既有分支：未主动接管低功耗";
        if (decision == 6) return @"已读取压力；未进入严重/正常压力分支";
    }
    if (route == TSleep && decision == 2) return @"已为低功耗：未改变模式枚举";
    if (route == TApply && decision == 2) return @"已进入全功率模式应用路径（效果未知）";
    if (route == TApply && decision == 1) return @"已进入低功耗模式应用路径（效果未知）";
    if (route == TInit && decision == 1) return @"既有构造注册阶段已完成；单项安装以 IMP 证据为准";
    return decision == 1 ? @"已观察到既有处理分支（效果未知）" : decision == 2 ? @"已观察到原始参数放行分支（效果未知）" : @"已调用（结果未分类；效果未知）";
}
static NSDictionary *THook(NSString *cls, NSString *selector, int route) {
    Class c = objc_getClass(cls.UTF8String);
    Method method = c ? class_getInstanceMethod(c, NSSelectorFromString(selector)) : NULL;
    Dl_info info = {0};
    BOOL own = NO;
    if (method && dladdr((void *)method_getImplementation(method), &info) && info.dli_fname) {
        const char *base = strrchr(info.dli_fname, '/');
        own = strcmp(base ? base + 1 : info.dli_fname, "SBCPUThermal.dylib") == 0;
    }
    uint64_t count = (route >= 0 && route < TRouteCount) ? atomic_load_explicit(&TCounts[route], memory_order_relaxed) : 0;
    double calledAt = (route >= 0 && route < TRouteCount) ? atomic_load_explicit(&TLastNS[route], memory_order_relaxed) / 1e9 : 0;
    int result = (route >= 0 && route < TRouteCount) ? atomic_load_explicit(&TDecisions[route], memory_order_relaxed) : -1;
    NSString *resultLabel = TResult(route, result, count);
    return @{ @"class":cls, @"selector":selector, @"classPresent":@(c != Nil), @"methodPresent":@(method != NULL),
              @"implementationInCore":@(own),
              @"evidence":own ? @"当前 IMP 的 dladdr 镜像归属 SBCPUThermal.dylib；不是仅凭类名推断" : @"无法从当前 IMP 确认注册；类/方法存在不代表已安装",
              @"installation": own ? @"安装已确认" : (method ? @"仅类方法存在" : @"不支持/未找到"),
              @"called":@(count > 0), @"callCount":@(count), @"lastCalledMono":@(calledAt),
              @"result":resultLabel };
}
// Runs on main only to sample main-owned runtime flags. Locks cover their existing domains;
// no I/O under a lock or on main. This is a sampled report, not a transaction across domains.
static NSDictionary *TRuntime(void) {
    os_unfair_lock_lock(&g_stateLock);
    BOOL enabled = g_enabled, cpu = g_cpuProtection, network = g_blockNetworkThermalThrottle;
    BOOL popup = g_thermalBlockNotifPopup, dimming = g_thermalPreventDimmingEnabled;
    BOOL pressureProtection = g_thermalPressureAutoProtectionEnabled;
    BOOL recovery = g_thermalNominalAutoRecoveryEnabled, sleep = g_lockScreenLowPowerEnabled;
    os_unfair_lock_unlock(&g_stateLock);
    os_unfair_lock_lock(&g_modeLock);
    int selected = g_userSelectedPowerMode, effective = g_powerMode;
    os_unfair_lock_unlock(&g_modeLock);
    // Only primitive reads under the existing locks; no ObjC allocation, scheduling or I/O.
    NSMutableDictionary *r = [@{@"enabled":@(enabled), @"cpuProtection":@(cpu), @"blockNetwork":@(network), @"blockPopup":@(popup), @"preventDimming":@(dimming), @"pressureProtection":@(pressureProtection), @"nominalRecovery":@(recovery), @"lockScreenLowPower":@(sleep)} mutableCopy];
    r[@"selected"] = @(selected); r[@"effective"] = @(effective);
    NSArray *modeNames = @[@"fullPower", @"lowPower", @"extremeFull"];
    r[@"selectedMode"] = selected >= 0 && selected < (int)modeNames.count ? modeNames[selected] : @"unknown";
    r[@"effectiveMode"] = effective >= 0 && effective < (int)modeNames.count ? modeNames[effective] : @"unknown";
    r[@"bootSettled"] = @(bootSettled()); r[@"pressure"] = @(g_currentPressureLevel);
    r[@"pressureOverride"] = @(g_pressureSafetyOverride);
    r[@"locked"] = @(SBCPUThermalScreenIsLocked());
    r[@"blanked"] = @(SBCPUThermalScreenIsBlanked());
    r[@"nominalSince"] = @(g_pressureNominalSince);
    r[@"reason"] = !enabled ? @"总开关关闭：原生控制路径" : !bootSettled() ? @"启动静默期（个别显式应用可不受启动守卫限制）" : g_pressureSafetyOverride ? @"热压力安全覆盖标志为真" : effective != selected ? @"临时模式与用户模式不同；见锁屏/恢复调用记录" : @"当前枚举与用户模式一致";
    return r;
}
static void TWrite(NSDictionary *runtime, NSArray *hooks, double wall, double mono) {
    @autoreleasepool {
        NSMutableArray *routes = [NSMutableArray array];
        for (int i = 0; i < TRouteCount; i++) {
            uint64_t count = atomic_load_explicit(&TCounts[i], memory_order_relaxed);
            int decision = atomic_load_explicit(&TDecisions[i], memory_order_relaxed);
            double last = atomic_load_explicit(&TLastNS[i], memory_order_relaxed) / 1e9;
            NSDictionary *row = @{@"name":@(TNames[i]), @"count":@(count), @"lastMono":@(last), @"decision":@(decision), @"result":TResult(i, decision, count)};
            [routes addObject:row];
            if (count != TSeen[i]) {
                [TEvents addObject:@{@"wall":@(wall), @"route":@(TNames[i]), @"count":@(count), @"coalesced":@(count - TSeen[i]), @"decision":@(decision), @"lastMono":@(last), @"result":TResult(i, decision, count)}];
                TSeen[i] = count;
            }
        }
        while (TEvents.count > 80) [TEvents removeObjectAtIndex:0];
        NSDictionary *snapshot = @{ @"schema":@1, @"pid":@(getpid()), @"process":NSProcessInfo.processInfo.processName, @"boot":SBCTBoot(), @"session":TSession, @"sequence":@(++TSequence), @"wall":@(wall), @"mono":@(mono), @"runtime":runtime, @"configLoaded":@(TLoaded != nil), @"config":TLoaded ?: @{}, @"revision":@(TRevision), @"lastLoadWall":@(TLoadWall), @"lastSuccessfulLoadWall":@(TLastSuccessWall), @"lastLoadSucceeded":@(TLastLoadSucceeded), @"loadStatus":TLoadStatus ?: @"未知", @"hooks":hooks, @"routes":routes, @"events":[TEvents copy]};
        NSData *data = [NSPropertyListSerialization dataWithPropertyList:snapshot format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
        if (!data || data.length > 131072) {
            SBCTWriterPublish(data ? SBCTOversize : SBCTSerialize, 0, TSequence);
            return;
        }
        NSString *path = SBCPUThermalTelemetryPath();
        NSString *tmp = [path stringByAppendingFormat:@".%d.%@.tmp", getpid(), TSession];
        int fd = open(tmp.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
        if (fd < 0) { SBCTWriterPublish(SBCTOpen, errno, TSequence); return; }
        unsigned code = SBCTSuccess;
        int savedError = 0;
        if (fchown(fd, 0, 501) != 0) { code = SBCTOwner; savedError = errno; }
        if (code == SBCTSuccess && fchmod(fd, 0640) != 0) { code = SBCTMode; savedError = errno; }
        const char *p = data.bytes; size_t remaining = data.length;
        while (code == SBCTSuccess && remaining) {
            ssize_t n = write(fd, p, remaining);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) { code = SBCTWrite; savedError = n < 0 ? errno : EIO; break; }
            p += n; remaining -= n;
        }
        // Keep the first failure: cleanup may overwrite errno.
        if (close(fd) != 0 && code == SBCTSuccess) { code = SBCTClose; savedError = errno; }
        if (code == SBCTSuccess && rename(tmp.fileSystemRepresentation, path.fileSystemRepresentation) != 0) { code = SBCTRename; savedError = errno; }
        unlink(tmp.fileSystemRepresentation);
        SBCTWriterPublish(code, savedError, TSequence);
    }
}
static void TSchedule(void) {
    bool expected = false;
    if (!atomic_compare_exchange_strong_explicit(&TPending, &expected, true, memory_order_relaxed, memory_order_relaxed)) return;
    // One delayed task for any number of frequent calls; no per-call queue backlog.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        uint64_t generation = atomic_load_explicit(&TGeneration, memory_order_relaxed);
        NSDictionary *runtime = TRuntime();
        NSArray *hooks = @[THook(@"ThermalManager", @"evaluateDecisionTree", TDecision), THook(@"ThermalManager", @"updateThermalNotification:", TNotification), THook(@"ThermalManager", @"updateThermalPressureLevelNotification:shouldForceThermalPressure:", TPressureNotification), THook(@"MitigationController", @"setCPULevel:", TMitigationCPU), THook(@"CommonProduct", @"setCPULevel:", TCommonCPU), THook(@"HidSensors", @"handleTemperatureEvent:service:", TSensors)];
        double wall = NSDate.date.timeIntervalSince1970, mono = SBCTMono();
        dispatch_async(TGetQueue(), ^{
            TWrite(runtime, hooks, wall, mono);
            atomic_store_explicit(&TPending, false, memory_order_relaxed);
            // An event arriving during sampling/I/O must get a final coalesced snapshot.
            if (atomic_load_explicit(&TGeneration, memory_order_relaxed) != generation) TSchedule();
        });
    });
}
