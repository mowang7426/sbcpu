// ============================================================
// SBCPUForce120.xm —— 全局 120Hz 强制（V4.17.0）
// 注入所有进程：hook 每个进程的 CADisplayLink，
// 任何 App 的显示需求都申报 120Hz，ProMotion 协商器自然锁 120。
// 低电量模式 / 系统临界过热时主动让位给系统（硬件保护）。
// ============================================================
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

#define kPrefAppID CFSTR("com.yourname.sbcpufloating")
#define kPrefChangedNotification CFSTR("com.yourname.sbcpufloating.prefschanged")

static BOOL gForce120Enabled = NO;

// 读取主插件偏好：force120HzEnable
static void updateForce120Pref(void) {
    CFBooleanRef val = (CFBooleanRef)CFPreferencesCopyAppValue(CFSTR("force120HzEnable"), kPrefAppID);
    gForce120Enabled = (val && CFBooleanGetValue(val));
    if (val) CFRelease(val);
}

// 主插件偏好变化时同步开关（设置页切换立即生效，无需注销）
static void force120PrefChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    updateForce120Pref();
}

// 是否实际强制：开关开启，且系统未进入低电量/临界过热
static BOOL shouldForce120(void) {
    if (!gForce120Enabled) return NO;
    if (NSProcessInfo.processInfo.isLowPowerModeEnabled) return NO;
    if (NSProcessInfo.processInfo.thermalState == NSProcessInfoThermalStateCritical) return NO;
    return YES;
}

%hook CADisplayLink

// 新建 display link 后立即强制
+ (CADisplayLink *)displayLinkWithTarget:(id)target selector:(SEL)selector {
    CADisplayLink *link = %orig;
    if (shouldForce120()) {
        @try {
            if (@available(iOS 15.0, *)) {
                link.preferredFrameRateRange = CAFrameRateRangeMake(120.0, 120.0, 120.0);
            } else {
                link.preferredFramesPerSecond = 120;
            }
        } @catch (NSException *e) {}
    }
    return link;
}

// iOS 15+：持续强制（系统可能在运行中重设范围，例如切前台/低电量恢复）
- (void)setPreferredFrameRateRange:(CAFrameRateRange)range {
    if (shouldForce120()) {
        range = CAFrameRateRangeMake(120.0, 120.0, 120.0);
    }
    %orig(range);
}

// iOS 15 以下：preferredFramesPerSecond 通道
- (void)setPreferredFramesPerSecond:(NSInteger)framesPerSecond {
    if (shouldForce120()) framesPerSecond = 120;
    %orig(framesPerSecond);
}

%end

%ctor {
    updateForce120Pref();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, force120PrefChanged, kPrefChangedNotification, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}
