#import <Foundation/Foundation.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

@interface SBCPUPluginConflictController : PSListController
@property(nonatomic,copy) NSArray<NSDictionary *> *results;
@property(nonatomic,assign) BOOL scanning;
@property(nonatomic,copy) NSString *scanMessage;
@property(nonatomic,assign) NSUInteger scannedPlists;
@property(nonatomic,assign) NSUInteger scannedDirectories;
@end

@implementation SBCPUPluginConflictController

static void SBCPUPluginScanFinished(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    (void)center; (void)name; (void)object; (void)userInfo;
    SBCPUPluginConflictController *controller = (__bridge SBCPUPluginConflictController *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{ [controller receiveScanResult]; });
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"插件冲突检测";
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge const void *)self, SBCPUPluginScanFinished, CFSTR("com.sbcpu.floating.plugin-scan.finished"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}

- (void)dealloc {
    CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge const void *)self, CFSTR("com.sbcpu.floating.plugin-scan.finished"), NULL);
}

- (void)receiveScanResult {
    NSDictionary *snapshot = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.sbcpu.floating.plugin-scan.json"];
    if (![snapshot isKindOfClass:[NSDictionary class]] || ![snapshot[@"finished"] boolValue]) return;
    self.scanning = NO;
    self.results = snapshot[@"conflicts"] ?: @[];
    self.scannedDirectories = 1;
    self.scannedPlists = [snapshot[@"pluginCount"] unsignedIntegerValue];
    NSString *method = snapshot[@"method"] ?: @"SpringBoard 扫描";
    NSString *error = snapshot[@"error"];
    self.scanMessage = [NSString stringWithFormat:@"扫描完成：%@，已识别 %lu 个插件。%@", method, (unsigned long)self.scannedPlists, error.length ? [@" 诊断：" stringByAppendingString:error] : @""];
    _specifiers = nil;
    [self reloadSpecifiers];
}

- (void)viewDidAppear:(BOOL)animated {

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!self.scanMessage && !self.scanning) [self startScan];
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *items = [NSMutableArray array];
        [items addObject:[PSSpecifier groupSpecifierWithName:@"安全扫描"]];
        PSSpecifier *scan = [PSSpecifier preferenceSpecifierNamed:self.scanning ? @"正在扫描…" : @"重新扫描插件"
            target:self set:NULL get:NULL detail:nil cell:PSButtonCell edit:nil];
        [scan setButtonAction:@selector(startScan)];
        [scan setProperty:@(!self.scanning) forKey:@"enabled"];
        [items addObject:scan];
        if (self.scanMessage) {
            [items addObject:[PSSpecifier preferenceSpecifierNamed:self.scanMessage target:nil set:NULL get:NULL detail:Nil cell:PSStaticTextCell edit:nil]];
        } else {
            [items addObject:[PSSpecifier preferenceSpecifierNamed:@"进入此页面后会自动扫描；也可点上方按钮重新扫描。" target:nil set:NULL get:NULL detail:Nil cell:PSStaticTextCell edit:nil]];
        }
        if (!_results) {
            [items addObject:[PSSpecifier preferenceSpecifierNamed:@"等待扫描结果" target:nil set:NULL get:NULL detail:Nil cell:PSStaticTextCell edit:nil]];
        } else if (!self.scannedDirectories) {
            [items addObject:[PSSpecifier preferenceSpecifierNamed:@"无法访问插件扫描目录，不能判定是否存在冲突。" target:nil set:NULL get:NULL detail:Nil cell:PSStaticTextCell edit:nil]];
        } else if (!_results.count) {
            [items addObject:[PSSpecifier preferenceSpecifierNamed:@"未发现多个插件同时注入同一系统进程。" target:nil set:NULL get:NULL detail:Nil cell:PSStaticTextCell edit:nil]];
        } else {
            [items addObject:[PSSpecifier groupSpecifierWithName:[NSString stringWithFormat:@"发现 %lu 个潜在冲突", (unsigned long)_results.count]]];
            for (NSDictionary *item in _results) {
                NSString *title = item[@"title"] ?: item[@"process"] ?: @"潜在冲突";
                NSString *description = item[@"desc"] ?: @"";
                NSArray *plugins = item[@"plugins"] ?: @[];
                NSString *detail = plugins.count ? [NSString stringWithFormat:@"%@\n涉及插件：%@", description, [plugins componentsJoinedByString:@"、"]] : description;
                [items addObject:[PSSpecifier preferenceSpecifierNamed:[NSString stringWithFormat:@"%@：%@", title, detail] target:nil set:NULL get:NULL detail:Nil cell:PSStaticTextCell edit:nil]];
            }
        }
        _specifiers = items;
    }
    return _specifiers;
}

