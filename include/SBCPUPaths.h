#ifndef SBCPU_PATHS_H
#define SBCPU_PATHS_H
#import <Foundation/Foundation.h>
#include <roothide.h>
#include <string.h>
#define S(str) [NSString stringWithUTF8String:(str)]
static inline NSString *SBCPUJBRootPathForRootFSPath(const char *path) {
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

static inline NSString *SBCPUCurrentRootHideRoot(void) {
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
        NSString *tweakPath = [root stringByAppendingPathComponent:S("Library/MobileSubstrate/DynamicLibraries/SBCPUFloating.dylib")];
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


#endif
