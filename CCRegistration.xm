#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>
#import <substrate.h>
#import "SBCPUThermalPaths.h"

static NSArray<NSURL *> *(*origDefaultModuleDirectories)(id, SEL) = NULL;
static void (*origQueueUpdateAllModuleMetadata)(id, SEL) = NULL;
static void (*origUpdateAllModuleMetadata)(id, SEL) = NULL;
static BOOL gHooksInstalled = NO;
static BOOL gExternalCCSupportDetected = NO;

static BOOL SBCPUPathExists(NSString *path) { return path.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:path]; }
static BOOL SBCPUImageContains(const char *needle) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i=0; i<count; i++) { const char *name=_dyld_get_image_name(i); if (name && strstr(name, needle)) return YES; }
    return NO;
}
static BOOL SBCPUExternalCCSupportPresent(void) {
    if (objc_getClass("CCSModuleProviderManager")) return YES;
    if (SBCPUImageContains("CCSupport.dylib") || SBCPUImageContains("/CCSupport/")) return YES;
    NSMutableArray<NSString *> *roots = [NSMutableArray arrayWithObjects:SBCPUThermalStringFromCPath(""), S("/var/jb"), nil];
    NSString *rh = SBCPUThermalCurrentRootHideRoot(); if (rh.length) [roots addObject:rh];
    for (NSString *root in roots) {
        NSString *d = [root stringByAppendingPathComponent:S("Library/MobileSubstrate/DynamicLibraries/CCSupport.dylib")];
        if (SBCPUPathExists(d)) return YES;
    }
    return NO;
}
static NSString *SBCPUCCModulesPath(void) { return SBCPUThermalJBRootPathForRootFSPath("/Library/ControlCenter/Bundles"); }
static void SBCPUSetAllowlistBypass(id repository) {
    if (!repository) return;
    Class cls = object_getClass(repository);
    Ivar ivar = class_getInstanceVariable(cls, "_ignoreAllowedList");
    if (!ivar) ivar = class_getInstanceVariable(cls, "_ignoreWhitelist");
    if (!ivar) return;
    ptrdiff_t offset = ivar_getOffset(ivar);
    *((BOOL *)((uint8_t *)(__bridge void *)repository + offset)) = YES;
}
static NSArray<NSURL *> *SBCPUDefaultModuleDirectories(id self, SEL command) {
    NSArray<NSURL *> *dirs = origDefaultModuleDirectories ? origDefaultModuleDirectories(self, command) : nil;
    if (SBCPUExternalCCSupportPresent()) return dirs;
    NSString *path = SBCPUCCModulesPath();
    NSURL *u = path.length ? [NSURL fileURLWithPath:path isDirectory:YES] : nil;
    if (!u) return dirs;
    for (NSURL *x in dirs ?: @[]) if ([[x path] isEqualToString:[u path]]) return dirs;
    return dirs ? [dirs arrayByAddingObject:u] : @[u];
}
static void SBCPUQueueUpdate(id self, SEL command) { if (!SBCPUExternalCCSupportPresent()) SBCPUSetAllowlistBypass(self); if (origQueueUpdateAllModuleMetadata) origQueueUpdateAllModuleMetadata(self, command); }
static void SBCPUUpdate(id self, SEL command) { if (!SBCPUExternalCCSupportPresent()) SBCPUSetAllowlistBypass(self); if (origUpdateAllModuleMetadata) origUpdateAllModuleMetadata(self, command); }
static void SBCPUInstallHooks(void) {
    if (gExternalCCSupportDetected || gHooksInstalled) return;
    Class repo = objc_getClass("CCSModuleRepository"); if (!repo) return;
    Class meta = object_getClass(repo);
    SEL dirsSel = sel_registerName("_defaultModuleDirectories");
    Method dm = class_getClassMethod(repo, dirsSel);
    if (dm && !origDefaultModuleDirectories) MSHookMessageEx(meta, dirsSel, (IMP)SBCPUDefaultModuleDirectories, (IMP *)&origDefaultModuleDirectories);
    SEL qSel = sel_registerName("_queue_updateAllModuleMetadata");
    if (class_getInstanceMethod(repo, qSel) && !origQueueUpdateAllModuleMetadata) MSHookMessageEx(repo, qSel, (IMP)SBCPUQueueUpdate, (IMP *)&origQueueUpdateAllModuleMetadata);
    SEL uSel = sel_registerName("_updateAllModuleMetadata");
    if (class_getInstanceMethod(repo, uSel) && !origUpdateAllModuleMetadata) MSHookMessageEx(repo, uSel, (IMP)SBCPUUpdate, (IMP *)&origUpdateAllModuleMetadata);
    gHooksInstalled = (origDefaultModuleDirectories != NULL) && ((origQueueUpdateAllModuleMetadata != NULL) || (origUpdateAllModuleMetadata != NULL));
}
static void SBCPUBundleDidLoad(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef ui) {
    (void)c;(void)o;(void)n;(void)obj;(void)ui;
    if (!gExternalCCSupportDetected && SBCPUExternalCCSupportPresent()) { gExternalCCSupportDetected = YES; return; }
    SBCPUInstallHooks();
}
%ctor {
    @autoreleasepool {
        gExternalCCSupportDetected = SBCPUExternalCCSupportPresent();
        if (gExternalCCSupportDetected) return;
        dlopen("/System/Library/PrivateFrameworks/ControlCenterServices.framework/ControlCenterServices", RTLD_LAZY | RTLD_GLOBAL);
        gExternalCCSupportDetected = SBCPUExternalCCSupportPresent();
        if (gExternalCCSupportDetected) return;
        SBCPUInstallHooks();
        if (!gHooksInstalled) CFNotificationCenterAddObserver(CFNotificationCenterGetLocalCenter(), NULL, SBCPUBundleDidLoad, (__bridge CFStringRef)NSBundleDidLoadNotification, NULL, CFNotificationSuspensionBehaviorCoalesce);
    }
}