static NSArray *SBCPUPluginDirectories(void) {
    return @[@"/var/jb/Library/MobileSubstrate/DynamicLibraries",
             @"/private/var/jb/Library/MobileSubstrate/DynamicLibraries",
             @"/Library/MobileSubstrate/DynamicLibraries",
             @"/var/lib/MobileSubstrate/DynamicLibraries",
             @"/private/var/lib/MobileSubstrate/DynamicLibraries",
             @"/var/jb/usr/lib/TweakInject",
             @"/private/var/jb/usr/lib/TweakInject",
             @"/usr/lib/TweakInject",
             @"/var/jb/Library/TweakInject",
             @"/private/var/jb/Library/TweakInject",
             @"/Library/TweakInject"];
}

static NSArray *SBCPUProcessNamesFromFilter(NSDictionary *filter) {
    if (![filter isKindOfClass:[NSDictionary class]]) return @[];
    NSMutableArray *result = [NSMutableArray array];
    for (NSString *key in @[@"Bundles", @"Executables", @"Classes"]) {
        id value = filter[key];
        if ([value isKindOfClass:[NSArray class]]) {
            for (id entry in value) if ([entry isKindOfClass:[NSString class]] && [entry length]) [result addObject:entry];
        } else if ([value isKindOfClass:[NSString class]] && [value length]) {
            [result addObject:value];
        }
    }
    return result;
}

- (NSDictionary *)scanSnapshot {
    NSMutableDictionary<NSString *, NSMutableSet<NSString *> *> *processPlugins = [NSMutableDictionary dictionary];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSUInteger directories = 0, plistCount = 0;
    for (NSString *directory in SBCPUPluginDirectories()) {
        BOOL isDirectory = NO;
        if (![fm fileExistsAtPath:directory isDirectory:&isDirectory] || !isDirectory) continue;
        directories++;
        NSArray *files = [fm contentsOfDirectoryAtPath:directory error:nil];
        for (NSString *file in files) {
            if (![[file pathExtension].lowercaseString isEqualToString:@"plist"]) continue;
            plistCount++;
            NSString *path = [directory stringByAppendingPathComponent:file];
            NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:path];
            if (![plist isKindOfClass:[NSDictionary class]]) continue;
            NSArray *targets = SBCPUProcessNamesFromFilter(plist[@"Filter"]);
            if (!targets.count) continue;
            NSString *plugin = [file stringByDeletingPathExtension];
            for (NSString *target in targets) {
                if (!processPlugins[target]) processPlugins[target] = [NSMutableSet set];
                [processPlugins[target] addObject:plugin];
            }
        }
    }
    NSMutableArray *results = [NSMutableArray array];
    for (NSString *process in processPlugins) {
        NSSet *plugins = processPlugins[process];
        if (plugins.count < 2) continue;
        NSArray *sorted = [[plugins allObjects] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
        [results addObject:@{ @"process": process, @"plugins": sorted }];
    }
    NSArray *sortedResults = [results sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"process"] localizedCaseInsensitiveCompare:b[@"process"]];
    }];
    return @{ @"results": sortedResults, @"directories": @(directories), @"plists": @(plistCount) };
}

- (void)startScan {
    if (self.scanning) return;
    self.scanning = YES;
    self.scanMessage = @"正在请求 SpringBoard 扫描插件目录…";
    _specifiers = nil;
    [self reloadSpecifiers];
    [[NSFileManager defaultManager] removeItemAtPath:@"/var/mobile/Library/Preferences/com.sbcpu.floating.plugin-scan.json" error:nil];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.sbcpu.floating.plugin-scan.request"), NULL, NULL, YES);
    __weak typeof(self) weakSelf = self;
    __block NSUInteger attempts = 0;
    __block dispatch_block_t check = nil;
    check = ^{
        SBCPUPluginConflictController *strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.scanning) return;
        [strongSelf receiveScanResult];
        if (!strongSelf.scanning) return;
        attempts++;
        if (attempts >= 30) {
            strongSelf.scanning = NO;
            strongSelf.scanMessage = @"扫描请求未收到 SpringBoard 响应；确认插件已注入 SpringBoard 后重试。";
            strongSelf->_specifiers = nil;
            [strongSelf reloadSpecifiers];
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), check);
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), check);
}
@end
