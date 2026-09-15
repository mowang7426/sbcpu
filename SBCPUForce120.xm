// ============================================================
// SBCPUForce120.xm —— 全局 120Hz 强制（V4.17.1）
// 注入所有进程：
//   1) hook CADisplayLink（所有 App 的 display link 申报 120Hz）
//   2) hook CALayer.preferredFrameRateRange（iOS 16+，覆盖 CA 转场动画）
//   3) hook displayLinkWithDisplay 变体（覆盖指定 display 创建的 link）
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

// 对 display link 施加 120Hz 需求
static void applyForce120ToLink(CADisplayLink *link) {
    if (!link || !shouldForce120()) return;
    @try {
        if (@available(iOS 15.0, *)) {
            link.preferredFrameRateRange = CAFrameRateRangeMake(120.0, 120.0, 120.0);
        } else {
            link.preferredFramesPerSecond = 120;
        }
    } @catch (NSException *e) {}
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

// 新建 display link 后立即强制（指定 display 的入口，iOS 3+ 公开 API）
+ (CADisplayLink *)displayLinkWithDisplay:(id)display target:(id)target selector:(SEL)selector {
    CADisplayLink *link = %orig;
    applyForce120ToLink(link);
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

%hook CALayer

// iOS 16+：图层动画的帧率需求也强制 120，覆盖 App 打开/退出转场动画
- (void)setPreferredFrameRateRange:(CAFrameRateRange)range {
    if (shouldForce120()) {
        range = CAFrameRateRangeMake(120.0, 120.0, 120.0);
    }
    %orig(range);
}

%end

#pragma clang diagnostic pop

%ctor {
    updateForce120Pref();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, force120PrefChanged, kPrefChangedNotification, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}
