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

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"插件冲突检测";
}

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
                NSString *process = item[@"process"] ?: @"未知进程";
                NSArray *plugins = item[@"plugins"] ?: @[];
                NSString *detail = [NSString stringWithFormat:@"%lu 个插件同时注入：%@", (unsigned long)plugins.count, [plugins componentsJoinedByString:@"、"]];
                [items addObject:[PSSpecifier preferenceSpecifierNamed:[NSString stringWithFormat:@"%@：%@", process, detail] target:nil set:NULL get:NULL detail:Nil cell:PSStaticTextCell edit:nil]];
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
    _specifiers = nil;
    [self reloadSpecifiers];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSDictionary *snapshot = [weakSelf scanSnapshot];
        dispatch_async(dispatch_get_main_queue(), ^{
            SBCPUPluginConflictController *strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.results = snapshot[@"results"] ?: @[];
            strongSelf.scannedDirectories = [snapshot[@"directories"] unsignedIntegerValue];
            strongSelf.scannedPlists = [snapshot[@"plists"] unsignedIntegerValue];
            strongSelf.scanMessage = [NSString stringWithFormat:@"扫描完成：%lu 个插件目录，%lu 个过滤器。", (unsigned long)strongSelf.scannedDirectories, (unsigned long)strongSelf.scannedPlists];
            strongSelf.scanning = NO;
            strongSelf->_specifiers = nil;
            [strongSelf reloadSpecifiers];
        });
    });
}
@end
