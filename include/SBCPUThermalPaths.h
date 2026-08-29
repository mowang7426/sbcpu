#ifndef CPUTHERMAL_PATHS_H
#define CPUTHERMAL_PATHS_H

#import <Foundation/Foundation.h>
#import <notify.h>
#include <stdint.h>
#include <roothide.h>

#define S(str) [NSString stringWithUTF8String:(str)]

static const char *kSBCPUThermalPrefRootFSPathC = "/var/mobile/Library/Preferences/com.yourname.sbcpufloating.plist";
static const char *kSBCPUThermalOldJBPrefRelativePathC = "Library/Preferences/com.yourname.sbcpufloating.plist";
static const char *kSBCPUThermalSettingsChangedNotifC = "com.yourname.sbcpufloating/settingsChanged";
static const char *kSBCPUThermalPowerModeChangedNotifC = "com.yourname.sbcpufloating/powerModeChanged";
static const char *kSBCPUThermalMaximumCapacityNotifC = "com.yourname.sbcpufloating/maximumCapacityState";
static const char *kSBCPUThermalRefreshRateNotifC = "com.yourname.sbcpufloating/refreshRateState";
static const char *kSBCPUThermalLowPowerModeC = "lowPower";
static const char *kSBCPUThermalFullPowerModeC = "fullPower";
static const uint64_t kSBCPUThermalPowerModeStateFull = 0;
static const uint64_t kSBCPUThermalPowerModeStateLow = 1;

// 温控核心跨进程心跳文件：Darwin notify 在部分 RootHide/thermalmonitord
// 组合环境中可能出现状态空间不同步，因此同时保留一个最简单的共享文件心跳。
// /var/tmp 由 thermalmonitord 与 SpringBoard 共同可见。
static const char *kSBCPUThermalHeartbeatFileC = "/var/tmp/com.yourname.sbcpufloating.thermal.heartbeat";


// Darwin notify state 直接携带模式，避免 thermalmonitord 因偏好路径/缓存读到旧值。
static inline int SBCPUThermalPostPowerMode(NSString *mode) {
    int token = 0;
    if (notify_register_check(kSBCPUThermalPowerModeChangedNotifC, &token) != NOTIFY_STATUS_OK) return -1;
    uint64_t state = [mode isEqualToString:S(kSBCPUThermalLowPowerModeC)]
        ? kSBCPUThermalPowerModeStateLow : kSBCPUThermalPowerModeStateFull;
    int result = notify_set_state(token, state);
    if (result == NOTIFY_STATUS_OK) result = notify_post(kSBCPUThermalPowerModeChangedNotifC);
    notify_cancel(token);
    return result;
}

static inline BOOL SBCPUThermalReadPostedPowerMode(BOOL *lowPower) {
    int token = 0;
    uint64_t state = UINT64_MAX;
    if (notify_register_check(kSBCPUThermalPowerModeChangedNotifC, &token) != NOTIFY_STATUS_OK) return NO;
    int result = notify_get_state(token, &state);
    notify_cancel(token);
    if (result != NOTIFY_STATUS_OK || state > kSBCPUThermalPowerModeStateLow) return NO;
    if (lowPower) *lowPower = (state == kSBCPUThermalPowerModeStateLow);
    return YES;
}

static inline void SBCPUThermalPostRefreshRateState(BOOL force120) {
    int token = 0;
    if (notify_register_check(kSBCPUThermalRefreshRateNotifC, &token) != NOTIFY_STATUS_OK) return;
    notify_set_state(token, force120 ? 1ULL : 0ULL);
    notify_post(kSBCPUThermalRefreshRateNotifC);
    notify_cancel(token);
}

static inline BOOL SBCPUThermalReadRefreshRateState(BOOL *force120) {
    int token = 0; uint64_t state = 0;
    if (notify_register_check(kSBCPUThermalRefreshRateNotifC, &token) != NOTIFY_STATUS_OK) return NO;
    int result = notify_get_state(token, &state); notify_cancel(token);
    if (result != NOTIFY_STATUS_OK) return NO;
    if (force120) *force120 = state != 0;
    return YES;
}

static inline void SBCPUThermalPostMaximumCapacityState(BOOL enabled) {
    int token = 0;
    if (notify_register_check(kSBCPUThermalMaximumCapacityNotifC, &token) != NOTIFY_STATUS_OK) return;
    notify_set_state(token, enabled ? 1 : 0);
    notify_post(kSBCPUThermalMaximumCapacityNotifC);
    notify_cancel(token);
}

static inline BOOL SBCPUThermalMaximumCapacityState(void) {
    int token = 0;
    uint64_t state = 0;
    if (notify_register_check(kSBCPUThermalMaximumCapacityNotifC, &token) != NOTIFY_STATUS_OK) return NO;
    int result = notify_get_state(token, &state);
    notify_cancel(token);
    return result == NOTIFY_STATUS_OK && state == 1;
}

