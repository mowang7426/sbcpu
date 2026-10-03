// ============================================================
// SBCPUForce120.xm —— 全局 120Hz 强制（V4.17.1）
// 注入所有进程：
//   1) hook CADisplayLink（所有 App 的 display link 申报 120Hz）
//   2) hook CALayer.preferredFrameRateRange（iOS 16+，覆盖 CA 转场动画）
//   3) 跟踪已有 link，在启用/恢复前台/电源状态变化时重新应用
//      退出强制时恢复 App 最近一次请求，不强制唤醒已暂停的 link
// 低电量模式 / 系统临界过热时主动让位给系统（硬件保护）。
// ============================================================
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>

#define kPrefAppID CFSTR("com.yourname.sbcpufloating")
#define kPrefChangedNotification CFSTR("com.yourname.sbcpufloating.prefschanged")

#import <objc/runtime.h>
#import <substrate.h>

// V4.17.2: weak tracking + event-driven reapply; no thermal/CPU policy changes.
@interface SBCPU120Request : NSObject
@property(nonatomic) NSInteger fps;
@property(nonatomic) float minimum;
@property(nonatomic) float maximum;
@property(nonatomic) float preferred;
@property(nonatomic) BOOL usesRange;
@property(nonatomic) BOOL applied;
@end
@implementation SBCPU120Request
@end

static BOOL gForce120Enabled = NO;
// 独立的录屏期间增强请求；默认关闭，仅在用户授权且系统报告录屏时短暂生效。
static BOOL gScreenRecordingHighFrameRateEnabled = NO;
static BOOL gScreenRecordingActive = NO;
static NSObject *g120Lock;
static NSHashTable<CADisplayLink *> *g120Links;
static char g120RequestKey;
static __thread BOOL g120InternalWrite = NO;

// MotionX 的关键补充：向 CADynamicFrameRateSource 声明一个高刷原因。
// 通过运行时反射调用，系统不支持时完全跳过，不依赖私有头文件。
static void requestDynamicHighFrameRate(void) {
    Class cls = NSClassFromString(@"CADynamicFrameRateSource");
    if (!cls) return;
    @try {
        id source = [[cls alloc] init];
        SEL one = NSSelectorFromString(@"setHighFrameRateReason:");
        if ([source respondsToSelector:one]) {
            ((void (*)(id, SEL, NSUInteger))objc_msgSend)(source, one, (NSUInteger)1);
            return;
        }
        SEL many = NSSelectorFromString(@"setHighFrameRateReasons:count:");
        if ([source respondsToSelector:many]) {
            NSUInteger reason = 1;
            ((void (*)(id, SEL, const NSUInteger *, NSUInteger))objc_msgSend)(source, many, &reason, 1);
        }
    } @catch (id exception) {}
}

static void releaseDynamicHighFrameRate(void) {
    // CADynamicFrameRateSource 生命周期由系统管理；刷新偏好即可撤销本插件
    // 对 display link/layer 的请求，不主动销毁系统对象。
}

static void prepare120Tracking(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g120Lock = [NSObject new];
        g120Links = [NSHashTable weakObjectsHashTable];
    });
}

// Caller holds g120Lock. A weak registry must not keep display links alive.
static SBCPU120Request *request120(CADisplayLink *link) {
    SBCPU120Request *request = objc_getAssociatedObject(link, &g120RequestKey);
    if (!request) {
        request = [SBCPU120Request new];
        request.fps = link.preferredFramesPerSecond;
        if (@available(iOS 15.0, *)) {
            CAFrameRateRange range = link.preferredFrameRateRange;
            request.minimum = range.minimum;
            request.maximum = range.maximum;
            request.preferred = range.preferred;
            request.usesRange = YES;
        }
        objc_setAssociatedObject(link, &g120RequestKey, request, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [g120Links addObject:link];
    }
    return request;
}

static BOOL shouldForce120(void);

static void updateForce120Pref(void) {
    prepare120Tracking();
    CFPreferencesAppSynchronize(kPrefAppID);
    CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR("force120HzEnable"), kPrefAppID);
    BOOL enabled = NO;
    if (value && CFGetTypeID(value) == CFBooleanGetTypeID()) enabled = CFBooleanGetValue((CFBooleanRef)value);
    if (value) CFRelease(value);
    CFPropertyListRef recordingValue = CFPreferencesCopyAppValue(CFSTR("screenRecordingHighFrameRateEnabled"), kPrefAppID);
    BOOL recordingEnabled = recordingValue && CFGetTypeID(recordingValue) == CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)recordingValue);
    if (recordingValue) CFRelease(recordingValue);
    @synchronized(g120Lock) { gScreenRecordingHighFrameRateEnabled = recordingEnabled; }
    if (enabled && shouldForce120()) requestDynamicHighFrameRate();
    else releaseDynamicHighFrameRate();
}

