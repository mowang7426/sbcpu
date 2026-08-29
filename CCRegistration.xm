#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>
#import <substrate.h>
#import "SBCPUThermalPaths.h"

// 参考 CPUthermal 1.6.4-53 的 CCRegistration.xm：
// 1. 将 /Library/ControlCenter/Bundles 纳入 CCSModuleRepository 扫描目录；
// 2. 在没有外部 CCSupport 时旁路内置 allowlist；
// 3. 如果系统已经有 CCSupport，则不与其重复接管。

static NSArray<NSURL *> *(*origDefaultModuleDirectories)(id, SEL) = NULL;
static void (*origQueueUpdateAllModuleMetadata)(id, SEL) = NULL;
static void (*origUpdateAllModuleMetadata)(id, SEL) = NULL;
static BOOL gRepositoryHooksInstalled = NO;
static BOOL gExternalCCSupportDetected = NO;

static BOOL SBCPUPathExists(NSString *path) {
    return path.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:path];
}

static BOOL SBCPUImageNameContains(const char *needle) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, needle)) return YES;
    }
    return NO;
}

static BOOL SBCPUExternalCCSupportPresent(void) {
    if (objc_getClass("CCSModuleProviderManager")) return YES;
    if (SBCPUImageNameContains("CCSupport.dylib") || SBCPUImageNameContains("/CCSupport/")) return YES;

    NSMutableArray<NSString *> *roots = [NSMutableArray arrayWithObjects:S(""), S("/var/jb"), nil];
    NSString *rootHideRoot = SBCPUThermalCurrentRootHideRoot();
    if (rootHideRoot.length > 0) [roots addObject:rootHideRoot];

    for (NSString *root in roots) {
        NSString *dylib = [root stringByAppendingPathComponent:S("Library/MobileSubstrate/DynamicLibraries/CCSupport.dylib")];
        if (SBCPUPathExists(dylib)) return YES;
    }
    return NO;
}

static NSString *SBCPUCCModulesPath(void) {
    return SBCPUThermalJBRootPathForRootFSPath("/Library/ControlCenter/Bundles");
}

static void SBCPUSetRepositoryAllowlistBypass(id repository) {
    if (!repository) return;
    Class cls = object_getClass(repository);
    Ivar ivar = class_getInstanceVariable(cls, "_ignoreAllowedList");
    if (!ivar) ivar = class_getInstanceVariable(cls, "_ignoreWhitelist");
    if (!ivar) return;
    ptrdiff_t offset = ivar_getOffset(ivar);
    *((BOOL *)((uint8_t *)(__bridge void *)repository + offset)) = YES;
}

static NSArray<NSURL *> *SBCPUDefaultModuleDirectories(id self, SEL command) {
    NSArray<NSURL *> *directories = origDefaultModuleDirectories ? origDefaultModuleDirectories(self, command) : nil;
    if (SBCPUExternalCCSupportPresent()) return directories;

    NSString *path = SBCPUCCModulesPath();
    NSURL *url = path.length ? [NSURL fileURLWithPath:path isDirectory:YES] : nil;
    if (!url) return directories;

    for (NSURL *existing in directories ?: @[]) {
        if ([[existing path] isEqualToString:[url path]]) return directories;
    }
    return directories ? [directories arrayByAddingObject:url] : @[url];
}

static void SBCPUQueueUpdateAllModuleMetadata(id self, SEL command) {
    if (!SBCPUExternalCCSupportPresent()) SBCPUSetRepositoryAllowlistBypass(self);
    if (origQueueUpdateAllModuleMetadata) origQueueUpdateAllModuleMetadata(self, command);
}

static void SBCPUUpdateAllModuleMetadata(id self, SEL command) {
    if (!SBCPUExternalCCSupportPresent()) SBCPUSetRepositoryAllowlistBypass(self);
    if (origUpdateAllModuleMetadata) origUpdateAllModuleMetadata(self, command);
}

static void SBCPUInstallRepositoryHooks(void) {
    if (gExternalCCSupportDetected || gRepositoryHooksInstalled) return;

    Class repositoryClass = objc_getClass("CCSModuleRepository");
    if (!repositoryClass) return;

    SEL directoriesSelector = sel_registerName("_defaultModuleDirectories");
    Class metaClass = object_getClass(repositoryClass);
    Method directoriesMethod = class_getClassMethod(repositoryClass, directoriesSelector);
    if (directoriesMethod && !origDefaultModuleDirectories) {
        MSHookMessageEx(metaClass, directoriesSelector, (IMP)SBCPUDefaultModuleDirectories, (IMP *)&origDefaultModuleDirectories);
    }

    SEL queueSelector = sel_registerName("_queue_updateAllModuleMetadata");
    if (class_getInstanceMethod(repositoryClass, queueSelector) && !origQueueUpdateAllModuleMetadata) {
        MSHookMessageEx(repositoryClass, queueSelector, (IMP)SBCPUQueueUpdateAllModuleMetadata, (IMP *)&origQueueUpdateAllModuleMetadata);
    }

    SEL updateSelector = sel_registerName("_updateAllModuleMetadata");
    if (class_getInstanceMethod(repositoryClass, updateSelector) && !origUpdateAllModuleMetadata) {
        MSHookMessageEx(repositoryClass, updateSelector, (IMP)SBCPUUpdateAllModuleMetadata, (IMP *)&origUpdateAllModuleMetadata);
    }

    gRepositoryHooksInstalled = (origDefaultModuleDirectories != NULL) &&
        ((origQueueUpdateAllModuleMetadata != NULL) || (origUpdateAllModuleMetadata != NULL));
}

static void SBCPUBundleDidLoad(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    if (!gExternalCCSupportDetected && SBCPUExternalCCSupportPresent()) {
        gExternalCCSupportDetected = YES;
        return;
    }
    SBCPUInstallRepositoryHooks();
}

%ctor {
    @autoreleasepool {
        gExternalCCSupportDetected = SBCPUExternalCCSupportPresent();
        if (gExternalCCSupportDetected) return;

        dlopen("/System/Library/PrivateFrameworks/ControlCenterServices.framework/ControlCenterServices", RTLD_LAZY | RTLD_GLOBAL);

        gExternalCCSupportDetected = SBCPUExternalCCSupportPresent();
        if (gExternalCCSupportDetected) return;

        SBCPUInstallRepositoryHooks();
        if (!gRepositoryHooksInstalled) {
            CFNotificationCenterAddObserver(CFNotificationCenterGetLocalCenter(), NULL, SBCPUBundleDidLoad,
                (__bridge CFStringRef)NSBundleDidLoadNotification, NULL, CFNotificationSuspensionBehaviorCoalesce);
        }
    }
}