static inline NSString *SBCPUThermalStringFromCPath(const char *path) {
    return path ? [NSString stringWithUTF8String:path] : nil;
}

static inline NSString *SBCPUThermalJBRootPathForRootFSPath(const char *path) {
    if (!path) return nil;

    // 优先尝试通过 jbroot 转换路径
    const char *jbPath = jbroot(path);
    if (jbPath && strlen(jbPath) > 0) {
        NSString *converted = [NSString stringWithUTF8String:jbPath];
        if ([[NSFileManager defaultManager] fileExistsAtPath:converted]) {
            return converted;
        }
    }

    // 兜底 1: 检查 /var/jb 相对路径
    NSString *varJBPath = [S("/var/jb") stringByAppendingPathComponent:[NSString stringWithUTF8String:path]];
    if ([[NSFileManager defaultManager] fileExistsAtPath:varJBPath]) {
        return varJBPath;
    }

    // 兜底 2: 返回原始路径
    return [NSString stringWithUTF8String:path];
}

static inline NSString *SBCPUThermalCurrentRootHideRoot(void) {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *appGroupRoot = S("/var/mobile/Containers/Shared/AppGroup");
    NSArray<NSString *> *entries = [fileManager contentsOfDirectoryAtPath:appGroupRoot error:nil];
    NSString *bestRoot = nil;
    NSInteger bestScore = NSIntegerMin;
    NSDate *bestDate = nil;

    for (NSString *entry in entries) {
        if (![entry hasPrefix:S(".jbroot-")]) continue;
        NSString *root = [appGroupRoot stringByAppendingPathComponent:entry];
        BOOL isDirectory = NO;
        if (![fileManager fileExistsAtPath:root isDirectory:&isDirectory] || !isDirectory) continue;

        NSInteger score = 0;
        NSString *tweakPath = [root stringByAppendingPathComponent:S("Library/MobileSubstrate/DynamicLibraries/SBCPUThermal.dylib")];
        NSString *substratePath = [root stringByAppendingPathComponent:S("Library/MobileSubstrate")];
        NSString *usrLibPath = [root stringByAppendingPathComponent:S("usr/lib")];
        if ([fileManager fileExistsAtPath:tweakPath]) score += 1000;
        if ([fileManager fileExistsAtPath:substratePath]) score += 100;
        if ([fileManager fileExistsAtPath:usrLibPath]) score += 10;

        NSDictionary *attributes = [fileManager attributesOfItemAtPath:root error:nil];
        NSDate *date = attributes[NSFileModificationDate] ?: [NSDate distantPast];
        if (!bestRoot || score > bestScore || (score == bestScore && [date compare:bestDate] == NSOrderedDescending)) {
            bestRoot = root;
            bestScore = score;
            bestDate = date;
        }
    }
    return bestRoot;
}

static inline NSString *SBCPUThermalCurrentPrefPath(void) {
    // 先动态定位当前 .jbroot-UUID，避免部分 RootHide 进程中的 jbroot(/var/mobile/...)
    // 仍返回真实 var 路径。UUID 每次重越狱变化也能自动重新发现。
    NSString *rootHideRoot = SBCPUThermalCurrentRootHideRoot();
    if (rootHideRoot.length > 0) {
        return [[rootHideRoot stringByAppendingPathComponent:S("var/mobile/Library/Preferences")]
            stringByAppendingPathComponent:S("com.yourname.sbcpufloating.plist")];
    }

    const char *convertedPath = jbroot(kSBCPUThermalPrefRootFSPathC);
    if (convertedPath && strlen(convertedPath) > 0) {
        NSString *converted = [NSString stringWithUTF8String:convertedPath];
        if ([converted containsString:S("/Containers/Shared/AppGroup/.jbroot-")]) return converted;
    }
    return SBCPUThermalJBRootPathForRootFSPath(kSBCPUThermalPrefRootFSPathC);
}

static inline NSString *SBCPUThermalOldJBRootPrefPath(void) {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *resolvedJBRoot = [fileManager destinationOfSymbolicLinkAtPath:S("/var/jb") error:nil];
    if (resolvedJBRoot.length > 0) {
        return [resolvedJBRoot stringByAppendingPathComponent:S(kSBCPUThermalOldJBPrefRelativePathC)];
    }
    return [S("/var/jb") stringByAppendingPathComponent:S(kSBCPUThermalOldJBPrefRelativePathC)];
}