// Preserve the original low-power/critical-temperature conditions exactly.
static BOOL shouldForce120(void) {
    @synchronized(g120Lock) {
        if (!(gForce120Enabled || (gScreenRecordingHighFrameRateEnabled && gScreenRecordingActive))) return NO;
    }
    if (NSProcessInfo.processInfo.isLowPowerModeEnabled) return NO;
    if (NSProcessInfo.processInfo.thermalState == NSProcessInfoThermalStateCritical) return NO;
    return YES;
}

typedef void (*SBCPUSetHighReasonIMP)(id, SEL, NSUInteger);
typedef void (*SBCPUSetHighReasonsIMP)(id, SEL, const NSUInteger *, NSUInteger);
static SBCPUSetHighReasonIMP gOrigSetHighReason = NULL;
static SBCPUSetHighReasonsIMP gOrigSetHighReasons = NULL;

static void hookedSetHighReason(id self, SEL sel, NSUInteger reason) {
    if (shouldForce120()) reason = 1;
    if (gOrigSetHighReason) gOrigSetHighReason(self, sel, reason);
}

static void hookedSetHighReasons(id self, SEL sel, const NSUInteger *reasons, NSUInteger count) {
    NSUInteger forced = 1;
    if (shouldForce120() && gOrigSetHighReasons) {
        gOrigSetHighReasons(self, sel, &forced, 1);
    } else if (gOrigSetHighReasons) {
        gOrigSetHighReasons(self, sel, reasons, count);
    }
}

static void installDynamicFrameRateHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = NSClassFromString(@"CADynamicFrameRateSource");
        if (!cls) return;
        SEL one = NSSelectorFromString(@"setHighFrameRateReason:");
        Method oneMethod = class_getInstanceMethod(cls, one);
        if (oneMethod) MSHookMessageEx(cls, one, (IMP)hookedSetHighReason, (IMP *)&gOrigSetHighReason);
        SEL many = NSSelectorFromString(@"setHighFrameRateReasons:count:");
        Method manyMethod = class_getInstanceMethod(cls, many);
        if (manyMethod) MSHookMessageEx(cls, many, (IMP)hookedSetHighReasons, (IMP *)&gOrigSetHighReasons);
    });
}
static NSInteger supported120Target(void) {
    Class screenClass = NSClassFromString(@"UIScreen");
    id screen = screenClass ? ((id (*)(id, SEL))objc_msgSend)(screenClass, NSSelectorFromString(@"mainScreen")) : nil;
    SEL maxSel = NSSelectorFromString(@"maximumFramesPerSecond");
    if (screen && [screen respondsToSelector:maxSel]) {
        NSInteger max = ((NSInteger (*)(id, SEL))objc_msgSend)(screen, maxSel);
        if (max > 0) return MIN(120, max);
    }
    return 120;
}

static void applyForce120ToLink(CADisplayLink *link) {
    if (!link) return;
    prepare120Tracking();
    @synchronized(g120Lock) {
        SBCPU120Request *request = request120(link);
        BOOL force = shouldForce120();
        if (!force && !request.applied) return;
        BOOL previous = g120InternalWrite;
        g120InternalWrite = YES;
        @try {
            if (@available(iOS 15.0, *)) {
                CGFloat target = (CGFloat)supported120Target();
                if (force) {
                    requestDynamicHighFrameRate();
                    link.preferredFrameRateRange = CAFrameRateRangeMake(target, target, target);
                }
                else if (request.usesRange) link.preferredFrameRateRange = CAFrameRateRangeMake(request.minimum, request.maximum, request.preferred);
                else link.preferredFramesPerSecond = request.fps;
            } else {
                link.preferredFramesPerSecond = force ? supported120Target() : request.fps;
            }
            request.applied = force;
        } @catch (NSException *exception) {
            // Keep original app lifecycle; never unpause or recreate its link here.
        } @finally {
            g120InternalWrite = previous;
        }
    }
}

static void refresh120Links(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            updateForce120Pref();
            NSArray<CADisplayLink *> *links;
            @synchronized(g120Lock) { links = g120Links.allObjects; }
            for (CADisplayLink *link in links) applyForce120ToLink(link);
        }
    });
}

