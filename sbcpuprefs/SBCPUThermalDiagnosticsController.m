#import <UIKit/UIKit.h>
#import "SBCPUThermalDiagnosticsController.h"
#import <Preferences/PSSpecifier.h>
#import "../include/SBCPUThermalPaths.h"
#import "SBCPUThermalDiagnostics.h"
#import "../include/SBCPUTelemetryFormat.h"

static NSNumber *SBCDNotify(const char *name) {
    int token = -1;
    if (notify_register_check(name, &token) != NOTIFY_STATUS_OK) return nil;
    uint64_t state = 0;
    int result = notify_get_state(token, &state);
    notify_cancel(token);
    return result == NOTIFY_STATUS_OK ? @(state) : nil;
}
// Fixed paths only; bounded I/O on a utility queue, no system-log scraping.
static NSData *SBCDRead(NSString *path, NSUInteger limit, BOOL *exists) {
    *exists = [[NSFileManager defaultManager] fileExistsAtPath:path];
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) return nil;
    NSData *data = nil;
    @try { data = [handle readDataOfLength:limit + 1]; } @catch (__unused NSException *e) {}
    [handle closeFile];
    return data.length <= limit ? data : nil;
}
static void SBCDGroup(NSMutableArray *rows, NSString *title, NSString *detail) {
    PSSpecifier *group = [PSSpecifier groupSpecifierWithName:title];
    [group setProperty:detail forKey:@"footerText"];
    [rows addObject:group];
}
@interface SBCPUThermalDiagnosticsController ()
@property(nonatomic, copy) NSArray *diagnosticRows;
@property(nonatomic, strong) NSMutableArray<NSString *> *events;
@property(nonatomic, copy) NSString *previousConfiguration;
@property(nonatomic, assign) BOOL loading;
@end
@implementation SBCPUThermalDiagnosticsController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"诊断报告";
    self.events = [NSMutableArray array];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"刷新" style:UIBarButtonItemStylePlain target:self action:@selector(refreshDiagnostics)];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshDiagnostics];
}
- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *rows = [NSMutableArray arrayWithArray:self.diagnosticRows ?: @[]];
        if (!rows.count) SBCDGroup(rows, @"读取中", @"只读检测，不修改偏好、不发送控制通知、不探测或启动温控进程。");
        PSSpecifier *copy = [PSSpecifier preferenceSpecifierNamed:@"复制本页诊断与日志" target:self set:NULL get:NULL detail:Nil cell:PSButtonCell edit:nil];
        [copy setButtonAction:@selector(copyDiagnostics)];
        [rows addObject:copy];
        SBCDGroup(rows, @"本页诊断事件（最近 80 条）", self.events.count ? [[self.events reverseObjectEnumerator].allObjects componentsJoinedByString:@"\n"] : @"暂无；仅记录本页读取事件，不是核心启动日志。离开此控制器后记录不保证保留。");
        _specifiers = rows;
    }
    return _specifiers;
}
- (void)copyDiagnostics {
    NSMutableArray *text = [NSMutableArray arrayWithObject:@"运行检测与日志（只读快照；非功能生效证明）"];
    for (PSSpecifier *row in self.diagnosticRows) {
        [text addObject:row.name ?: @""];
        [text addObject:[row propertyForKey:@"footerText"] ?: @""];
    }
    [text addObjectsFromArray:self.events ?: @[]];
    UIPasteboard.generalPasteboard.string = [text componentsJoinedByString:@"\n"];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"已复制" message:@"仅包含白名单配置摘要、时间及检测结果；不包含原始路径、UUID、系统日志或个人信息。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)refreshDiagnostics {
    if (self.loading) return;
    self.loading = YES;
    self.navigationItem.rightBarButtonItem.enabled = NO;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            NSDate *date = NSDate.date;
            NSTimeInterval now = date.timeIntervalSince1970;
            NSDateFormatter *formatter = [NSDateFormatter new];
            formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss Z";
            NSString *stamp = [formatter stringFromDate:date];
            NSMutableArray *rows = [NSMutableArray array];
            NSMutableArray *events = [NSMutableArray arrayWithObject:@"刷新：完成只读快照"];
            BOOL exists = NO;
            NSData *prefData = SBCDRead(SBCPUThermalCurrentPrefPath(), 262144, &exists);
            id parsed = prefData ? [NSPropertyListSerialization propertyListWithData:prefData options:NSPropertyListImmutable format:NULL error:nil] : nil;
            BOOL readable = [parsed isKindOfClass:NSDictionary.class];
            NSDictionary *prefs = readable ? parsed : @{};
            // The core snapshot is the only source for actual runtime/config evidence.
            BOOL telemetryExists = NO;
            NSData *telemetryData = SBCDRead(SBCPUThermalTelemetryPath(), 131072, &telemetryExists);
            id telemetryObject = telemetryData ? [NSPropertyListSerialization propertyListWithData:telemetryData options:NSPropertyListImmutable format:NULL error:nil] : nil;
            NSString *telemetryState = SBCTValidate(telemetryObject, SBCTBoot(), now, SBCTMono());
            NSDictionary *telemetry = [@[@"recent", @"stale"] containsObject:telemetryState] ? telemetryObject : nil;
            if (!telemetry) [events addObject:[NSString stringWithFormat:@"核心快照：%@（不采用损坏/异次启动/未来报告）", telemetryState]];
            if (telemetry) {
                BOOL stale = [telemetryState isEqual:@"stale"];
                NSString *age = [NSString stringWithFormat:@"%.0f 秒", MAX(0, SBCTMono() - [telemetry[@"mono"] doubleValue])];
                NSString *prefix = stale ? @"上次观测（已过期；进程当前状态未知）" : @"近期观测（非实时保证）";
                NSDictionary *runtime = telemetry[@"runtime"], *config = telemetry[@"config"];
                NSString *load = [telemetry[@"configLoaded"] boolValue] ? @"曾成功读取" : @"尚未确认成功读取";
                NSString *lastRead = [telemetry[@"lastLoadSucceeded"] boolValue] ? @"上次读取成功" : @"上次读取失败；保留先前成功版本（如有）";
                NSString *successTime = [telemetry[@"lastSuccessfulLoadWall"] doubleValue] > 0 ? [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:[telemetry[@"lastSuccessfulLoadWall"] doubleValue]]] : @"无";
                SBCDGroup(rows, @"核心真实运行快照", [NSString stringWithFormat:@"%@，观测距今 %@；%@；%@（修订 %@）\n报告模式 %@；用户模式 %@；原因 %@\n总开关 %@；CPU保护 %@；锁屏降功耗 %@；热压保护 %@；常温恢复 %@；防变暗 %@；阻断弹窗 %@；网络限制 %@；热压覆盖 %@\n报告时间 %@，PID %@；仅表示上次观测，不证明硬件效果。", prefix, age, load, lastRead, telemetry[@"revision"] ?: @0, runtime[@"effectiveMode"] ?: @"未知", runtime[@"selectedMode"] ?: @"未知", runtime[@"reason"] ?: @"未知", runtime[@"enabled"] ?: @"?", runtime[@"cpuProtection"] ?: @"?", runtime[@"lockScreenLowPower"] ?: @"?", runtime[@"pressureProtection"] ?: @"?", runtime[@"nominalRecovery"] ?: @"?", runtime[@"preventDimming"] ?: @"?", runtime[@"blockPopup"] ?: @"?", runtime[@"blockNetwork"] ?: @"?", runtime[@"pressureOverride"] ?: @"?", [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:[telemetry[@"wall"] doubleValue]]], telemetry[@"pid"] ?: @"?"]);
                NSMutableArray *configLines = [NSMutableArray array];
                for (NSString *key in SBCTKeys()) [configLines addObject:[NSString stringWithFormat:@"%@: %@", key, [telemetry[@"configLoaded"] boolValue] ? (config[key] ?: @"未报告") : @"未读取"]];
                SBCDGroup(rows, @"核心上次成功加载的配置（非磁盘期望值）", [NSString stringWithFormat:@"%@；%@；上次成功读取 %@\n%@", prefix, lastRead, successTime, [configLines componentsJoinedByString:@"；"]]);
                NSMutableArray *hookLines = [NSMutableArray array];
                for (NSDictionary *hook in telemetry[@"hooks"]) [hookLines addObject:[NSString stringWithFormat:@"%@.%@：%@；调用 %@ 次；%@；%@", hook[@"class"] ?: @"?", hook[@"selector"] ?: @"?", hook[@"installation"] ?: @"未知", hook[@"callCount"] ?: @0, hook[@"result"] ?: @"未知", hook[@"evidence"] ?: @"无安装证据"]];
                SBCDGroup(rows, @"Hook 安装与调用证据", [NSString stringWithFormat:@"%@。IMP 镜像归属仅为安装证据；不保证系统效果。\n%@", prefix, [hookLines componentsJoinedByString:@"\n"]]);
                NSMutableArray *routeLines = [NSMutableArray array];
                for (NSDictionary *route in telemetry[@"routes"]) [routeLines addObject:[NSString stringWithFormat:@"%@: %@ 次；%@", route[@"name"] ?: @"?", route[@"count"] ?: @0, route[@"result"] ?: @"未知"]];
                SBCDGroup(rows, @"核心函数调用与分支结果", [NSString stringWithFormat:@"%@；未触发不代表失败。\n%@", prefix, [routeLines componentsJoinedByString:@"\n"]]);
                NSMutableArray *coreEvents = [NSMutableArray array];
                for (NSDictionary *event in [telemetry[@"events"] reverseObjectEnumerator]) [coreEvents addObject:[NSString stringWithFormat:@"%@: +%@ 次（累计 %@）；%@", event[@"route"] ?: @"?", event[@"coalesced"] ?: @0, event[@"count"] ?: @0, event[@"result"] ?: @"未知"]];
                SBCDGroup(rows, @"核心近期事件（最多 80 条）", [NSString stringWithFormat:@"%@；合并计数来自核心，不是硬件生效次数。\n%@", prefix, coreEvents.count ? [coreEvents componentsJoinedByString:@"\n"] : @"尚无调用事件"]);
            } else {
                SBCDGroup(rows, @"核心真实运行快照", [NSString stringWithFormat:@"未读取：%@；核心已读取/模式/Hook 调用均未知。路径：%@", telemetryState, telemetryExists ? @"存在但不可验证" : @"不存在"]);
            }
            // Missing current file is not migrated or substituted with a legacy copy.
            if (!readable) [events addObject:exists ? @"错误：当前偏好不可读/损坏/超限" : @"配置：当前偏好缺失（未迁移旧副本）"];
            NSMutableArray *heartbeats = [NSMutableArray array];
            NSUInteger bad = 0, future = 0, missing = 0;
            for (NSString *path in SBCPUThermalHeartbeatPaths()) {
                NSData *data = SBCDRead(path, 64, &exists);
                NSNumber *value = SBCDParseHeartbeat(data);
                if (!exists) { missing++; continue; }
                if (!value) { bad++; continue; }
                if ([SBCDHeartbeatState(value, now) isEqual:@"future"]) { future++; continue; }
                [heartbeats addObject:value];
            }
            NSNumber *notifyHeartbeat = SBCDNotify("com.yourname.sbcpufloating/thermal.engine.heartbeat");
            if (notifyHeartbeat.unsignedLongLongValue > 0) {
                if ([SBCDHeartbeatState(notifyHeartbeat, now) isEqual:@"future"]) future++;
                else [heartbeats addObject:notifyHeartbeat];
            }
            NSNumber *newest = [heartbeats valueForKeyPath:@"@max.self"];
            NSString *heartbeatState = SBCDHeartbeatState(newest, now);
            NSString *heartbeatText = @"无可用心跳；进程是否存活未知";
            if (newest) {
                NSString *last = [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:newest.doubleValue / 1000.0]];
                heartbeatText = [NSString stringWithFormat:@"%@；最后心跳 %@，距读取 %.1f 秒", [heartbeatState isEqual:@"recent"] ? @"近期收到核心心跳（≤15 秒），不是进程/功能生效证明" : @"心跳过期（>15 秒），不能断言进程已退出", last, now - newest.doubleValue / 1000.0];
            }
            SBCDGroup(rows, @"快照与核心心跳", [NSString stringWithFormat:@"读取时间：%@\n%@\n候选缺失 %lu、异常/不可读 %lu、未来时间 %lu（拒绝采用）。文件与 Darwin 通知可能处于不同路径/状态空间。无 PID 身份验证，进程存活仍未验证。", stamp, heartbeatText, (unsigned long)missing, (unsigned long)bad, (unsigned long)future]);
            [events addObject:[@"心跳：" stringByAppendingString:heartbeatText]];
            if (bad || future) [events addObject:@"错误：部分心跳异常/未来时间，已忽略"];
            NSNumber *boot = SBCDNotify("com.yourname.sbcpufloating/thermal.boot.settled");
            NSNumber *protection = SBCDNotify("com.yourname.sbcpufloating/thermal.protection.active");
            NSNumber *pressure = SBCDNotify("com.yourname.sbcpufloating/thermal.pressure");
            NSString *(^cached)(NSNumber *) = ^NSString *(NSNumber *v) {
                if (!v) return @"不可读";
                if (v.unsignedLongLongValue == 1) return @"历史缓存报告为 1（无报告时间）";
                if (v.unsignedLongLongValue == 0) return @"0（未发布与关闭无法区分）";
                return @"异常值";
            };
            SBCDGroup(rows, @"核心报告（不等于当前运行值）", [NSString stringWithFormat:@"启动静默期结束：%@\n过热安全覆盖：%@\n热压力缓存：%@\n这些既有通知无时间戳/序列号，不能与独立心跳关联；即使心跳新鲜也可能是旧值。安全覆盖不是“温控已启用”。配置模式通知是用户请求，不作为运行模式证据。", cached(boot), cached(protection), pressure ? ([@[@0,@10,@20,@30,@40,@50,@999] containsObject:pressure] ? [NSString stringWithFormat:@"%@（0 也可能未发布；999 未知）", pressure] : @"异常值") : @"不可读"]);
            NSString *dylib = SBCPUThermalJBRootPathForRootFSPath("/Library/MobileSubstrate/DynamicLibraries/SBCPUThermal.dylib");
            BOOL installed = [[NSFileManager defaultManager] fileExistsAtPath:dylib];
            SBCDGroup(rows, @"安装与 Hook 证据", [NSString stringWithFormat:@"核心文件：%@\nHook 安装：未验证。文件存在不代表已注入或 Hook 已安装。核心已有 NSLog 安装/重载记录，但未提供可安全读取的专属日志文件；本页不扫描统一系统日志，也不伪造安装事件。\n实际 CPU/显示/系统保护效果：未验证。", installed ? @"发现候选安装文件" : @"未发现候选文件（可能路径/权限不可见）"]);
            NSArray *keys = @[@"thermalEngineEnabled", @"powerMode", @"thermalPressureAutoProtectionEnabled", @"thermalLockScreenLowPowerEnabled", @"thermalNominalAutoRecoveryEnabled", @"thermalPreventDimmingEnabled", @"thermalBlockNotifPopup"];
            NSArray *titles = @[@"温度保护总开关", @"运行方式", @"过热自动保护", @"锁屏省电保护", @"温度正常后自动恢复", @"温控防暗屏", @"尝试抑制高温通知弹窗"];
            NSMutableArray *configuration = [NSMutableArray array];
            for (NSUInteger i = 0; i < keys.count; i++) {
                NSString *value = SBCDConfigValue(prefs, keys[i], readable);
                [configuration addObject:[NSString stringWithFormat:@"%@=%@", titles[i], value]];
                NSString *reason = @"核心未发布本项配置快照或执行事件；已开启不等于真正启动。";
                if (i == 1) reason = @"核心未发布当前执行模式；锁屏及过热覆盖可能改变模式，无法确认与配置是否一致。";
                if (i > 1 && readable && [prefs[@"thermalEngineEnabled"] isKindOfClass:NSNumber.class] && ![prefs[@"thermalEngineEnabled"] boolValue]) reason = @"配置总开关关闭：本项按配置不应生效；核心是否已重载无法确认。";
                if (i == 6) reason = [reason stringByAppendingString:@" 仅已有通知路径；不保证隐藏全屏高温保护，不解除系统安全保护。"];
                SBCDGroup(rows, titles[i], [NSString stringWithFormat:@"配置：%@\n运行：未知/待验证\nHook：未验证；效果：未验证\n%@", value, reason]);
            }
            if (SBCDConfigConflict(prefs, readable, protection)) {
                SBCDGroup(rows, @"配置/报告疑似不一致", @"配置总开关关闭，但缓存安全覆盖报告为 1；可能是旧报告或未同步，不能断言保存失败/运行生效。请在需要时手动刷新。");
                [events addObject:@"疑似不一致：配置关闭/缓存安全覆盖为 1（无时间关联）"];
            }
            NSString *fingerprint = [configuration componentsJoinedByString:@"；"];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.previousConfiguration && ![self.previousConfiguration isEqual:fingerprint]) [events addObject:@"配置摘要改变：未获得核心重载确认"];
                self.previousConfiguration = fingerprint;
                for (NSString *event in events) [self.events addObject:[NSString stringWithFormat:@"[%@] %@", stamp, event]];
                while (self.events.count > 80) [self.events removeObjectAtIndex:0];
                self.diagnosticRows = rows;
                self.loading = NO;
                self.navigationItem.rightBarButtonItem.enabled = YES;
                self->_specifiers = nil;
                [self reloadSpecifiers];
            });
        }
    });
}
@end