static inline NSArray<NSString *> *SBCPUThermalLegacyPrefPaths(void) {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSFileManager *fileManager = [NSFileManager defaultManager];

    // RootHide 重新生成环境后 UUID 会变化；扫描全部旧 .jbroot-* 偏好副本并迁移。
    NSString *appGroupRoot = S("/var/mobile/Containers/Shared/AppGroup");
    NSArray<NSString *> *entries = [fileManager contentsOfDirectoryAtPath:appGroupRoot error:nil];
    for (NSString *entry in entries) {
        if (![entry hasPrefix:S(".jbroot-")]) continue;
        NSString *candidate = [[[appGroupRoot stringByAppendingPathComponent:entry]
            stringByAppendingPathComponent:S("var/mobile/Library/Preferences")]
            stringByAppendingPathComponent:S("com.yourname.sbcpufloating.plist")];
        if (![paths containsObject:candidate]) [paths addObject:candidate];
    }

    NSString *oldJBPath = SBCPUThermalOldJBRootPrefPath();
    if (oldJBPath.length > 0) {
        [paths addObject:oldJBPath];
    }
    NSString *rootFSPath = SBCPUThermalStringFromCPath(kSBCPUThermalPrefRootFSPathC);
    if (rootFSPath.length > 0 && ![paths containsObject:rootFSPath]) {
        [paths addObject:rootFSPath];
    }
    return paths;
}

static inline NSString *SBCPUThermalExistingExecutablePath(const char *rootFSPath, NSArray<NSString *> *fallbackPaths) {
    if (!rootFSPath) return nil;
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *resolvedPath = SBCPUThermalJBRootPathForRootFSPath(rootFSPath);
    if (resolvedPath.length > 0 && [fileManager isExecutableFileAtPath:resolvedPath]) {
        return resolvedPath;
    }

    for (NSString *path in fallbackPaths) {
        if (path.length > 0 && [fileManager isExecutableFileAtPath:path]) {
            return path;
        }
    }
    return nil;
}

static inline NSString *SBCPUThermalLaunchctlPath(void) {
    return SBCPUThermalExistingExecutablePath("/usr/bin/launchctl", @[
        S("/var/jb/usr/bin/launchctl"),
        S("/var/jb/bin/launchctl"),
        S("/usr/bin/launchctl"),
        S("/bin/launchctl")
    ]);
}

static inline NSString *SBCPUThermalToolPath(void) {
    return SBCPUThermalExistingExecutablePath("/usr/local/bin/SBCPUThermalTool", @[
        S("/var/jb/usr/local/bin/SBCPUThermalTool"),
        S("/usr/local/bin/SBCPUThermalTool")
    ]);
}

static inline void SBCPUThermalEnsurePrefDirectory(void) {
    NSString *path = SBCPUThermalCurrentPrefPath();
    NSString *directory = [path stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
}

static inline NSMutableDictionary *SBCPUThermalReadMutablePrefs(void) {
    NSString *path = SBCPUThermalCurrentPrefPath();
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:path];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (prefs) {
        // 当前隐根配置有效时，清掉真实 var 和旧 UUID 副本，避免被 var 清理继续识别。
        for (NSString *legacyPath in SBCPUThermalLegacyPrefPaths()) {
            if (![legacyPath isEqualToString:path]) {
                [fileManager removeItemAtPath:legacyPath error:nil];
            }
        }
        return prefs;
    }


    NSString *newestLegacyPath = nil;
    NSDictionary *newestLegacyPrefs = nil;
    NSDate *newestDate = nil;
    NSArray<NSString *> *legacyPaths = SBCPUThermalLegacyPrefPaths();
    for (NSString *legacyPath in legacyPaths) {
        if ([legacyPath isEqualToString:path]) continue;
        NSDictionary *legacyPrefs = [NSDictionary dictionaryWithContentsOfFile:legacyPath];
        if (!legacyPrefs) continue;
        NSDictionary *attributes = [fileManager attributesOfItemAtPath:legacyPath error:nil];
        NSDate *date = attributes[NSFileModificationDate] ?: [NSDate distantPast];
        if (!newestLegacyPrefs || [date compare:newestDate] == NSOrderedDescending) {
            newestLegacyPath = legacyPath;
            newestLegacyPrefs = legacyPrefs;
            newestDate = date;
        }
    }

    if (newestLegacyPrefs) {
        prefs = [newestLegacyPrefs mutableCopy];
        SBCPUThermalEnsurePrefDirectory();
        if ([prefs writeToFile:path atomically:YES]) {
            for (NSString *legacyPath in legacyPaths) {
                if (![legacyPath isEqualToString:path]) {
                    [fileManager removeItemAtPath:legacyPath error:nil];
                }
            }
        }
        (void)newestLegacyPath;
        return prefs;
    }

    return nil;
}

static inline NSDictionary *SBCPUThermalReadPrefs(void) {
    return SBCPUThermalReadMutablePrefs();
}

static inline BOOL SBCPUThermalWritePrefs(NSDictionary *prefs) {
    if (!prefs) {
        return NO;
    }

    NSString *path = SBCPUThermalCurrentPrefPath();
    SBCPUThermalEnsurePrefDirectory();
    BOOL ok = [prefs writeToFile:path atomically:YES];
    if (ok) {
        NSFileManager *fileManager = [NSFileManager defaultManager];
        for (NSString *legacyPath in SBCPUThermalLegacyPrefPaths()) {
            if (![legacyPath isEqualToString:path]) {
                [fileManager removeItemAtPath:legacyPath error:nil];
            }
        }
    }
    return ok;
}

#endif