static void force120PrefChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    refresh120Links();
}

// CAFrameRateRange 是 iOS 15+ 类型，而工程部署目标为 iOS 14；
// Logos 生成的 hook 声明无法用 @available 消音，这里压掉该警告（运行时仍由 @available 保护）。
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"

%hook CADisplayLink

// 新建 display link 后立即强制（标准入口）
+ (CADisplayLink *)displayLinkWithTarget:(id)target selector:(SEL)selector {
    CADisplayLink *link = %orig;
    applyForce120ToLink(link);
    return link;
}

// Covers links joining a run loop, without relying on undocumented factories.
- (void)addToRunLoop:(NSRunLoop *)runLoop forMode:(NSRunLoopMode)mode {
    applyForce120ToLink(self);
    %orig(runLoop, mode);
}

- (void)setPaused:(BOOL)paused {
    if (!paused) applyForce120ToLink(self);
    %orig(paused);
}

- (void)invalidate {
    prepare120Tracking();
    @synchronized(g120Lock) { [g120Links removeObject:self]; }
    %orig;
}

- (void)setPreferredFrameRateRange:(CAFrameRateRange)range {
    prepare120Tracking();
    @synchronized(g120Lock) {
        if (!g120InternalWrite) {
            SBCPU120Request *request = request120(self);
            request.minimum = range.minimum;
            request.maximum = range.maximum;
            request.preferred = range.preferred;
            request.usesRange = YES;
            request.applied = shouldForce120();
            if (request.applied) range = CAFrameRateRangeMake((CGFloat)supported120Target(), (CGFloat)supported120Target(), (CGFloat)supported120Target());
        }
        BOOL previous = g120InternalWrite;
        g120InternalWrite = YES;
        @try {
            %orig(range);
        }
        @finally { g120InternalWrite = previous; }
    }
}

- (void)setPreferredFramesPerSecond:(NSInteger)framesPerSecond {
    prepare120Tracking();
    @synchronized(g120Lock) {
        if (!g120InternalWrite) {
            SBCPU120Request *request = request120(self);
            request.fps = framesPerSecond;
            request.usesRange = NO;
            request.applied = shouldForce120();
            if (request.applied) framesPerSecond = supported120Target();
        }
        BOOL previous = g120InternalWrite;
        g120InternalWrite = YES;
        @try {
            %orig(framesPerSecond);
        }
        @finally { g120InternalWrite = previous; }
    }
}

%end

%hook CALayer

// iOS 16+：图层动画的帧率需求也强制 120，覆盖 App 打开/退出转场动画
- (void)setPreferredFrameRateRange:(CAFrameRateRange)range {
    if (shouldForce120()) {
        range = CAFrameRateRangeMake((CGFloat)supported120Target(), (CGFloat)supported120Target(), (CGFloat)supported120Target());
    }
    %orig(range);
}

%end

#pragma clang diagnostic pop

static void updateScreenRecordingState(void) {
    BOOL recording = NO;
    Class recorder = NSClassFromString(@"RPScreenRecorder");
    SEL shared = NSSelectorFromString(@"sharedRecorder");
    SEL isRecording = NSSelectorFromString(@"isRecording");
    if (recorder && [recorder respondsToSelector:shared]) {
        id instance = ((id (*)(id, SEL))objc_msgSend)(recorder, shared);
        if (instance && [instance respondsToSelector:isRecording])
            recording = ((BOOL (*)(id, SEL))objc_msgSend)(instance, isRecording);
    }
    @synchronized(g120Lock) { gScreenRecordingActive = recording; }
    refresh120Links();
}

static void registerScreenRecordingLifecycle(void) {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    for (NSString *name in @[@"RPScreenRecorderRecordingDidStartNotification",
                             @"RPScreenRecorderRecordingDidStopNotification",
                             @"RPScreenRecorderRecordingDidFailNotification"]) {
        [center addObserverForName:name object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            (void)note;
            updateScreenRecordingState();
        }];
    }
}

%ctor {
    installDynamicFrameRateHooks();
    updateForce120Pref();
    registerScreenRecordingLifecycle();
    updateScreenRecordingState();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, force120PrefChanged, kPrefChangedNotification, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    // UIKit notification names as strings: no new UIKit link dependency.
    for (NSString *name in @[@"UIApplicationDidBecomeActiveNotification",
                             @"NSProcessInfoPowerStateDidChangeNotification",
                             @"NSProcessInfoThermalStateDidChangeNotification"]) {
        [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *notification) {
            (void)notification;
            refresh120Links();
        }];
    }
}
