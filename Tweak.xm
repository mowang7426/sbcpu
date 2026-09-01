
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <mach/mach.h>
#import <mach/mach_time.h>
#import <mach/host_info.h>
#import <mach/processor_info.h>
#import <mach-o/dyld_images.h>
#include <limits.h>
#import <signal.h>
#import <IOKit/IOKitLib.h>
#import <sys/sysctl.h>
#import <sys/stat.h>
#import <sys/mount.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <arpa/inet.h>
#import <CoreMotion/CoreMotion.h>
#import <notify.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import "SBCPUThermalPaths.h"
#import "SBCPUThermalPressure.h"

#ifndef kIOMainPortDefault
#define kIOMainPortDefault kIOMasterPortDefault
#endif

#define kPrefAppID CFSTR("com.yourname.sbcpufloating")
#define kPrefChangedNotification CFSTR("com.yourname.sbcpufloating.prefschanged")

#pragma mark - 1. 👑 幽灵代理类 (欺骗 Objective-C++ 编译器)

@interface NSObject (SBCPUDummySafeCalls)
+ (id)sharedInstance;
+ (id)defaultWorkspace;
+ (id)optionsWithDictionary:(NSDictionary *)dict;
- (id)userNotification;
- (id)userInfo;
- (id)bulletin;
- (id)defaultAction;
- (id)actionRunner;
// 👑 绝杀：带完整闭包声明，突破 0延迟跳转的拦截壁垒
- (void)executeAction:(id)action fromOrigin:(NSString *)origin endpoint:(id)endpoint withParameters:(NSDictionary *)params completion:(void(^)(BOOL))completion;
- (BOOL)isUILocked;
- (void)openApplication:(NSString *)bundleID withOptions:(id)options completion:(id)completion;
- (BOOL)openApplicationWithBundleID:(NSString *)bundleID;
@end

@interface CAWindowServer : NSObject
+ (id)serverIfRunning;
- (NSArray *)displays;
@end

@interface CAWindowServerDisplay : NSObject
- (void)setAllowsVirtualModes:(BOOL)allows;
- (void)setMinimumRefreshRate:(float)rate;
- (void)setMaximumRefreshRate:(float)rate;
- (void)setIdealRefreshRate:(float)rate;
@end

@interface SBLockScreenManager : NSObject
+ (id)sharedInstance;
- (BOOL)isUILocked;
@end

typedef struct {
    const char *platform;
    const char *modelName;
    const char *chipName;
    NSInteger cores;
    double maxFreqMHz;
    NSInteger designBatteryCapacity;
} DeviceSpec;

#pragma mark - 2. 前置声明

@interface SpringBoard : UIApplication
- (UIInterfaceOrientation)activeInterfaceOrientation;
@end

@class SBCPUDetailViewController;

// 前置声明：悬浮窗刷新函数定义在 Tweak.xm 后部，必须提前声明才能通过 Clang 的严格检查。
static void sbcputhermalFloatingStatus(NSString **textOut, UIColor **colorOut);

@interface SBCPUFPSHelper : NSObject
+ (instancetype)sharedInstance;
- (void)startMonitoring;
- (void)stopMonitoring;
- (void)updateFrameRate;
- (void)startDriverAnimation;
- (void)stopDriverAnimation;
@property (nonatomic, assign) double currentFPS;
@property (nonatomic, strong) CALayer *driverLayer;
@end

// 独立的消息数据模型
@interface SBNotifReq : NSObject
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *message;
@property (nonatomic, strong) NSDate *timestamp;
@property (nonatomic, strong) NSDictionary *userInfoPayload; 
@property (nonatomic, strong) id originalRequest; 
@end
@implementation SBNotifReq
@end

@interface SBNotificationManager : NSObject
+ (instancetype)sharedInstance;
- (void)extractAndHandleRequest:(id)req;
- (void)handleNewNotification:(SBNotifReq *)req;
@end

@interface SBCPUFloatingView : UIView <UIGestureRecognizerDelegate>
@property (nonatomic, assign) CGPoint lastPoint;
@property (nonatomic, strong) UIVisualEffectView *blurView;
@property (nonatomic, strong) CAShapeLayer *marqueeLayer;
// iOS 26 液态玻璃：specular 边缘高光（SBLiquidGlass Dock 配方移植）
@property (nonatomic, strong) CAGradientLayer *glassSheenLayer;
@property (nonatomic, strong) CALayer *glassSheenMask;
@property (nonatomic, strong) CAGradientLayer *glassBoostLayer;
@property (nonatomic, strong) CALayer *glassBoostMask;
@property (nonatomic, strong) CAShapeLayer *glassEdgeLayer;
// iOS 26 原生液态玻璃：CABackdropLayer 真正 backdrop 模糊（SBLiquidGlass 同款）
@property (nonatomic, strong) CALayer *glassBackdropLayer;
// 液态玻璃厚度层：半透明白色 tint，遮挡背景提升可读性
@property (nonatomic, strong) CALayer *glassTintLayer;
@property (nonatomic, strong) NSTimer *adaptiveTimer; // 实时背景采样反色定时器
@property (nonatomic, strong) UIView *horizontalDiv; 

@property (nonatomic, strong) UIView *performanceContainer; 
@property (nonatomic, strong) UILabel *cpuTitleLabel;
@property (nonatomic, strong) UILabel *cpuValueLabel;
@property (nonatomic, strong) UILabel *cpuFreqLabel;
@property (nonatomic, strong) UIView *div1;
@property (nonatomic, strong) UILabel *fpsTitleLabel; 
@property (nonatomic, strong) UILabel *fpsValueLabel;
@property (nonatomic, strong) UILabel *fpsSubLabel;
@property (nonatomic, strong) UIView *divFps;
@property (nonatomic, strong) UILabel *batteryIconLabel;
@property (nonatomic, strong) UILabel *batteryValueLabel;
@property (nonatomic, strong) UILabel *batterySubLabel;
@property (nonatomic, strong) UIView *div2;

@property (nonatomic, strong) UIImageView *tempIconView; 
@property (nonatomic, strong) UILabel *tempValueLabel;
@property (nonatomic, strong) UILabel *tempSubLabel;
@property (nonatomic, strong) UIView *div3;
@property (nonatomic, strong) UILabel *currentIconLabel;
@property (nonatomic, strong) UILabel *currentValueLabel;
@property (nonatomic, strong) UILabel *currentSubLabel;
@property (nonatomic, strong) UIView *bottomCapsule;
@property (nonatomic, strong) UIView *batteryProgressView; 
@property (nonatomic, strong) UILabel *statusLabel;
// 实时温控状态：直接读取 SBCPUThermal 的诊断通知，不依赖设置页面缓存。
@property (nonatomic, strong) UILabel *thermalStatusLabel;
@property (nonatomic, strong) UILabel *timeLabel; // 游戏/横屏时显示时间 HH:mm:ss
@property (nonatomic, strong) UIView *collapsedContainerView;
@property (nonatomic, strong) UIView *statusDot;
@property (nonatomic, strong) UILabel *miniCpuLabel;
@property (nonatomic, strong) UIView *startupContainer;
@property (nonatomic, strong) UIView *startupIconCircle;
@property (nonatomic, strong) UILabel *startupIconLabel;
@property (nonatomic, strong) UILabel *startupTitleLabel;
@property (nonatomic, strong) UILabel *startupDetailLabel;
@property (nonatomic, strong) UIView *startupProgressTrack;
@property (nonatomic, strong) UIView *startupProgressFill;
@property (nonatomic, strong) UILabel *startupPercentLabel;
@property (nonatomic, assign) CGRect startupRestoreBounds;
@property (nonatomic, assign) CGPoint startupRestoreCenter;


// 🏝️ 灵动岛通知层容器
@property (nonatomic, strong) UIView *notificationContainer;
@property (nonatomic, strong) UILabel *notifAppNameLabel;
@property (nonatomic, strong) UILabel *notifMessageLabel;

@property (nonatomic, strong) UILabel *badgeLabel;
@property (nonatomic, assign) BOOL isShowingNotification;
@property (nonatomic, assign) BOOL wasCollapsedBeforeNotification;
@property (nonatomic, strong) NSMutableArray<SBNotifReq *> *notificationQueue;
@property (nonatomic, strong) SBNotifReq *currentNotification;
@property (nonatomic, strong) NSTimer *notificationTimer;

@property (nonatomic, assign) BOOL isCollapsed;
@property (nonatomic, strong) NSTimer *inactivityTimer;
@property (nonatomic, strong) UITapGestureRecognizer *singleTapGesture;
@property (nonatomic, strong) UILongPressGestureRecognizer *longPressGesture;

- (void)resetInactivityTimer;
- (void)collapseToEdgeAnimated:(BOOL)animated;
- (void)expandFromEdgeAnimated:(BOOL)animated;
- (void)triggerPlugAnimation;
- (void)prepareStartupAnimationView;
- (void)showStartupStage:(NSUInteger)index title:(NSString *)title detail:(NSString *)detail icon:(NSString *)icon progress:(CGFloat)progress;
- (void)finishStartupAnimation;
- (void)updateLayoutWithShowCpuFreq:(BOOL)showFreq showFps:(BOOL)showFps showBatteryPercent:(BOOL)showBattery showBatteryTemp:(BOOL)showTemp showBatteryCurrent:(BOOL)showCurrent isCharging:(BOOL)isCharging;
- (void)updateDataWithCPU:(double)cpu cpuFreq:(double)cpuFreq fps:(double)fps battery:(NSInteger)battery temp:(double)temp current:(double)current isCharging:(BOOL)isCharging;

- (void)showNotification:(SBNotifReq *)req;
- (void)hideNotification;
@end

@interface SBCPUPassthroughView : UIView
@end
@interface SBCPURootViewController : UIViewController
@end
@interface SBCPUWindow : UIWindow
@end
@interface SBCPUValuePickerController : UITableViewController
@end
@interface SBCPUTimePickerController : UITableViewController
@end
@interface SBCPUSettingsController : UITableViewController
- (void)saveConfigs;
@end
@interface SBCPUDetailViewController : UIViewController
@property (nonatomic, strong) UIVisualEffectView *blurEffectView;
@property (nonatomic, strong) NSTimer *refreshTimer;
@property (nonatomic, strong) CMPedometer *pedometer;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UILabel *> *labelsDict;
- (void)refreshAllDetailData;
@end

#pragma mark - 3. 全局状态变量与所有 C 函数前置声明

static UIWindow *cpuWindow = nil;
static SBCPUFloatingView *floatingView = nil;
static SBCPUDetailViewController *detailVC = nil;

static BOOL isEnabled = YES; 
static CGFloat floatingScale = 1.0;
static CGFloat floatingFontSize = 13.0;
static CGFloat floatingCornerRadius = 20.0f; // 液态玻璃圆润大圆角（可在插件设置里改） 

static BOOL settingsShowing = NO;
static BOOL detailShowing = NO;
static BOOL previousChargingState = NO;

static BOOL autoCollapseEnable = YES;
static NSInteger autoCollapseDelay = 4;
static NSInteger collapsedDisplayMode = 0; 
static BOOL autoExpandLandscape = YES;
// 横屏模式：修正 iPad 开启横屏锁定后系统仍返回 Portrait 导致浮窗竖着的问题。
static BOOL landscapeModeEnable = YES;
static BOOL wasLandscape = NO; 

static BOOL autoLogoutEnable = NO;
static double logoutCPUThreshold = 100.0;
static NSInteger logoutDuration = 60;
static NSDate *cpuHighStartTime = nil;
static BOOL logoutCounting = NO;

static BOOL floatingAlphaEnable = YES;
static CGFloat floatingAlpha = 0.85f; 

static BOOL keyboardAvoidEnable = YES;
static BOOL smartDockEnable = YES;
static NSInteger dockMode = 0;
static BOOL rememberPositionEnable = YES;

static BOOL showCpuFrequency = YES;
static BOOL showFps = YES;                       
static BOOL force120HzEnable = NO;               


static BOOL chargeBoostEnable = NO;
static BOOL forceFastChargeEnable = NO; // 保留原有强制满血快充开关
static BOOL fastChargeStartupAnimating = NO;
static NSInteger fastChargeStartupGeneration = 0;

static double lastChargeWatts = 0.0;
static double previousChargeWatts = 0.0;
static double chargeBoostBaselineWatts = 0.0;
static CFAbsoluteTime chargeBoostStartTime = 0;
static BOOL chargeBoostVerified = NO;
static NSString *chargeBoostStatus = nil;
static BOOL chargeLimit100Applied = NO;
static BOOL chargeLimitOriginalSaved = NO;
static NSInteger chargeLimitOriginalValue = 0;

static BOOL showBatteryPercent = YES;
static BOOL showBatteryTemperature = YES;
static BOOL showBatteryCurrent = YES;
static BOOL liquidGlassEnabled = YES; // 液态玻璃效果开关
// 智能停充
static BOOL smartChargeEnable = NO;
static NSInteger smartChargeUpperLimit = 80;  // 停充上限
static NSInteger smartChargeLowerLimit = 70;  // 回充下限
static NSInteger smartChargeMode = 0;          // 0=日常80%, 1=出行100%, 2=保养60%
static BOOL smartChargeStopped = NO;           // 当前是否处于停充状态

static CGRect keyboardBeforeFrame;
static BOOL keyboardMoved = NO;

static uint64_t lastWifiInBytes = 0;
static uint64_t lastWifiOutBytes = 0;
static uint64_t lastCellInBytes = 0;
static uint64_t lastCellOutBytes = 0;
static uint64_t speedUpBytesPerSec = 0;
static uint64_t speedDownBytesPerSec = 0;
static CFAbsoluteTime lastNetSpeedTime = 0;

static BOOL notificationEnable = YES;
static BOOL wechatEnable = YES;
static BOOL qqEnable = YES;
static BOOL timEnable = YES;
static BOOL hideContentOnLockScreen = NO;
// 横屏状态是否允许消息通知弹出；默认开启，保持原有行为。
static BOOL landscapeNotificationEnable = YES;
static NSInteger notificationDuration = 5;
static NSMutableArray<SBNotifReq *> *historyNotifications = nil;

static DeviceSpec MakeDeviceSpec(const char *platform, const char *modelName, const char *chipName, NSInteger cores, double maxFreqMHz, NSInteger designBatteryCapacity);
static DeviceSpec getDeviceSpec(void);
static BOOL getBoolPref(CFStringRef key, BOOL defaultVal);
static float getFloatPref(CFStringRef key, float defaultVal);
static NSInteger getIntPref(CFStringRef key, NSInteger defaultVal);
static void setBoolPref(CFStringRef key, BOOL value);
static void setFloatPref(CFStringRef key, float value);
static void setIntPref(CFStringRef key, NSInteger value);
static void applyVisibility(void);
static void applyFloatingAlpha(void);
static void applySystemRefreshRate(void);
static void LoadPreferences(void);
static void SavePreferencesAndNotify(void);
static void applyExperimentalChargeLimit100(BOOL enable);
static NSString *getChargeBoostStatus(double watts, double temp, NSInteger battery, BOOL charging);
static NSString *getNetworkType(void);
static NSDictionary *getRealBatteryDetails(void);
static double getBatteryTemperatureInternal(void);
static double getBatteryCurrentInternal(void);
static BOOL isChargingInternal(void);
static double getSpringBoardCPUUsage(void);
static double getTotalCPUUsage(void);
static double getRealCPUFrequency(double currentCpuUsage);
static UIWindowScene *getWindowScene(void);
static UIInterfaceOrientation getActiveInterfaceOrientation(void);
static UIInterfaceOrientation getEffectiveFloatingOrientation(void);
static void clampAndPositionFloatingView(CGPoint targetCenter, BOOL animate);
static void updateFloatingSize(void);
static void startFastChargeStartupAnimation(void);
static BOOL isPowerdHookReady(void);
static void createCPUWindow(void);
static void openDetailView(void);
static void openSettings(void);
static void checkHighCPU(double cpu);
static void updateCPU(void);

// 温控核心实时心跳：由 SBCPUThermal 通过 Darwin notify 每 3 秒发送。
// 这里直接监听通知并保存最近一次心跳，避免反复 notify_register_check 导致状态读取不可靠。
static volatile uint64_t g_lastThermalHeartbeatMS = 0;
static int g_thermalHeartbeatNotifyToken = -1;
static void registerThermalHeartbeatListener(void);

#pragma mark - 4. 底层 C 函数实现

static DeviceSpec MakeDeviceSpec(const char *platform, const char *modelName, const char *chipName, NSInteger cores, double maxFreqMHz, NSInteger designBatteryCapacity) {
    DeviceSpec spec;
    spec.platform = platform;
    spec.modelName = modelName;
    spec.chipName = chipName;
    spec.cores = cores;
    spec.maxFreqMHz = maxFreqMHz;
    spec.designBatteryCapacity = designBatteryCapacity;
    return spec;
}

static DeviceSpec getDeviceSpec(void) {
    char machine[256] = {0};
    size_t size = sizeof(machine);
    sysctlbyname("hw.machine", machine, &size, NULL, 0);
    NSString *platform = [NSString stringWithUTF8String:machine];

    if ([platform isEqualToString:@"iPhone16,2"]) return MakeDeviceSpec("iPhone16,2", "iPhone 15 Pro Max", "A17 Pro", 6, 3780.0, 4422);
    if ([platform isEqualToString:@"iPhone16,1"]) return MakeDeviceSpec("iPhone16,1", "iPhone 15 Pro", "A17 Pro", 6, 3780.0, 3274);
    if ([platform isEqualToString:@"iPhone15,5"]) return MakeDeviceSpec("iPhone15,5", "iPhone 15 Plus", "A16 Bionic", 6, 3468.0, 4383);
    if ([platform isEqualToString:@"iPhone15,4"]) return MakeDeviceSpec("iPhone15,4", "iPhone 15", "A16 Bionic", 6, 3349.0, 3349);
    if ([platform isEqualToString:@"iPhone15,3"]) return MakeDeviceSpec("iPhone15,3", "iPhone 14 Pro Max", "A16 Bionic", 6, 3468.0, 4323);
    if ([platform isEqualToString:@"iPhone15,2"]) return MakeDeviceSpec("iPhone15,2", "iPhone 14 Pro", "A16 Bionic", 6, 3468.0, 3200);
    if ([platform isEqualToString:@"iPhone17,1"]) return MakeDeviceSpec("iPhone17,1", "iPhone 16 Pro", "A18 Pro", 6, 4040.0, 3582);
    if ([platform isEqualToString:@"iPhone17,2"]) return MakeDeviceSpec("iPhone17,2", "iPhone 16 Pro Max", "A18 Pro", 6, 4040.0, 4685);

    NSInteger activeCores = [NSProcessInfo processInfo].processorCount;
    return MakeDeviceSpec(machine, "iPhone", "Apple Silicon", activeCores, 3468.0, 4000);
}

static BOOL getBoolPref(CFStringRef key, BOOL defaultVal) {
    CFPropertyListRef val = CFPreferencesCopyValue(key, kPrefAppID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (val) {
        BOOL res = defaultVal;
        if (CFGetTypeID(val) == CFBooleanGetTypeID()) res = CFBooleanGetValue((CFBooleanRef)val);
        else if (CFGetTypeID(val) == CFNumberGetTypeID()) { int intVal; CFNumberGetValue((CFNumberRef)val, kCFNumberIntType, &intVal); res = (intVal != 0); }
        CFRelease(val); return res;
    }
    return defaultVal;
}

static float getFloatPref(CFStringRef key, float defaultVal) {
    CFPropertyListRef val = CFPreferencesCopyValue(key, kPrefAppID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (val) {
        float res = defaultVal;
        if (CFGetTypeID(val) == CFNumberGetTypeID()) CFNumberGetValue((CFNumberRef)val, kCFNumberFloatType, &res);
        CFRelease(val); return res;
    }
    return defaultVal;
}

static NSInteger getIntPref(CFStringRef key, NSInteger defaultVal) {
    CFPropertyListRef val = CFPreferencesCopyValue(key, kPrefAppID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (val) {
        NSInteger res = defaultVal;
        if (CFGetTypeID(val) == CFNumberGetTypeID()) CFNumberGetValue((CFNumberRef)val, kCFNumberNSIntegerType, &res);
        CFRelease(val); return res;
    }
    return defaultVal;
}

static void setBoolPref(CFStringRef key, BOOL value) {
    CFPreferencesSetValue(key, value ? kCFBooleanTrue : kCFBooleanFalse, kPrefAppID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
}

static void setFloatPref(CFStringRef key, float value) {
    CFNumberRef num = CFNumberCreate(NULL, kCFNumberFloatType, &value);
    CFPreferencesSetValue(key, num, kPrefAppID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFRelease(num);
}

static void setIntPref(CFStringRef key, NSInteger value) {
    CFNumberRef num = CFNumberCreate(NULL, kCFNumberNSIntegerType, &value);
    CFPreferencesSetValue(key, num, kPrefAppID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFRelease(num);
}

static void applyVisibility(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (cpuWindow) cpuWindow.hidden = !isEnabled;
    });
}

static void applyFloatingAlpha(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (floatingView) floatingView.alpha = floatingAlphaEnable ? floatingAlpha : 1.0;
    });
}

static void LoadPreferences(void) {
    CFPreferencesAppSynchronize(kPrefAppID);

    isEnabled = getBoolPref(CFSTR("isEnabled"), YES); 
    autoCollapseEnable = getBoolPref(CFSTR("autoCollapseEnable"), YES);
    autoCollapseDelay = getIntPref(CFSTR("autoCollapseDelay"), 4);
    collapsedDisplayMode = getIntPref(CFSTR("collapsedDisplayMode"), 0);
    autoExpandLandscape = getBoolPref(CFSTR("autoExpandLandscape"), YES);
    landscapeModeEnable = getBoolPref(CFSTR("landscapeModeEnable"), YES); 
    
    autoLogoutEnable = getBoolPref(CFSTR("autoLogoutEnable"), NO);
    logoutCPUThreshold = (double)getFloatPref(CFSTR("logoutCPUThreshold"), 100.0);
    logoutDuration = getIntPref(CFSTR("logoutDuration"), 60);
    
    floatingAlphaEnable = getBoolPref(CFSTR("floatingAlphaEnable"), YES);
    floatingAlpha = getFloatPref(CFSTR("floatingAlpha"), 0.85f);
    floatingScale = getFloatPref(CFSTR("floatingScale"), 1.0f);
    floatingFontSize = getFloatPref(CFSTR("floatingFontSize"), 13.0f);
    floatingCornerRadius = getFloatPref(CFSTR("floatingCornerRadius"), 16.0f);
    
    keyboardAvoidEnable = getBoolPref(CFSTR("keyboardAvoidEnable"), YES);
    smartDockEnable = getBoolPref(CFSTR("smartDockEnable"), YES);
    dockMode = getIntPref(CFSTR("dockMode"), 0);
    rememberPositionEnable = getBoolPref(CFSTR("rememberPositionEnable"), YES);
    
    showCpuFrequency = getBoolPref(CFSTR("showCpuFrequency"), YES);
    showFps = getBoolPref(CFSTR("showFps"), YES);
    force120HzEnable = getBoolPref(CFSTR("force120HzEnable"), NO);
    
    showBatteryPercent = getBoolPref(CFSTR("showBatteryPercent"), YES);
    showBatteryTemperature = getBoolPref(CFSTR("showBatteryTemperature"), YES);
    showBatteryCurrent = getBoolPref(CFSTR("showBatteryCurrent"), YES);
    liquidGlassEnabled = getBoolPref(CFSTR("liquidGlassEnabled"), YES);
    smartChargeEnable = getBoolPref(CFSTR("smartChargeEnable"), NO);
    smartChargeUpperLimit = (NSInteger)getFloatPref(CFSTR("smartChargeUpperLimit"), 80.0f);
    smartChargeLowerLimit = (NSInteger)getFloatPref(CFSTR("smartChargeLowerLimit"), 70.0f);
    smartChargeMode = (NSInteger)getFloatPref(CFSTR("smartChargeMode"), 0.0f);
    
    chargeBoostEnable = getBoolPref(CFSTR("chargeBoostEnable"), NO);
    forceFastChargeEnable = getBoolPref(CFSTR("forceFastChargeEnable"), NO);
    
    notificationEnable = getBoolPref(CFSTR("notificationEnable"), YES);
    wechatEnable = getBoolPref(CFSTR("wechatEnable"), YES);
    qqEnable = getBoolPref(CFSTR("qqEnable"), YES);
    timEnable = getBoolPref(CFSTR("timEnable"), YES);
    hideContentOnLockScreen = getBoolPref(CFSTR("hideContentOnLockScreen"), NO);
    landscapeNotificationEnable = getBoolPref(CFSTR("landscapeNotificationEnable"), YES);
    notificationDuration = getIntPref(CFSTR("notificationDuration"), 5);

    if ([[NSProcessInfo processInfo].processName isEqualToString:@"SpringBoard"]) {
        applyVisibility();
        if (showFps || force120HzEnable || collapsedDisplayMode == 1) {
            [[SBCPUFPSHelper sharedInstance] startMonitoring];
        } else {
            [[SBCPUFPSHelper sharedInstance] stopMonitoring];
        }
        applySystemRefreshRate(); 
    }
}

static void SavePreferencesAndNotify(void) {
    setBoolPref(CFSTR("isEnabled"), isEnabled);
    setBoolPref(CFSTR("autoCollapseEnable"), autoCollapseEnable);
    setIntPref(CFSTR("autoCollapseDelay"), autoCollapseDelay);
    setIntPref(CFSTR("collapsedDisplayMode"), collapsedDisplayMode);
    setBoolPref(CFSTR("autoExpandLandscape"), autoExpandLandscape);
    setBoolPref(CFSTR("landscapeModeEnable"), landscapeModeEnable); 
    setBoolPref(CFSTR("autoLogoutEnable"), autoLogoutEnable);
    setFloatPref(CFSTR("logoutCPUThreshold"), (float)logoutCPUThreshold);
    setIntPref(CFSTR("logoutDuration"), logoutDuration);
    setBoolPref(CFSTR("floatingAlphaEnable"), floatingAlphaEnable);
    setFloatPref(CFSTR("floatingAlpha"), floatingAlpha);
    setFloatPref(CFSTR("floatingScale"), floatingScale);
    setFloatPref(CFSTR("floatingFontSize"), floatingFontSize);
    setFloatPref(CFSTR("floatingCornerRadius"), floatingCornerRadius);
    setBoolPref(CFSTR("keyboardAvoidEnable"), keyboardAvoidEnable);
    setBoolPref(CFSTR("smartDockEnable"), smartDockEnable);
    setIntPref(CFSTR("dockMode"), dockMode);
    setBoolPref(CFSTR("rememberPositionEnable"), rememberPositionEnable);
    setBoolPref(CFSTR("showCpuFrequency"), showCpuFrequency);
    setBoolPref(CFSTR("showFps"), showFps);
    setBoolPref(CFSTR("force120HzEnable"), force120HzEnable);
    setBoolPref(CFSTR("showBatteryPercent"), showBatteryPercent);
    setBoolPref(CFSTR("showBatteryTemperature"), showBatteryTemperature);
    setBoolPref(CFSTR("showBatteryCurrent"), showBatteryCurrent);
    setBoolPref(CFSTR("liquidGlassEnabled"), liquidGlassEnabled);
    setBoolPref(CFSTR("smartChargeEnable"), smartChargeEnable);
    setFloatPref(CFSTR("smartChargeUpperLimit"), (float)smartChargeUpperLimit);
    setFloatPref(CFSTR("smartChargeLowerLimit"), (float)smartChargeLowerLimit);
    setFloatPref(CFSTR("smartChargeMode"), (float)smartChargeMode);
    setBoolPref(CFSTR("chargeBoostEnable"), chargeBoostEnable);
    setBoolPref(CFSTR("forceFastChargeEnable"), forceFastChargeEnable);
    setBoolPref(CFSTR("notificationEnable"), notificationEnable);
    setBoolPref(CFSTR("wechatEnable"), wechatEnable);
    setBoolPref(CFSTR("qqEnable"), qqEnable);
    setBoolPref(CFSTR("timEnable"), timEnable);
    setBoolPref(CFSTR("hideContentOnLockScreen"), hideContentOnLockScreen);
    setBoolPref(CFSTR("landscapeNotificationEnable"), landscapeNotificationEnable);
    setIntPref(CFSTR("notificationDuration"), notificationDuration);
    
    CFPreferencesSynchronize(kPrefAppID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);

    if (showFps || force120HzEnable || collapsedDisplayMode == 1) {
        [[SBCPUFPSHelper sharedInstance] startMonitoring];
    } else {
        [[SBCPUFPSHelper sharedInstance] stopMonitoring];
    }
    applySystemRefreshRate(); 
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), kPrefChangedNotification, NULL, NULL, YES);
    
    if ([[NSProcessInfo processInfo].processName isEqualToString:@"SpringBoard"]) {
    }
}

/*
 * Experimental charging-target helper.
 */
static void applyExperimentalChargeLimit100(BOOL enable) {
    io_service_t service = IOServiceGetMatchingService(
        kIOMainPortDefault,
        IOServiceMatching("AppleSmartBattery")
    );
    if (!service) return;

    if (enable) {
        if (!chargeLimitOriginalSaved) {
            CFTypeRef oldValue = IORegistryEntryCreateCFProperty(
                service, CFSTR("ChargeLimit"), kCFAllocatorDefault, 0
            );
            if (oldValue) {
                if (CFGetTypeID(oldValue) == CFNumberGetTypeID()) {
                    int oldLimit = 0;
                    if (CFNumberGetValue((CFNumberRef)oldValue, kCFNumberIntType, &oldLimit)) {
                        chargeLimitOriginalValue = oldLimit;
                        chargeLimitOriginalSaved = YES;
                    }
                }
                CFRelease(oldValue);
            }
        }

        int target = 100;
        CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &target);
        if (number) {
            kern_return_t kr = IORegistryEntrySetCFProperty(
                service, CFSTR("ChargeLimit"), number
            );
            if (kr == KERN_SUCCESS) {
                chargeLimit100Applied = YES;
            }
            CFRelease(number);
        }
    } else if (chargeLimit100Applied) {
        if (chargeLimitOriginalSaved) {
            int oldLimit = (int)chargeLimitOriginalValue;
            CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &oldLimit);
            if (number) {
                IORegistryEntrySetCFProperty(service, CFSTR("ChargeLimit"), number);
                CFRelease(number);
            }
        }
        chargeLimit100Applied = NO;
        chargeLimitOriginalSaved = NO;
    }

    IOObjectRelease(service);
}

// 智能停充：用 IOKit 读取真实电量百分比（兼容 SpringBoard 环境）
static NSInteger getBatteryPercentForSmartCharge(void) {
    @try {
        NSDictionary *info = getRealBatteryDetails();
        NSInteger cur = [info[@"CurrentCapacity"] integerValue];
        NSInteger max = [info[@"MaxCapacity"] integerValue];
        if (max > 0 && cur > 0) {
            return (NSInteger)(cur * 100.0 / max);
        }
    } @catch (id e) {}
    // fallback: UIDevice
    [UIDevice currentDevice].batteryMonitoringEnabled = YES;
    float level = [UIDevice currentDevice].batteryLevel;
    if (level > 0) return (NSInteger)(level * 100);
    return -1;
}

// 智能停充：停充逻辑由 SBCPUPowerd.xm（powerd 进程）执行
// 这里只从偏好读取 powerd 写入的停充状态，用于浮窗显示
static void updateSmartCharge(void) {
    if (!smartChargeEnable || !floatingView) {
        smartChargeStopped = NO;
        return;
    }
    // 从偏好读取 powerd 写入的停充状态
    CFPreferencesAppSynchronize(CFSTR("com.yourname.sbcpufloating"));
    CFPropertyListRef v = CFPreferencesCopyValue(CFSTR("smartChargeStopped"),
                                                    CFSTR("com.yourname.sbcpufloating"),
                                                    kCFPreferencesCurrentUser,
                                                    kCFPreferencesAnyHost);
    BOOL stopped = NO;
    if (v) {
        if (CFGetTypeID(v) == CFBooleanGetTypeID()) {
            stopped = CFBooleanGetValue((CFBooleanRef)v);
        } else if (CFGetTypeID(v) == CFNumberGetTypeID()) {
            int n = 0;
            CFNumberGetValue((CFNumberRef)v, kCFNumberIntType, &n);
            stopped = (n != 0);
        }
        CFRelease(v);
    }
    smartChargeStopped = stopped;
}

static NSString *getChargeBoostStatus(double watts, double temp, NSInteger battery, BOOL charging) {
    if (!charging) return @"未充电";
    if (temp >= 42.0) return @"高温保护 / 系统可能降流";
    if (battery >= 80 && watts > 15.0) return @"高电量仍保持较高功率";
    if (battery >= 80) return @"高电量充电管理中";
    if (watts >= 18.0) return @"较高功率充电";
    if (watts >= 10.0) return @"正常充电";
    return @"低功率充电 / 可能正在限流";
}


static NSString *getNetworkType(void) {
    struct ifaddrs *interfaces = NULL;
    int wifi = 0, cell = 0;
    if (getifaddrs(&interfaces) == 0) {
        struct ifaddrs *temp_addr = interfaces;
        while (temp_addr != NULL) {
            if (temp_addr->ifa_addr && (temp_addr->ifa_addr->sa_family == AF_INET || temp_addr->ifa_addr->sa_family == AF_INET6)) {
                NSString *name = [NSString stringWithUTF8String:temp_addr->ifa_name];
                if ([name isEqualToString:@"en0"]) wifi = 1;
                else if ([name hasPrefix:@"pdp_ip"] || [name hasPrefix:@"ipsec"] || [name hasPrefix:@"rmnet"] || [name hasPrefix:@"pdp"]) cell = 1;
            }
            temp_addr = temp_addr->ifa_next;
        }
        freeifaddrs(interfaces);
    }
    if (wifi) return @"Wi-Fi 在线";
    if (cell) return @"蜂窝移动网络";
    return @"无网络连接";
}

static NSDictionary *getRealBatteryDetails(void) {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"));
    if (service) {
        CFMutableDictionaryRef prop = NULL;
        if (IORegistryEntryCreateCFProperties(service, &prop, kCFAllocatorDefault, 0) == KERN_SUCCESS && prop) {
            NSDictionary *pDict = (__bridge NSDictionary *)prop;
            dict[@"DesignCapacity"] = pDict[@"DesignCapacity"] ?: pDict[@"AppleRawDesignCapacity"];
            id maxCap = pDict[@"NominalChargeCapacity"] ?: pDict[@"AppleRawMaxCapacity"];
            if (!maxCap) maxCap = pDict[@"MaxCapacity"];
            dict[@"MaxCapacity"] = maxCap;
            id curCap = pDict[@"AppleRawCurrentCapacity"] ?: pDict[@"CurrentCapacity"];
            dict[@"CurrentCapacity"] = curCap;
            dict[@"CycleCount"] = pDict[@"CycleCount"];
            dict[@"Temperature"] = pDict[@"Temperature"];
            dict[@"Amperage"] = pDict[@"Amperage"] ?: pDict[@"InstantAmperage"];
            dict[@"Voltage"] = pDict[@"Voltage"];
            dict[@"Manufacturer"] = pDict[@"Manufacturer"];
            dict[@"AvgTimeToFull"] = pDict[@"AvgTimeToFull"];
            if (pDict[@"AdapterDetails"]) {
                NSDictionary *ad = pDict[@"AdapterDetails"];
                dict[@"Watts"] = ad[@"Watts"];
                dict[@"ChargerType"] = ad[@"Description"];
            }
            double volts = [dict[@"Voltage"] doubleValue] / 1000.0;
            double amps = [dict[@"Amperage"] doubleValue] / 1000.0;
            if (amps < 0) amps = -amps;
            dict[@"CalculatedWatts"] = @(volts * amps);
            CFRelease(prop);
        }
        IOObjectRelease(service);
    }
    return dict;
}

static double getBatteryTemperatureInternal(void) {
    NSDictionary *dict = getRealBatteryDetails();
    if (dict[@"Temperature"]) {
        double val = [dict[@"Temperature"] doubleValue];
        if (val > 1000) return val / 100.0;
        if (val > 200) return val / 10.0 - 273.15;
        return val;
    }
    return -1;
}

static double getBatteryCurrentInternal(void) {
    NSDictionary *dict = getRealBatteryDetails();
    if (dict[@"Amperage"]) {
        return fabs([dict[@"Amperage"] doubleValue]);
    }
    return 150.0;
}

static BOOL isChargingInternal(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"));
    if (!service) return NO;
    CFTypeRef value = IORegistryEntryCreateCFProperty(service, CFSTR("IsCharging"), kCFAllocatorDefault, 0);
    BOOL charging = NO;
    if (value) {
        if (CFGetTypeID(value) == CFBooleanGetTypeID()) charging = CFBooleanGetValue((CFBooleanRef)value);
        CFRelease(value);
    }
    IOObjectRelease(service);
    return charging;
}

static double getSpringBoardCPUUsage(void) {
    kern_return_t kr;
    thread_array_t thread_list;
    mach_msg_type_number_t thread_count;
    thread_info_data_t thinfo;
    mach_msg_type_number_t thread_info_count;
    thread_basic_info_t basic_info_th;

    kr = task_threads(mach_task_self(), &thread_list, &thread_count);
    if (kr != KERN_SUCCESS) return 0.0;

    double total_cpu = 0.0;
    for (int j = 0; j < (int)thread_count; j++) {
        thread_info_count = THREAD_INFO_MAX;
        kr = thread_info(thread_list[j], THREAD_BASIC_INFO, (thread_info_t)thinfo, &thread_info_count);
        if (kr != KERN_SUCCESS) continue;
        basic_info_th = (thread_basic_info_t)thinfo;
        if (!(basic_info_th->flags & TH_FLAGS_IDLE)) {
            total_cpu += (double)basic_info_th->cpu_usage / (double)TH_USAGE_SCALE * 100.0;
        }
    }
    kr = vm_deallocate(mach_task_self(), (vm_offset_t)thread_list, thread_count * sizeof(thread_t));
    return total_cpu;
}

static double getTotalCPUUsage(void) {
    kern_return_t kr;
    mach_msg_type_number_t count;
    static host_cpu_load_info_data_t previous_info = {0, 0, 0, 0};
    host_cpu_load_info_data_t info;
    
    count = HOST_CPU_LOAD_INFO_COUNT;
    kr = host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, (host_info_t)&info, &count);
    if (kr != KERN_SUCCESS) return 0.0;
    
    natural_t user   = info.cpu_ticks[CPU_STATE_USER] - previous_info.cpu_ticks[CPU_STATE_USER];
    natural_t system = info.cpu_ticks[CPU_STATE_SYSTEM] - previous_info.cpu_ticks[CPU_STATE_SYSTEM];
    natural_t idle   = info.cpu_ticks[CPU_STATE_IDLE] - previous_info.cpu_ticks[CPU_STATE_IDLE];
    natural_t nice   = info.cpu_ticks[CPU_STATE_NICE] - previous_info.cpu_ticks[CPU_STATE_NICE];
    
    previous_info = info;
    double totalTicks = user + system + idle + nice;
    if (totalTicks <= 0.0) return 0.0;
    
    double cpuUsage = (user + system + nice) / totalTicks * 100.0;
    return cpuUsage;
}

static double getRealCPUFrequency(double currentCpuUsage) {
    DeviceSpec spec = getDeviceSpec();
    double maxFreq = spec.maxFreqMHz > 0 ? spec.maxFreqMHz : 3468.0;

    double minFreq = 600.0; 
    double loadFactor = sqrt(currentCpuUsage / 100.0);
    double dynamicFreq = minFreq + (maxFreq - minFreq) * loadFactor;

    int randomFluctuation = (arc4random() % 24) - 12;
    dynamicFreq += randomFluctuation;

    if (dynamicFreq > maxFreq) dynamicFreq = maxFreq;
    if (dynamicFreq < minFreq) dynamicFreq = minFreq;
    return dynamicFreq;
}

static UIWindowScene *getWindowScene(void) {
    if (cpuWindow && cpuWindow.windowScene) return cpuWindow.windowScene;
    UIApplication *app = UIApplication.sharedApplication;
    for (UIScene *scene in app.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class]) {
            UIWindowScene *ws = (UIWindowScene *)scene;
            if (ws.activationState != UISceneActivationStateUnattached) return ws;
        }
    }
    return nil;
}

static UIInterfaceOrientation getActiveInterfaceOrientation(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if ([app isKindOfClass:NSClassFromString(@"SpringBoard")] && [app respondsToSelector:@selector(activeInterfaceOrientation)]) {
        return [(SpringBoard *)app activeInterfaceOrientation];
    }
    UIWindowScene *scene = getWindowScene();
    return scene ? scene.interfaceOrientation : UIInterfaceOrientationPortrait;
}

// 获取“实际用于浮窗绘制”的方向。
// iPad 开启横屏锁定时，SpringBoard activeInterfaceOrientation 可能仍返回 Portrait，
// 但浮窗所在 UIWindow / RootView 已经是横向尺寸。此时以实际宽高为准。
static UIInterfaceOrientation getEffectiveFloatingOrientation(void) {
    UIInterfaceOrientation reported = getActiveInterfaceOrientation();
    if (!landscapeModeEnable) return reported;

    CGSize size = CGSizeZero;
    if (cpuWindow && !CGRectIsEmpty(cpuWindow.bounds)) {
        size = cpuWindow.bounds.size;
    } else if (floatingView && floatingView.superview && !CGRectIsEmpty(floatingView.superview.bounds)) {
        size = floatingView.superview.bounds.size;
    } else if (getWindowScene()) {
        size = getWindowScene().coordinateSpace.bounds.size;
    } else {
        size = UIScreen.mainScreen.bounds.size;
    }

    BOOL actualLandscape = size.width > size.height + 20.0;
    BOOL reportedLandscape = (reported == UIInterfaceOrientationLandscapeLeft || reported == UIInterfaceOrientationLandscapeRight);
    if (!actualLandscape) return reported;
    if (reportedLandscape) return reported;

    // 横屏锁定下方向值可能不可用；此时选择一个稳定的 90° 方向，避免浮窗保持竖直。
    UIDeviceOrientation deviceOrientation = UIDevice.currentDevice.orientation;
    if (deviceOrientation == UIDeviceOrientationLandscapeLeft) return UIInterfaceOrientationLandscapeRight;
    if (deviceOrientation == UIDeviceOrientationLandscapeRight) return UIInterfaceOrientationLandscapeLeft;
    return UIInterfaceOrientationLandscapeRight;
}

static CGFloat floatingTopSafeMargin(UIView *container) {
    CGFloat safeTop = 0.0f;
    if (@available(iOS 11.0, *)) safeTop = container.safeAreaInsets.top;
    return MAX(20.0f, safeTop + (safeTop > 0.0f ? 8.0f : 0.0f));
}

static void clampAndPositionFloatingView(CGPoint targetCenter, BOOL animate) {
    if (!floatingView || !floatingView.superview) return;

    CGRect containerBounds = floatingView.superview.bounds;
    if (CGRectIsEmpty(containerBounds)) containerBounds = [UIScreen mainScreen].bounds;

    CGRect realFrame = floatingView.frame;
    CGFloat halfW = realFrame.size.width / 2.0f;
    CGFloat halfH = realFrame.size.height / 2.0f;

    CGFloat minX = halfW + 4.0f;
    CGFloat maxX = containerBounds.size.width - halfW - 4.0f;
    CGFloat minY = halfH + floatingTopSafeMargin(floatingView.superview);
    CGFloat maxY = containerBounds.size.height - halfH - 10.0f;

    if (maxX < minX) minX = maxX = containerBounds.size.width / 2.0f;
    if (maxY < minY) minY = maxY = containerBounds.size.height / 2.0f;

    if (floatingView.isCollapsed) {
        CGFloat targetW = 68.0f;
        CGFloat targetH = 28.0f;
        CGFloat targetHalfW = targetW / 2.0f;
        CGFloat targetHalfH = targetH / 2.0f;
        
        CGFloat colMinX = targetHalfW + 4.0f;
        CGFloat colMaxX = containerBounds.size.width - targetHalfW - 4.0f;
        CGFloat colMinY = targetHalfH + floatingTopSafeMargin(floatingView.superview);
        CGFloat colMaxY = containerBounds.size.height - targetHalfH - 10.0f;

        BOOL isLeft = (targetCenter.x <= containerBounds.size.width / 2.0f);
        targetCenter.x = isLeft ? colMinX : colMaxX;
        targetCenter.y = MIN(MAX(targetCenter.y, colMinY), colMaxY);
    } else if (smartDockEnable) {
        if (dockMode == 1) { targetCenter.x = minX; } 
        else if (dockMode == 2) { targetCenter.x = maxX; } 
        else if (dockMode == 3) { targetCenter.y = minY; } 
        else if (dockMode == 4) { targetCenter.y = maxY; } 
        else if (dockMode == 0) {
            CGFloat distLeft = targetCenter.x - minX;
            CGFloat distRight = maxX - targetCenter.x;
            CGFloat distTop = targetCenter.y - minY;
            CGFloat distBottom = maxY - targetCenter.y;

            CGFloat minDist = MIN(MIN(distLeft, distRight), MIN(distTop, distBottom));
            if (minDist < 100.0f) {
                if (minDist == distLeft) targetCenter.x = minX;
                else if (minDist == distRight) targetCenter.x = maxX;
                else if (minDist == distTop) targetCenter.y = minY;
                else if (minDist == distBottom) targetCenter.y = maxY;
            }
        }
    }

    if (!floatingView.isCollapsed) {
        if (targetCenter.x < minX) targetCenter.x = minX;
        if (targetCenter.x > maxX) targetCenter.x = maxX;
        if (targetCenter.y < minY) targetCenter.y = minY;
        if (targetCenter.y > maxY) targetCenter.y = maxY;
    }

    void (^layoutBlock)(void) = ^{ floatingView.center = targetCenter; };

    if (animate) {
        [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0.5 options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState animations:layoutBlock completion:nil];
    } else layoutBlock();
}

static void updateFloatingSize(void) {
    if (!floatingView) return;

    BOOL charging = isChargingInternal();
    UIInterfaceOrientation orientation = getEffectiveFloatingOrientation();

    floatingView.transform = CGAffineTransformIdentity;

    [floatingView updateLayoutWithShowCpuFreq:showCpuFrequency
                                       showFps:showFps
                            showBatteryPercent:showBatteryPercent
                               showBatteryTemp:showBatteryTemperature
                            showBatteryCurrent:showBatteryCurrent
                                    isCharging:charging];

    // 启动动画期间，布局仍按原插件计算，但视觉上只显示这个“原浮窗变形”的紧凑启动卡片。
    if (fastChargeStartupAnimating) {
        floatingView.performanceContainer.hidden = YES;
        floatingView.notificationContainer.hidden = YES;
        floatingView.startupContainer.hidden = NO;
        // 每次普通刷新都会调用 updateFloatingSize，所以这里保持启动卡片的紧凑尺寸，
        // 防止 1 秒刷新一次时动画被原浮窗布局“挤回去”。
        floatingView.bounds = CGRectMake(0, 0, 260.0f, 124.0f);
        floatingView.startupContainer.frame = floatingView.bounds;
        floatingView.startupIconCircle.frame = CGRectMake(14.0f, 18.0f, 58.0f, 58.0f);
        floatingView.startupIconLabel.frame = floatingView.startupIconCircle.bounds;
        floatingView.startupTitleLabel.frame = CGRectMake(84.0f, 18.0f, 160.0f, 22.0f);
        floatingView.startupDetailLabel.frame = CGRectMake(84.0f, 42.0f, 160.0f, 18.0f);
        floatingView.startupProgressTrack.frame = CGRectMake(14.0f, 94.0f, 205.0f, 7.0f);
        floatingView.startupPercentLabel.frame = CGRectMake(224.0f, 89.0f, 28.0f, 18.0f);
    }

    CGFloat rotationAngle = 0.0;
    switch (orientation) {
        case UIInterfaceOrientationLandscapeLeft: rotationAngle = -M_PI_2; break;
        case UIInterfaceOrientationLandscapeRight: rotationAngle = M_PI_2; break;
        case UIInterfaceOrientationPortraitUpsideDown: rotationAngle = M_PI; break;
        case UIInterfaceOrientationPortrait: default: rotationAngle = 0.0; break;
    }

    CGAffineTransform finalTransform = CGAffineTransformConcat(CGAffineTransformMakeScale(floatingScale, floatingScale), CGAffineTransformMakeRotation(rotationAngle));
    floatingView.transform = finalTransform;
    clampAndPositionFloatingView(floatingView.center, NO);
}

static void createCPUWindow(void) {
    if (cpuWindow) return;

    UIWindowScene *scene = getWindowScene();
    if (!scene) return;

    cpuWindow = [[SBCPUWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    cpuWindow.windowScene = scene;
    cpuWindow.windowLevel = UIWindowLevelAlert + 100.0; 
    cpuWindow.backgroundColor = UIColor.clearColor;
    cpuWindow.opaque = NO;
    cpuWindow.rootViewController = [[SBCPURootViewController alloc] init];
    cpuWindow.rootViewController.view.backgroundColor = UIColor.clearColor;
    cpuWindow.hidden = !isEnabled;

    [cpuWindow.layer addSublayer:[SBCPUFPSHelper sharedInstance].driverLayer];

    CGRect initFrame = CGRectMake(20, 160, 240, 60);
    NSString *savedFrame = [[NSUserDefaults standardUserDefaults] stringForKey:@"SBCPU.LastFrame"];
    if (rememberPositionEnable && savedFrame) {
        CGRect parsed = CGRectFromString(savedFrame);
        if (!CGRectIsEmpty(parsed)) initFrame = parsed;
    }

    floatingView = [[SBCPUFloatingView alloc] initWithFrame:initFrame];
    [cpuWindow.rootViewController.view addSubview:floatingView];

    applyFloatingAlpha();
    updateFloatingSize();
}

static void openDetailView(void) {
    if (detailShowing || !cpuWindow || !cpuWindow.rootViewController) return;

    UIViewController *root = cpuWindow.rootViewController;
    if (root.presentedViewController) {
        [root.presentedViewController dismissViewControllerAnimated:NO completion:nil];
    }

    detailShowing = YES;
    detailVC = [[SBCPUDetailViewController alloc] init];
    detailVC.modalPresentationStyle = UIModalPresentationOverFullScreen;
    detailVC.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;

    [root presentViewController:detailVC animated:YES completion:nil];
}

static void openSettings(void) {
    if (settingsShowing || !cpuWindow || !cpuWindow.rootViewController) return;

    UIViewController *root = cpuWindow.rootViewController;
    if (root.presentedViewController) {
        [root.presentedViewController dismissViewControllerAnimated:NO completion:nil];
    }

    settingsShowing = YES;
    SBCPUSettingsController *vc = [[SBCPUSettingsController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;

    [root presentViewController:nav animated:YES completion:nil];
}

static void checkHighCPU(double cpu) {
    if (!autoLogoutEnable || cpu < logoutCPUThreshold) {
        cpuHighStartTime = nil;
        logoutCounting = NO;
        return;
    }

    if (!cpuHighStartTime) {
        cpuHighStartTime = [NSDate date];
        return;
    }

    NSTimeInterval duration = [[NSDate date] timeIntervalSinceDate:cpuHighStartTime];
    if (duration >= logoutDuration && !logoutCounting) {
        logoutCounting = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!cpuWindow || !cpuWindow.rootViewController) { logoutCounting = NO; return; }
            UIViewController *root = cpuWindow.rootViewController;
            if (root.presentedViewController) {
                logoutCounting = NO;
                cpuHighStartTime = nil;
                return;
            }

            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"SpringBoard CPU过高" message:@"5秒后自动注销" preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
                logoutCounting = NO;
                cpuHighStartTime = nil;
            }]];
            [root presentViewController:alert animated:YES completion:nil];

            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                if (logoutCounting) kill(getpid(), SIGTERM);
            });
        });
    }
}

static BOOL isPowerdHookReady(void) {
    CFPreferencesAppSynchronize(CFSTR("com.yourname.sbcpufloating"));
    CFPropertyListRef value = CFPreferencesCopyValue(CFSTR("powerdHookReady"),
                                                       CFSTR("com.yourname.sbcpufloating"),
                                                       kCFPreferencesCurrentUser,
                                                       kCFPreferencesAnyHost);
    BOOL ready = (value && CFGetTypeID(value) == CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)value));
    if (value) CFRelease(value);
    return ready;
}

static void startFastChargeStartupAnimation(void) {
    if (!floatingView || !forceFastChargeEnable || !isChargingInternal()) return;
    if (fastChargeStartupAnimating) return;

    fastChargeStartupAnimating = YES;
    NSInteger generation = ++fastChargeStartupGeneration;

    dispatch_async(dispatch_get_main_queue(), ^{
        if (!floatingView || generation != fastChargeStartupGeneration || !isChargingInternal()) {
            fastChargeStartupAnimating = NO;
            return;
        }

        [floatingView resetInactivityTimer];
        [floatingView prepareStartupAnimationView];
        floatingView.performanceContainer.hidden = YES;
        floatingView.notificationContainer.hidden = YES;

        [UIView animateWithDuration:0.32
                              delay:0
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
            floatingView.startupContainer.alpha = 1.0;
            floatingView.startupContainer.transform = CGAffineTransformIdentity;
            floatingView.startupIconCircle.transform = CGAffineTransformMakeScale(1.0, 1.0);
        } completion:nil];

        NSArray<NSString *> *titles = @[
            @"满血充电核心启动",
            @"检测充电环境中…",
            @"检测 powerd 进程…",
            @"确认 powerd 注入状态…",
            @"Hook 核心功能加载中…",
            @"充电限制处理完成",
            @"满血充电已激活",
            @"启动完成"
        ];
        NSArray<NSString *> *details = @[
            @"正在初始化核心组件…",
            @"正在检测充电器 / 电池信息…",
            @"正在查找 powerd 进程…",
            @"正在确认插件注入状态…",
            @"正在加载充电核心模块…",
            @"正在解除充电限制策略…",
            @"满血充电核心已成功激活",
            @"正在恢复原浮窗…"
        ];
        NSArray<NSString *> *icons = @[@"⚡", @"⌕", @"PWRD", @"◉", @"🧩", @"✓", @"🔥", @"✓"];
        NSArray<NSNumber *> *durations = @[@1.05, @1.10, @1.10, @1.20, @1.15, @1.10, @0.95, @1.10];

        __block NSTimeInterval elapsed = 0.0;
        for (NSUInteger i = 0; i < titles.count; i++) {
            NSTimeInterval delay = elapsed;
            elapsed += durations[i].doubleValue;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (!floatingView || generation != fastChargeStartupGeneration || !fastChargeStartupAnimating) return;
                if (!isChargingInternal()) {
                    fastChargeStartupAnimating = NO;
                    [floatingView finishStartupAnimation];
                    return;
                }

                NSString *detail = details[i];
                if (i == 3) {
                    detail = isPowerdHookReady() ? @"SBCPUPowerd 已成功注入 powerd" : @"正在等待 SBCPUPowerd 注入…";
                } else if (i == 5 && !isPowerdHookReady()) {
                    detail = @"powerd Hook 尚未就绪，继续检测…";
                }

                CGFloat progress = ((CGFloat)i + 1.0f) / (CGFloat)titles.count;
                [floatingView showStartupStage:i title:titles[i] detail:detail icon:icons[i] progress:progress];
            });
        }

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(elapsed * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!floatingView || generation != fastChargeStartupGeneration || !fastChargeStartupAnimating) return;
            if (!isChargingInternal()) {
                fastChargeStartupAnimating = NO;
                [floatingView finishStartupAnimation];
                return;
            }

            fastChargeStartupAnimating = NO;
            [floatingView finishStartupAnimation];

            NSDictionary *chargeInfo = getRealBatteryDetails();
            double watts = MAX(0.0, [chargeInfo[@"CalculatedWatts"] doubleValue]);
            floatingView.statusLabel.text = [NSString stringWithFormat:@"🔥 强制满血快充 · %.1fW", watts];
            floatingView.statusLabel.textColor = [UIColor systemRedColor];
            floatingView.statusDot.backgroundColor = floatingView.statusLabel.textColor;

            NSString *thermalText = nil;
            UIColor *thermalColor = nil;
            sbcputhermalFloatingStatus(&thermalText, &thermalColor);
            floatingView.thermalStatusLabel.text = thermalText ?: @"温控：核心已运行";
            floatingView.thermalStatusLabel.textColor = thermalColor ?: [UIColor systemGreenColor];
            [floatingView resetInactivityTimer];
        });
    });
}

static void updateCPU(void) {
    if (!isEnabled) return;

    if (!cpuWindow || !floatingView) {
        createCPUWindow();
    }
    if (!floatingView) return;

    double cpu = getSpringBoardCPUUsage();
    double cpuFreq = getRealCPUFrequency(cpu);
    double fps = [SBCPUFPSHelper sharedInstance].currentFPS;

    checkHighCPU(cpu);
    updateSmartCharge(); // 智能停充：检测电量，达到上限停充，降到下限恢复

    dispatch_async(dispatch_get_main_queue(), ^{
        if (!floatingView) return;

        [UIDevice currentDevice].batteryMonitoringEnabled = YES;
        NSInteger battery = (NSInteger)([UIDevice currentDevice].batteryLevel * 100);
        if (battery < 0) battery = 100;

        double temp = getBatteryTemperatureInternal();
        double current = getBatteryCurrentInternal();
        BOOL charging = isChargingInternal();

        if (chargeBoostEnable && charging) {
            applyExperimentalChargeLimit100(YES);
        } else if (!chargeBoostEnable && chargeLimit100Applied) {
            applyExperimentalChargeLimit100(NO);
        }
if (charging && !previousChargingState) {
            if (floatingView.isCollapsed && !floatingView.isShowingNotification) {
                [floatingView expandFromEdgeAnimated:YES];
            }
            [floatingView triggerPlugAnimation];
            // 超级快充：插入充电器后启动一次 Powerd 注入启动动画。
            // 动画函数内部会检查开关、充电状态并防止重复启动。
            if (forceFastChargeEnable) {
                startFastChargeStartupAnimation();
            }
        }
        previousChargingState = charging;

        if (autoExpandLandscape) {
            UIInterfaceOrientation orientation = getEffectiveFloatingOrientation();
            BOOL isLandscape = (orientation == UIInterfaceOrientationLandscapeLeft || orientation == UIInterfaceOrientationLandscapeRight);
            
            if (isLandscape && !wasLandscape && floatingView.isCollapsed && !floatingView.isShowingNotification) {
                [floatingView expandFromEdgeAnimated:YES];
            } else if (!isLandscape && wasLandscape && !floatingView.isCollapsed && !floatingView.isShowingNotification) {
                [floatingView resetInactivityTimer];
            }
            wasLandscape = isLandscape;
        }

        NSDictionary *chargeInfo = getRealBatteryDetails();
        double chargeWatts = [chargeInfo[@"CalculatedWatts"] doubleValue];
        if (chargeWatts < 0) chargeWatts = 0;
        previousChargeWatts = lastChargeWatts;
        lastChargeWatts = chargeWatts;
        if (chargeBoostEnable && charging) {
            if (chargeBoostStartTime <= 0) chargeBoostStartTime = CFAbsoluteTimeGetCurrent();
            if (chargeBoostBaselineWatts <= 0.1 && chargeWatts > 0.1) chargeBoostBaselineWatts = chargeWatts;
            if (!chargeBoostVerified && chargeBoostStartTime > 0 && (CFAbsoluteTimeGetCurrent() - chargeBoostStartTime) >= 5.0) {
                chargeBoostVerified = (chargeBoostBaselineWatts > 0.1 && chargeWatts >= chargeBoostBaselineWatts + 1.0);
            }
        }
        chargeBoostStatus = [getChargeBoostStatus(chargeWatts, temp, battery, charging) copy];
        // 保留原有充电状态显示：强制满血快充 > 充电增强 > 普通状态。
        if (forceFastChargeEnable && charging) {
            floatingView.statusLabel.text = [NSString stringWithFormat:@"🔥 强制满血快充 · %.1fW", chargeWatts];
            floatingView.statusLabel.textColor = [UIColor systemRedColor];
            floatingView.statusDot.backgroundColor = floatingView.statusLabel.textColor;
        } else if (chargeBoostEnable && charging) {
            NSString *verify = @"监测中";
            if (chargeBoostVerified) verify = @"检测到功率提升";
            else if (chargeBoostStartTime > 0 && (CFAbsoluteTimeGetCurrent() - chargeBoostStartTime) >= 5.0) verify = @"未检测到明显提升";
            floatingView.statusLabel.text = [NSString stringWithFormat:@"⚡ 充电增强 · %.1fW · %@", chargeWatts, verify];
            floatingView.statusLabel.textColor = chargeBoostVerified ? [UIColor systemGreenColor] : [UIColor systemBlueColor];
            floatingView.statusDot.backgroundColor = floatingView.statusLabel.textColor;
        }

        [floatingView updateDataWithCPU:cpu 
                                cpuFreq:cpuFreq
                                    fps:fps 
                                battery:battery 
                                   temp:temp 
                                current:current 
                             isCharging:charging];

        updateFloatingSize();
    });
}

static void applySystemRefreshRate(void) {
    BOOL apply120 = force120HzEnable;
    
    Class serverClass = NSClassFromString(@"CAWindowServer");
    if (serverClass && [serverClass respondsToSelector:@selector(serverIfRunning)]) {
        id server = [serverClass serverIfRunning];
        if (server) {
            for (id display in [server displays]) {
                if ([display respondsToSelector:@selector(setAllowsVirtualModes:)]) {
                    [display setAllowsVirtualModes:YES];
                }
                if (apply120) {
                    if ([display respondsToSelector:@selector(setMinimumRefreshRate:)]) [display setMinimumRefreshRate:120.0f];
                    if ([display respondsToSelector:@selector(setMaximumRefreshRate:)]) [display setMaximumRefreshRate:120.0f];
                    if ([display respondsToSelector:@selector(setIdealRefreshRate:)]) [display setIdealRefreshRate:120.0f];
                }
            }
        }
    }

    if (cpuWindow && [SBCPUFPSHelper sharedInstance].driverLayer.superlayer == nil) {
        [cpuWindow.layer addSublayer:[SBCPUFPSHelper sharedInstance].driverLayer];
    }

    [[SBCPUFPSHelper sharedInstance] updateFrameRate];
}

#pragma mark - 5. Notification Manager 实现

@implementation SBNotificationManager
+ (instancetype)sharedInstance {
    static SBNotificationManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SBNotificationManager alloc] init];
        historyNotifications = [[NSMutableArray alloc] init];
    });
    return instance;
}

- (void)extractAndHandleRequest:(id)req {
    @try {
        NSString *bundleID = [req valueForKey:@"sectionIdentifier"];
        id content = [req valueForKey:@"content"];
        NSString *title = [content valueForKey:@"title"];
        if (!title || title.length == 0) title = [content valueForKey:@"subtitle"];
        NSString *message = [content valueForKey:@"message"];
        
        NSDictionary *payload = nil;
        @try {
            id userNotif = [req respondsToSelector:@selector(userNotification)] ? [req performSelector:@selector(userNotification)] : nil;
            id info = [userNotif respondsToSelector:@selector(userInfo)] ? [userNotif performSelector:@selector(userInfo)] : nil;
            if (!info) {
                id bulletin = [req respondsToSelector:@selector(bulletin)] ? [req performSelector:@selector(bulletin)] : nil;
                info = [bulletin respondsToSelector:@selector(userInfo)] ? [bulletin performSelector:@selector(userInfo)] : nil;
            }
            if (info && [info isKindOfClass:[NSDictionary class]]) {
                payload = [[NSDictionary alloc] initWithDictionary:info]; 
            }
        } @catch (NSException *e) {}

        static NSString *lastTitle = nil;
        static NSString *lastMessage = nil;
        static NSTimeInterval lastTime = 0;
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        
        if ([title isEqualToString:lastTitle] && [message isEqualToString:lastMessage] && (now - lastTime < 1.0)) {
            return; 
        }
        lastTitle = title; lastMessage = message; lastTime = now;
        
        SBNotifReq *notif = [[SBNotifReq alloc] init];
        notif.bundleID = bundleID; 
        notif.title = title ?: @"新消息"; 
        notif.message = message ?: @"";
        notif.timestamp = [NSDate date];
        notif.userInfoPayload = payload; 
        notif.originalRequest = req;
        
        [self handleNewNotification:notif];
    } @catch (NSException *e) {}
}

- (void)handleNewNotification:(SBNotifReq *)req {
    if (!notificationEnable) return;

    // 横屏状态消息通知独立控制：关闭后仅禁止横屏消息进入悬浮窗，
    // 不影响竖屏通知、微信/QQ/TIM 开关以及原有浮窗逻辑。
    UIInterfaceOrientation orientation = getActiveInterfaceOrientation();
    BOOL isLandscape = (orientation == UIInterfaceOrientationLandscapeLeft || orientation == UIInterfaceOrientationLandscapeRight);
    if (isLandscape && !landscapeNotificationEnable) return;

    BOOL shouldShow = NO;
    if (wechatEnable && [req.bundleID isEqualToString:@"com.tencent.xin"]) shouldShow = YES;
    if (qqEnable && [req.bundleID.lowercaseString containsString:@"qq"]) shouldShow = YES;
    if (timEnable && [req.bundleID isEqualToString:@"com.tencent.tim"]) shouldShow = YES;
    
    if (!shouldShow) return;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [historyNotifications insertObject:req atIndex:0];
        if (historyNotifications.count > 20) [historyNotifications removeLastObject];
        
        if (floatingView) {
            [floatingView.notificationQueue addObject:req];
            if (!floatingView.isShowingNotification) {
                [floatingView showNotification:floatingView.notificationQueue.firstObject];
            } else {
                [floatingView showNotification:floatingView.currentNotification];
            }
        }
    });
}
@end


#pragma mark - 7. 所有的 Objective-C 类实现区块

@implementation SBCPUFPSHelper {
    CADisplayLink *_displayLink;
    CFTimeInterval _lastTimestamp;
    NSInteger _frameCount;
}

+ (instancetype)sharedInstance {
    static SBCPUFPSHelper *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SBCPUFPSHelper alloc] init];
    });
    return instance;
}

- (instancetype)init {
    if (self = [super init]) {
        _driverLayer = [CALayer layer];
        _driverLayer.frame = CGRectMake(0, 0, 2, 2);
        _driverLayer.backgroundColor = [UIColor clearColor].CGColor;
        _driverLayer.opacity = 0.01f;
    }
    return self;
}

- (void)startDriverAnimation {
    if (!_driverLayer) return;
    [_driverLayer removeAnimationForKey:@"ProMotion120Driver"];

    CABasicAnimation *driveAnim = [CABasicAnimation animationWithKeyPath:@"opacity"];
    driveAnim.fromValue = @(0.01f);
    driveAnim.toValue = @(0.02f);
    driveAnim.duration = 1.0;
    driveAnim.repeatCount = HUGE_VALF;
    driveAnim.autoreverses = YES;
    driveAnim.removedOnCompletion = NO;
    if (@available(iOS 15.0, *)) {
        driveAnim.preferredFrameRateRange = CAFrameRateRangeMake(120.0f, 120.0f, 120.0f);
    }
    [_driverLayer addAnimation:driveAnim forKey:@"ProMotion120Driver"];
}

- (void)stopDriverAnimation {
    if (_driverLayer) {
        [_driverLayer removeAnimationForKey:@"ProMotion120Driver"];
    }
}

- (void)startMonitoring {
    if (_displayLink) return;
    _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    [self updateFrameRate];
    [_displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)stopMonitoring {
    if (_displayLink) {
        [_displayLink invalidate];
        _displayLink = nil;
    }
    [self stopDriverAnimation];
    _lastTimestamp = 0;
    _frameCount = 0;
    _currentFPS = 0.0;
}

- (void)updateFrameRate {
    if (!_displayLink) return;

    BOOL apply120 = force120HzEnable;

    if (@available(iOS 15.0, *)) {
        float targetFps = apply120 ? 120.0f : 60.0f;
        _displayLink.preferredFrameRateRange = CAFrameRateRangeMake(targetFps, targetFps, targetFps);
        
        if (apply120) {
            if ([_displayLink respondsToSelector:@selector(setHighFrameRateReason:)]) {
                @try {
                    [_displayLink setValue:@(1114113) forKey:@"highFrameRateReason"];
                } @catch (id ex) {}
            }
            [self startDriverAnimation];
        } else {
            [self stopDriverAnimation];
        }
    } else {
        _displayLink.preferredFramesPerSecond = apply120 ? 120 : 60;
    }
}

- (void)tick:(CADisplayLink *)link {
    if (_lastTimestamp == 0) {
        _lastTimestamp = link.timestamp;
        return;
    }
    _frameCount++;
    CFTimeInterval delta = link.timestamp - _lastTimestamp;
    if (delta >= 0.5) {
        self.currentFPS = (double)_frameCount / delta;
        _frameCount = 0;
        _lastTimestamp = link.timestamp;
    }
}
@end


// 液态玻璃：给文字加阴影+白色外发光（模拟描边），保证纯透明玻璃背景下可读
static void LGApplyGlassLabelShadow(UILabel *label) {
    if (!label) return;
    // 黑色向下阴影：增强文字轮廓
    label.layer.shadowColor = [UIColor colorWithWhite:0.0f alpha:0.65f].CGColor;
    label.layer.shadowOffset = CGSizeMake(0.0f, 1.0f);
    label.layer.shadowRadius = 3.0f;
    label.layer.shadowOpacity = 1.0f;
    label.layer.masksToBounds = NO;
    // UILabel 自带白色外发光：模拟描边，让文字在任何背景上都突出
    label.shadowColor = [UIColor colorWithWhite:1.0f alpha:0.55f];
    label.shadowOffset = CGSizeMake(0.0f, 0.0f);
}
static void LGApplyShadowToLabelsInView(UIView *view) {
    if (!view) return;
    for (UIView *v in view.subviews) {
        if ([v isKindOfClass:[UILabel class]]) {
            LGApplyGlassLabelShadow((UILabel *)v);
        }
        LGApplyShadowToLabelsInView(v);
    }
}
// 液态玻璃：去掉文字阴影（关闭液态玻璃时恢复原版）
static void LGRemoveLabelShadowInView(UIView *view) {
    if (!view) return;
    for (UIView *v in view.subviews) {
        if ([v isKindOfClass:[UILabel class]]) {
            UILabel *lbl = (UILabel *)v;
            lbl.layer.shadowOpacity = 0.0f;
            lbl.shadowColor = nil;
        }
        LGRemoveLabelShadowInView(v);
    }
}

@implementation SBCPUFloatingView

// 液态玻璃：根据开关应用/取消液态玻璃样式
- (void)applyLiquidGlassStyle {
    BOOL enabled = liquidGlassEnabled;
    _glassBackdropLayer.hidden = !enabled;
    _glassSheenLayer.hidden = !enabled;
    _glassBoostLayer.hidden = !enabled;
    _glassEdgeLayer.hidden = !enabled;
    if (_glassTintLayer) _glassTintLayer.hidden = !enabled;

    if (enabled) {
        if (_glassBackdropLayer) {
            _blurView.effect = nil; // 用 CABackdropLayer 替代 UIVisualEffect
        }
        LGApplyShadowToLabelsInView(_blurView.contentView);
    } else {
        // 恢复原版 UIVisualEffectView 模糊
        _blurView.effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialLight];
        LGRemoveLabelShadowInView(_blurView.contentView);
    }
    [self applyAdaptiveTextColors];
}

// 液态玻璃：实时采样浮窗下方背景亮度，文字自动反色（亮背景→黑字，暗背景→白字）
- (void)applyAdaptiveTextColors {
    BOOL glass = liquidGlassEnabled;
    BOOL lightBg = YES; // 默认浅色背景→黑字

    if (glass) {
        CGFloat lum = [self sampleBackgroundLuminance];
        lightBg = (lum > 0.5);
    }

    UIColor *titleColor = lightBg
        ? [UIColor colorWithWhite:0.32 alpha:1.0f]
        : [UIColor colorWithWhite:0.82 alpha:1.0f];
    UIColor *monoColor = lightBg ? [UIColor blackColor] : [UIColor whiteColor];

    // 静态副标题
    _cpuTitleLabel.textColor = titleColor;
    _cpuFreqLabel.textColor = titleColor;
    _fpsTitleLabel.textColor = titleColor;
    _fpsSubLabel.textColor = titleColor;
    _batterySubLabel.textColor = titleColor;
    _tempSubLabel.textColor = titleColor;
    _currentSubLabel.textColor = titleColor;
    // 静态值（温度、电流、折叠态）
    _tempValueLabel.textColor = monoColor;
    _currentValueLabel.textColor = monoColor;
    _miniCpuLabel.textColor = monoColor;
    _timeLabel.textColor = monoColor; // 时间显示也参与反色
    // 通知文字
    _notifAppNameLabel.textColor = lightBg ? [UIColor darkGrayColor] : [UIColor lightGrayColor];
    _notifMessageLabel.textColor = lightBg ? [UIColor colorWithWhite:0.15 alpha:1.0] : [UIColor colorWithWhite:0.85 alpha:1.0];
}

// 实时采样浮窗下方背景的平均亮度（0-1），用 UIScreen 私有截屏 API
- (CGFloat)sampleBackgroundLuminance {
    if (!self.superview) return 0.5;
    @try {
        UIView *snapshot = [UIScreen.mainScreen performSelector:@selector(snapshotView)];
        if (!snapshot) return 0.5;

        UIImage *snapshotImage = nil;
        if ([snapshot isKindOfClass:[UIImageView class]]) {
            snapshotImage = ((UIImageView *)snapshot).image;
        }
        if (!snapshotImage) {
            CGSize s = UIScreen.mainScreen.bounds.size;
            UIGraphicsBeginImageContextWithOptions(s, NO, 0);
            [snapshot drawViewHierarchyInRect:CGRectMake(0,0,s.width,s.height) afterScreenUpdates:NO];
            snapshotImage = UIGraphicsGetImageFromCurrentImageContext();
            UIGraphicsEndImageContext();
        }
        if (!snapshotImage || !snapshotImage.CGImage) return 0.5;

        // 裁剪浮窗中心 30x30 区域
        CGFloat scale = UIScreen.mainScreen.scale;
        CGRect sampleRect = CGRectMake((CGRectGetMidX(self.frame) - 15.0f) * scale,
                                         (CGRectGetMidY(self.frame) - 15.0f) * scale,
                                         30.0f * scale, 30.0f * scale);
        CGImageRef cropped = CGImageCreateWithImageInRect(snapshotImage.CGImage, sampleRect);
        if (!cropped) return 0.5;
        UIImage *croppedImage = [UIImage imageWithCGImage:cropped];
        CGImageRelease(cropped);

        return [self averageLuminanceFromImage:croppedImage];
    } @catch (NSException *e) {
        return 0.5; // 截屏失败时 fallback 中性亮度
    }
}

// 计算图片平均亮度（ITU-R BT.601）
- (CGFloat)averageLuminanceFromImage:(UIImage *)image {
    CGImageRef cgImage = image.CGImage;
    if (!cgImage) return 0.5;
    size_t width = CGImageGetWidth(cgImage);
    size_t height = CGImageGetHeight(cgImage);
    if (width == 0 || height == 0) return 0.5;

    unsigned char *rawData = (unsigned char *)calloc(width * height * 4, 1);
    if (!rawData) return 0.5;
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(rawData, width, height, 8, width*4,
                                                   colorSpace, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);
    if (!context) { free(rawData); return 0.5; }
    CGContextDrawImage(context, CGRectMake(0,0,width,height), cgImage);
    CGContextRelease(context);

    CGFloat total = 0;
    NSInteger count = width * height;
    for (NSInteger i = 0; i < count; i++) {
        CGFloat r = rawData[i*4] / 255.0f;
        CGFloat g = rawData[i*4+1] / 255.0f;
        CGFloat b = rawData[i*4+2] / 255.0f;
        total += 0.299f*r + 0.587f*g + 0.114f*b;
    }
    free(rawData);
    return total / count;
}

// 监听深浅模式变化，触发反色更新
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (liquidGlassEnabled) {
        [self applyAdaptiveTextColors];
    }
}

// 清理反色定时器
- (void)dealloc {
    [_adaptiveTimer invalidate];
    _adaptiveTimer = nil;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        self.backgroundColor = [UIColor clearColor];
        self.layer.masksToBounds = NO;
        self.userInteractionEnabled = YES;
        self.multipleTouchEnabled = NO;
        _isCollapsed = NO;
        _isShowingNotification = NO;
        _notificationQueue = [[NSMutableArray alloc] init];
        
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        pan.delegate = self;
        [self addGestureRecognizer:pan];

        self.singleTapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleSingleTap:)];
        self.singleTapGesture.delegate = self;
        [self addGestureRecognizer:self.singleTapGesture];

        UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleDoubleTap:)];
        doubleTap.numberOfTapsRequired = 2;
        doubleTap.delegate = self;
        [self addGestureRecognizer:doubleTap];
        [self.singleTapGesture requireGestureRecognizerToFail:doubleTap];

        self.longPressGesture = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
        self.longPressGesture.minimumPressDuration = 0.6;
        self.longPressGesture.delegate = self;
        [self addGestureRecognizer:self.longPressGesture];

        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.28f;
        self.layer.shadowOffset = CGSizeMake(0, 6);
        self.layer.shadowRadius = 18.0f;

        UIBlurEffect *blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialLight];
        _blurView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
        CGFloat cornerRad = floatingCornerRadius;
        _blurView.layer.cornerRadius = cornerRad;
        _blurView.layer.masksToBounds = YES;
        _blurView.layer.borderWidth = 1.0f;
        _blurView.layer.borderColor = [UIColor colorWithWhite:1.0f alpha:0.90f].CGColor;
        _blurView.userInteractionEnabled = NO;
        [self addSubview:_blurView];

        // === iOS 26 原生液态玻璃：CABackdropLayer 真正 backdrop 模糊（SBLiquidGlass 同款） ===
        _glassBackdropLayer = nil;
        @try {
            Class backdropCls = NSClassFromString(@"CABackdropLayer");
            if (backdropCls) {
                CALayer *bd = [backdropCls layer];
                bd.frame = _blurView.bounds;
                bd.cornerRadius = cornerRad;
                bd.masksToBounds = YES;
                [bd setValue:@NO  forKey:@"layerUsesCoreImageFilters"];
                [bd setValue:@YES forKey:@"windowServerAware"];
                [bd setValue:@"com.mowang.sbcpufloating.liquidglass" forKey:@"groupName"];
                [bd setValue:@"com.mowang.sbcpufloating" forKey:@"groupNamespace"];
                [bd setValue:@YES forKey:@"ignoresScreenClip"];
                [bd setValue:@1.0 forKey:@"scale"];
                [_blurView.layer insertSublayer:bd atIndex:0];
                _glassBackdropLayer = bd;
                _blurView.effect = nil; // 用 CABackdropLayer 替代 UIVisualEffect 模糊

                // 方案D：纯玻璃无 tint，完全靠 CABackdropLayer 模糊 + 文字阴影描边保可读
                _glassTintLayer = nil;
            }
        } @catch (NSException *e) {
            _glassBackdropLayer = nil;
            _glassTintLayer = nil;
            // fallback：保留 UIVisualEffectView 模糊
        }

        _marqueeLayer = [CAShapeLayer layer];
        _marqueeLayer.fillColor = [UIColor clearColor].CGColor;
        _marqueeLayer.strokeColor = [UIColor colorWithRed:0.2f green:0.85f blue:0.4f alpha:0.6f].CGColor;
        _marqueeLayer.lineWidth = 2.0f;
        _marqueeLayer.lineDashPattern = @[@14, @8];
        _marqueeLayer.hidden = YES;
        _marqueeLayer.zPosition = 1001.0f; // 跑马灯在玻璃高光之上，保持清晰
        [_blurView.layer addSublayer:_marqueeLayer];

        // === 液态玻璃：specular 边缘高光（SBLiquidGlass Dock 配方：白-清-白 45° 渐变 + 边缘 mask 只露一圈） ===
        _glassSheenLayer = [CAGradientLayer layer];
        _glassSheenLayer.frame = _blurView.bounds;
        _glassSheenLayer.colors = @[
            (id)[UIColor colorWithWhite:1.0f alpha:0.50f].CGColor,
            (id)[UIColor clearColor].CGColor,
            (id)[UIColor colorWithWhite:1.0f alpha:0.50f].CGColor,
        ];
        _glassSheenLayer.locations = @[@0.0f, @0.5f, @1.0f];
        _glassSheenLayer.startPoint = CGPointMake(0.0f, 0.0f);
        _glassSheenLayer.endPoint = CGPointMake(1.0f, 1.0f);
        _glassSheenLayer.zPosition = 1000.0f; // 玻璃表面反光盖在内容之上
        _glassSheenMask = [CALayer layer];
        _glassSheenMask.frame = _blurView.bounds;
        _glassSheenMask.backgroundColor = [UIColor clearColor].CGColor;
        _glassSheenMask.borderColor = [UIColor blackColor].CGColor;
        _glassSheenMask.borderWidth = 1.25f;
        _glassSheenMask.cornerRadius = cornerRad;
        _glassSheenLayer.mask = _glassSheenMask;
        [_blurView.layer addSublayer:_glassSheenLayer];

        // boost 层：overlayBlendMode 增强高光亮度
        _glassBoostLayer = [CAGradientLayer layer];
        _glassBoostLayer.frame = _blurView.bounds;
        _glassBoostLayer.colors = @[
            (id)[UIColor colorWithWhite:1.0f alpha:0.90f].CGColor,
            (id)[UIColor clearColor].CGColor,
            (id)[UIColor colorWithWhite:1.0f alpha:0.90f].CGColor,
        ];
        _glassBoostLayer.locations = @[@0.0f, @0.5f, @1.0f];
        _glassBoostLayer.startPoint = _glassSheenLayer.startPoint;
        _glassBoostLayer.endPoint = _glassSheenLayer.endPoint;
        _glassBoostLayer.compositingFilter = @"overlayBlendMode";
        _glassBoostLayer.zPosition = 999.0f;
        _glassBoostMask = [CALayer layer];
        _glassBoostMask.frame = _blurView.bounds;
        _glassBoostMask.backgroundColor = [UIColor clearColor].CGColor;
        _glassBoostMask.borderColor = [UIColor blackColor].CGColor;
        _glassBoostMask.borderWidth = 1.25f;
        _glassBoostMask.cornerRadius = cornerRad;
        _glassBoostLayer.mask = _glassBoostMask;
        [_blurView.layer addSublayer:_glassBoostLayer];

        // === 液态玻璃：最外沿细亮描边（配合 specular 形成完整边缘光） ===
        _glassEdgeLayer = [CAShapeLayer layer];
        _glassEdgeLayer.frame = _blurView.bounds;
        _glassEdgeLayer.fillColor = [UIColor clearColor].CGColor;
        _glassEdgeLayer.strokeColor = [UIColor colorWithWhite:1.0f alpha:0.55f].CGColor;
        _glassEdgeLayer.lineWidth = 1.0f;
        _glassEdgeLayer.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(_blurView.bounds, 0.5f, 0.5f) cornerRadius:cornerRad].CGPath;
        _glassEdgeLayer.zPosition = 998.0f;
        [_blurView.layer addSublayer:_glassEdgeLayer];

        UIView *content = _blurView.contentView;
        content.userInteractionEnabled = NO;
        
        _horizontalDiv = [[UIView alloc] init];
        _horizontalDiv.backgroundColor = [UIColor colorWithWhite:0.0f alpha:0.12f];
        _horizontalDiv.hidden = YES;
        [content addSubview:_horizontalDiv];

        _performanceContainer = [[UIView alloc] initWithFrame:content.bounds];
        _performanceContainer.userInteractionEnabled = NO;
        [content addSubview:_performanceContainer];

        UIColor *titleGrayColor = [UIColor colorWithWhite:0.35 alpha:1.0f];
        
        _cpuTitleLabel = [[UILabel alloc] init];
        _cpuTitleLabel.text = @"CPU";
        _cpuTitleLabel.textColor = titleGrayColor;
        _cpuTitleLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
        [_performanceContainer addSubview:_cpuTitleLabel];

        _cpuValueLabel = [[UILabel alloc] init];
        _cpuValueLabel.textColor = [UIColor colorWithRed:0.18f green:0.75f blue:0.35f alpha:1.0f]; 
        _cpuValueLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
        _cpuValueLabel.adjustsFontSizeToFitWidth = YES;
        _cpuValueLabel.minimumScaleFactor = 0.5f;
        [_performanceContainer addSubview:_cpuValueLabel];

        _cpuFreqLabel = [[UILabel alloc] init];
        _cpuFreqLabel.textColor = titleGrayColor;
        _cpuFreqLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
        _cpuFreqLabel.adjustsFontSizeToFitWidth = YES;
        _cpuFreqLabel.minimumScaleFactor = 0.5f;
        [_performanceContainer addSubview:_cpuFreqLabel];

        _div1 = [[UIView alloc] init];
        _div1.backgroundColor = [UIColor colorWithWhite:0.0f alpha:0.1f];
        [_performanceContainer addSubview:_div1];

        _fpsTitleLabel = [[UILabel alloc] init];
        _fpsTitleLabel.text = @"FPS";
        _fpsTitleLabel.textColor = titleGrayColor;
        _fpsTitleLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
        [_performanceContainer addSubview:_fpsTitleLabel];

        _fpsValueLabel = [[UILabel alloc] init];
        _fpsValueLabel.textColor = [UIColor colorWithRed:0.47f green:0.33f blue:0.90f alpha:1.0f];
        _fpsValueLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
        _fpsValueLabel.adjustsFontSizeToFitWidth = YES;
        _fpsValueLabel.minimumScaleFactor = 0.5f;
        [_performanceContainer addSubview:_fpsValueLabel];

        _fpsSubLabel = [[UILabel alloc] init];
        _fpsSubLabel.text = @"FPS";
        _fpsSubLabel.textColor = titleGrayColor;
        _fpsSubLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
        [_performanceContainer addSubview:_fpsSubLabel];

        _divFps = [[UIView alloc] init];
        _divFps.backgroundColor = [UIColor colorWithWhite:0.0f alpha:0.1f];
        [_performanceContainer addSubview:_divFps];

        _batteryIconLabel = [[UILabel alloc] init];
        _batteryIconLabel.text = @"🔋";
        _batteryIconLabel.font = [UIFont systemFontOfSize:16];
        [_performanceContainer addSubview:_batteryIconLabel];

        _batteryValueLabel = [[UILabel alloc] init];
        _batteryValueLabel.textColor = [UIColor colorWithRed:0.15f green:0.45f blue:0.25f alpha:1.0f];
        _batteryValueLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
        _batteryValueLabel.adjustsFontSizeToFitWidth = YES;
        _batteryValueLabel.minimumScaleFactor = 0.5f;
        [_performanceContainer addSubview:_batteryValueLabel];

        _batterySubLabel = [[UILabel alloc] init];
        _batterySubLabel.text = @"电量";
        _batterySubLabel.textColor = titleGrayColor;
        _batterySubLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
        [_performanceContainer addSubview:_batterySubLabel];

        _div2 = [[UIView alloc] init];
        _div2.backgroundColor = [UIColor colorWithWhite:0.0f alpha:0.1f];
        [_performanceContainer addSubview:_div2];

        _tempIconView = [[UIImageView alloc] init];
        _tempIconView.contentMode = UIViewContentModeScaleAspectFit;
        if (@available(iOS 13.0, *)) {
            UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightMedium];
            _tempIconView.image = [UIImage systemImageNamed:@"thermometer" withConfiguration:config];
            _tempIconView.tintColor = [UIColor systemRedColor];
        }
        [_performanceContainer addSubview:_tempIconView];

        _tempValueLabel = [[UILabel alloc] init];
        _tempValueLabel.textColor = [UIColor blackColor];
        _tempValueLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
        _tempValueLabel.adjustsFontSizeToFitWidth = YES;
        _tempValueLabel.minimumScaleFactor = 0.5f;
        [_performanceContainer addSubview:_tempValueLabel];

        _tempSubLabel = [[UILabel alloc] init];
        _tempSubLabel.text = @"温度";
        _tempSubLabel.textColor = titleGrayColor;
        _tempSubLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
        [_performanceContainer addSubview:_tempSubLabel];

        _div3 = [[UIView alloc] init];
        _div3.backgroundColor = [UIColor colorWithWhite:0.0f alpha:0.1f];
        [_performanceContainer addSubview:_div3];

        _currentIconLabel = [[UILabel alloc] init];
        _currentIconLabel.text = @"⚡";
        _currentIconLabel.font = [UIFont systemFontOfSize:14];
        [_performanceContainer addSubview:_currentIconLabel];

        _currentValueLabel = [[UILabel alloc] init];
        _currentValueLabel.textColor = [UIColor blackColor];
        _currentValueLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
        _currentValueLabel.adjustsFontSizeToFitWidth = YES;
        _currentValueLabel.minimumScaleFactor = 0.5f;
        [_performanceContainer addSubview:_currentValueLabel];

        _currentSubLabel = [[UILabel alloc] init];
        _currentSubLabel.text = @"电流";
        _currentSubLabel.textColor = titleGrayColor;
        _currentSubLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
        [_performanceContainer addSubview:_currentSubLabel];

        _bottomCapsule = [[UIView alloc] init];
        _bottomCapsule.backgroundColor = [UIColor colorWithRed:0.1f green:0.8f blue:0.4f alpha:0.15f];
        _bottomCapsule.layer.masksToBounds = YES;
        _bottomCapsule.layer.borderWidth = 0.0f;
        [_performanceContainer addSubview:_bottomCapsule];

        _batteryProgressView = [[UIView alloc] init];
        _batteryProgressView.backgroundColor = [UIColor colorWithRed:0.1f green:0.8f blue:0.4f alpha:0.3f];
        [_bottomCapsule addSubview:_batteryProgressView];

        _statusLabel = [[UILabel alloc] init];
        _statusLabel.textColor = [UIColor colorWithRed:0.15f green:0.65f blue:0.3f alpha:1.0f];
        _statusLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
        _statusLabel.textAlignment = NSTextAlignmentCenter;
        [_bottomCapsule addSubview:_statusLabel];

        // 实时温控状态显示，与充电状态分开，避免充电文字覆盖温控信息。
        _thermalStatusLabel = [[UILabel alloc] init];
        _thermalStatusLabel.text = @"温控：检测中";
        _thermalStatusLabel.textColor = [UIColor systemBlueColor];
        _thermalStatusLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightSemibold];
        _thermalStatusLabel.textAlignment = NSTextAlignmentCenter;
        _thermalStatusLabel.adjustsFontSizeToFitWidth = YES;
        _thermalStatusLabel.minimumScaleFactor = 0.75f;
        [_performanceContainer addSubview:_thermalStatusLabel];

        // 时间显示：游戏/横屏时看不到状态栏时间，在浮窗底部显示
        _timeLabel = [[UILabel alloc] init];
        _timeLabel.text = @"00:00:00";
        _timeLabel.textColor = [UIColor darkGrayColor];
        _timeLabel.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightSemibold];
        _timeLabel.textAlignment = NSTextAlignmentCenter;
        _timeLabel.adjustsFontSizeToFitWidth = YES;
        _timeLabel.minimumScaleFactor = 0.75f;
        [_performanceContainer addSubview:_timeLabel];

        // 超级快充启动动画：直接使用现有浮窗本体，不创建独立 UIWindow。
        // 这样插入充电器时只是把原浮窗临时变成一个紧凑的启动卡片，完成后恢复原样。
        _startupContainer = [[UIView alloc] init];
        _startupContainer.hidden = YES;
        _startupContainer.alpha = 0.0;
        _startupContainer.userInteractionEnabled = NO;
        [_blurView.contentView addSubview:_startupContainer];

        _startupIconCircle = [[UIView alloc] init];
        _startupIconCircle.backgroundColor = [UIColor colorWithRed:0.08f green:0.18f blue:0.10f alpha:0.92f];
        _startupIconCircle.layer.borderWidth = 1.5f;
        _startupIconCircle.layer.borderColor = [UIColor systemGreenColor].CGColor;
        _startupIconCircle.layer.shadowColor = [UIColor systemGreenColor].CGColor;
        _startupIconCircle.layer.shadowOpacity = 0.55f;
        _startupIconCircle.layer.shadowRadius = 8.0f;
        _startupIconCircle.layer.shadowOffset = CGSizeZero;
        [_startupContainer addSubview:_startupIconCircle];

        _startupIconLabel = [[UILabel alloc] init];
        _startupIconLabel.textAlignment = NSTextAlignmentCenter;
        _startupIconLabel.font = [UIFont systemFontOfSize:25.0f weight:UIFontWeightSemibold];
        [_startupIconCircle addSubview:_startupIconLabel];

        _startupTitleLabel = [[UILabel alloc] init];
        _startupTitleLabel.textColor = [UIColor labelColor];
        _startupTitleLabel.font = [UIFont systemFontOfSize:15.0f weight:UIFontWeightSemibold];
        _startupTitleLabel.adjustsFontSizeToFitWidth = YES;
        _startupTitleLabel.minimumScaleFactor = 0.72f;
        [_startupContainer addSubview:_startupTitleLabel];

        _startupDetailLabel = [[UILabel alloc] init];
        _startupDetailLabel.textColor = [UIColor secondaryLabelColor];
        _startupDetailLabel.font = [UIFont systemFontOfSize:10.5f weight:UIFontWeightRegular];
        _startupDetailLabel.adjustsFontSizeToFitWidth = YES;
        _startupDetailLabel.minimumScaleFactor = 0.68f;
        [_startupContainer addSubview:_startupDetailLabel];

        _startupProgressTrack = [[UIView alloc] init];
        _startupProgressTrack.backgroundColor = [UIColor colorWithWhite:0.0f alpha:0.10f];
        _startupProgressTrack.layer.cornerRadius = 3.5f;
        _startupProgressTrack.layer.masksToBounds = YES;
        [_startupContainer addSubview:_startupProgressTrack];

        _startupProgressFill = [[UIView alloc] init];
        _startupProgressFill.backgroundColor = [UIColor systemGreenColor];
        _startupProgressFill.layer.cornerRadius = 3.5f;
        [_startupProgressTrack addSubview:_startupProgressFill];

        _startupPercentLabel = [[UILabel alloc] init];
        _startupPercentLabel.textColor = [UIColor secondaryLabelColor];
        _startupPercentLabel.font = [UIFont monospacedDigitSystemFontOfSize:10.0f weight:UIFontWeightMedium];
        _startupPercentLabel.textAlignment = NSTextAlignmentRight;
        [_startupContainer addSubview:_startupPercentLabel];

        _collapsedContainerView = [[UIView alloc] init];
        _collapsedContainerView.hidden = YES;
        _collapsedContainerView.alpha = 0.0;
        [_performanceContainer addSubview:_collapsedContainerView];

        _statusDot = [[UIView alloc] initWithFrame:CGRectMake(8, 9, 10, 10)];
        _statusDot.layer.cornerRadius = 5.0f;
        _statusDot.backgroundColor = [UIColor blackColor];
        [_collapsedContainerView addSubview:_statusDot];

        _miniCpuLabel = [[UILabel alloc] initWithFrame:CGRectMake(22, 5, 45, 18)]; 
        _miniCpuLabel.textColor = [UIColor blackColor];
        _miniCpuLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
        _miniCpuLabel.textAlignment = NSTextAlignmentLeft;
        [_collapsedContainerView addSubview:_miniCpuLabel];
        
        _notificationContainer = [[UIView alloc] initWithFrame:content.bounds];
        _notificationContainer.userInteractionEnabled = NO;
        _notificationContainer.alpha = 0.0;
        _notificationContainer.hidden = YES;
        [content addSubview:_notificationContainer];

        _notifAppNameLabel = [[UILabel alloc] init];
        _notifAppNameLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
        _notifAppNameLabel.textColor = [UIColor darkGrayColor];
        [_notificationContainer addSubview:_notifAppNameLabel];

        _notifMessageLabel = [[UILabel alloc] init];
        _notifMessageLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
        _notifMessageLabel.textColor = [UIColor colorWithWhite:0.15 alpha:1.0];
        _notifMessageLabel.numberOfLines = 1; 
        [_notificationContainer addSubview:_notifMessageLabel];

        _badgeLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, -6, 20, 14)];
        _badgeLabel.backgroundColor = [UIColor systemRedColor];
        _badgeLabel.textColor = [UIColor whiteColor];
        _badgeLabel.font = [UIFont systemFontOfSize:9 weight:UIFontWeightBold];
        _badgeLabel.textAlignment = NSTextAlignmentCenter;
        _badgeLabel.layer.cornerRadius = 7;
        _badgeLabel.layer.masksToBounds = YES;
        _badgeLabel.hidden = YES;
        [self addSubview:_badgeLabel];

        [self resetInactivityTimer];
    }
            // 液态玻璃：根据开关应用样式（开→液态玻璃+阴影+反色，关→原版）
        [self applyLiquidGlassStyle];

        // 实时背景采样反色定时器：每 0.5 秒采样浮窗下方背景亮度，文字自动反色
        _adaptiveTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(applyAdaptiveTextColors) userInfo:nil repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:_adaptiveTimer forMode:NSRunLoopCommonModes];

return self;
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)longPress {
    if (longPress.state == UIGestureRecognizerStateBegan) {
        UIImpactFeedbackGenerator *generator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [generator prepare];
        [generator impactOccurred];

        dispatch_async(dispatch_get_main_queue(), ^{
            openDetailView();
        });
    }
}

- (void)handleSingleTap:(UITapGestureRecognizer *)tap {
    if (tap.state == UIGestureRecognizerStateEnded) {
        BOOL hasUnread = (historyNotifications.count > 0);
        BOOL combinedModeVisible = (!self.isCollapsed && hasUnread) || self.isShowingNotification;

        if (combinedModeVisible) {
            SBNotifReq *targetReq = self.currentNotification ?: historyNotifications.firstObject;
            if (targetReq) {
                NSString *bundleID = targetReq.bundleID;
                NSDictionary *userInfo = targetReq.userInfoPayload;
                id rawRequest = targetReq.originalRequest; 
                
                // 点击通知后，彻底结束本次通知状态。
                // 特别重要：必须取消通知定时器，否则 5 秒后 hideNotification
                // 仍会使用 wasCollapsedBeforeNotification 再次把浮窗折叠。
                [self.notificationTimer invalidate];
                self.notificationTimer = nil;
                self.wasCollapsedBeforeNotification = NO;
                
                self.badgeLabel.hidden = YES;
                self.isShowingNotification = NO;
                self.currentNotification = nil;
                [historyNotifications removeAllObjects];
                
                if (autoCollapseEnable) {
                    [self collapseToEdgeAnimated:YES];
                } else {
                    [self updateLayoutWithShowCpuFreq:showCpuFrequency
                                               showFps:showFps
                                    showBatteryPercent:showBatteryPercent
                                       showBatteryTemp:showBatteryTemperature
                                    showBatteryCurrent:showBatteryCurrent
                                            isCharging:isChargingInternal()];
                }
                
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    dispatch_async(dispatch_get_main_queue(), ^{
                        BOOL opened = NO;

                        @try {
                            if (rawRequest && [rawRequest respondsToSelector:@selector(defaultAction)]) {
                                id defaultAction = [rawRequest performSelector:@selector(defaultAction)];
                                if (defaultAction && [defaultAction respondsToSelector:@selector(actionRunner)]) {
                                    id runner = [defaultAction performSelector:@selector(actionRunner)];
                                    if (runner && [runner respondsToSelector:@selector(executeAction:fromOrigin:endpoint:withParameters:completion:)]) {
                                        
                                        void (^completionBlock)(BOOL) = ^(BOOL success) {};
                                        [runner executeAction:defaultAction fromOrigin:@"NCNotificationDestinationBanner" endpoint:nil withParameters:nil completion:completionBlock];
                                        opened = YES;
                                    }
                                }
                            }
                        } @catch (NSException *e) {}

                        if (!opened) {
                            @try {
                                id fbsServiceClass = NSClassFromString(@"FBSOpenApplicationService");
                                id fbsOptionsClass = NSClassFromString(@"FBSOpenApplicationOptions");
                                
                                if (fbsServiceClass && fbsOptionsClass) {
                                    id fbsService = [fbsServiceClass performSelector:@selector(sharedInstance)];
                                    if ([fbsService respondsToSelector:@selector(openApplication:withOptions:completion:)]) {
                                        NSMutableDictionary *dict = [NSMutableDictionary dictionary];
                                        dict[@"__UnlockPrompt"] = @YES; 
                                        if (userInfo) {
                                            dict[@"__Payload"] = userInfo;
                                            dict[@"bks-open-application-options-notification-payload"] = userInfo;
                                            dict[@"UIApplicationOpenURLOptionsAnnotationKey"] = userInfo;
                                        }
                                        id fbsOptions = [fbsOptionsClass performSelector:@selector(optionsWithDictionary:) withObject:dict];
                                        
                                        void (^completionBlock)(id) = ^(id error) {}; 
                                        [fbsService openApplication:bundleID withOptions:fbsOptions completion:completionBlock];
                                        opened = YES;
                                    }
                                }
                            } @catch (NSException *e) {}
                        }
                        
                        if (!opened) {
                            @try {
                                id lsawClass = NSClassFromString(@"LSApplicationWorkspace");
                                if (lsawClass) {
                                    id workspace = [lsawClass performSelector:@selector(defaultWorkspace)];
                                    if ([workspace respondsToSelector:@selector(openApplicationWithBundleID:)]) {
                                        [workspace performSelector:@selector(openApplicationWithBundleID:) withObject:bundleID];
                                    }
                                }
                            } @catch (NSException *e) {}
                        }
                    });
                });
                
                UIImpactFeedbackGenerator *g = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
                [g prepare]; [g impactOccurred];
                return;
            }
        }
        
        if (self.isCollapsed) {
            [self expandFromEdgeAnimated:YES];
        } else {
            [self resetInactivityTimer];
        }
    }
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    [self resetInactivityTimer];

    if (pan.state == UIGestureRecognizerStateBegan) {
        self.lastPoint = self.center;
    } else if (pan.state == UIGestureRecognizerStateChanged) {
        CGPoint translation = [pan translationInView:self.superview];
        CGPoint targetCenter = CGPointMake(self.lastPoint.x + translation.x, self.lastPoint.y + translation.y);

        UIView *parent = self.superview;
        CGRect containerBounds = parent ? parent.bounds : [UIScreen mainScreen].bounds;
        CGRect realFrame = self.frame;
        CGFloat halfW = realFrame.size.width / 2.0f;
        CGFloat halfH = realFrame.size.height / 2.0f;

        CGFloat minX = halfW + 2.0f;
        CGFloat maxX = containerBounds.size.width - halfW - 2.0f;
        CGFloat minY = halfH + floatingTopSafeMargin(floatingView.superview);
        CGFloat maxY = containerBounds.size.height - halfH - 10.0f;

        if (maxX < minX) minX = maxX = containerBounds.size.width / 2.0f;
        if (maxY < minY) minY = maxY = containerBounds.size.height / 2.0f;

        if (targetCenter.x < minX) targetCenter.x = minX;
        if (targetCenter.x > maxX) targetCenter.x = maxX;
        if (targetCenter.y < minY) targetCenter.y = minY;
        if (targetCenter.y > maxY) targetCenter.y = maxY;

        self.center = targetCenter;
    } else if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled) {
        if (rememberPositionEnable) {
            [[NSUserDefaults standardUserDefaults] setObject:NSStringFromCGRect(self.frame) forKey:@"SBCPU.LastFrame"];
            [[NSUserDefaults standardUserDefaults] synchronize];
        }
        clampAndPositionFloatingView(self.center, YES);
        [self resetInactivityTimer];
    }
}

- (void)handleDoubleTap:(UITapGestureRecognizer *)tap {
    if (tap.state == UIGestureRecognizerStateEnded) {
        dispatch_async(dispatch_get_main_queue(), ^{ openSettings(); });
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

- (void)prepareStartupAnimationView {
    if (!_startupContainer) return;

    // 只比原浮窗稍大一点：约 260×124，避免出现独立全屏大窗口的压迫感。
    CGFloat targetW = 260.0f;
    CGFloat targetH = 124.0f;
    self.startupRestoreBounds = self.bounds;
    self.startupRestoreCenter = self.center;

    self.bounds = CGRectMake(0, 0, targetW, targetH);
    _startupContainer.frame = self.bounds;
    _startupIconCircle.frame = CGRectMake(14.0f, 18.0f, 58.0f, 58.0f);
    _startupIconCircle.layer.cornerRadius = 29.0f;
    _startupIconLabel.frame = _startupIconCircle.bounds;

    _startupTitleLabel.frame = CGRectMake(84.0f, 18.0f, 160.0f, 22.0f);
    _startupDetailLabel.frame = CGRectMake(84.0f, 42.0f, 160.0f, 18.0f);
    _startupProgressTrack.frame = CGRectMake(14.0f, 94.0f, 205.0f, 7.0f);
    _startupProgressFill.frame = CGRectMake(0, 0, 0, 7.0f);
    _startupPercentLabel.frame = CGRectMake(224.0f, 89.0f, 28.0f, 18.0f);

    _startupContainer.hidden = NO;
    _startupContainer.alpha = 0.0f;
    _startupIconCircle.transform = CGAffineTransformMakeScale(0.72f, 0.72f);
}

- (void)showStartupStage:(NSUInteger)index title:(NSString *)title detail:(NSString *)detail icon:(NSString *)icon progress:(CGFloat)progress {
    if (!_startupContainer) return;

    _startupTitleLabel.text = title;
    _startupDetailLabel.text = detail;
    _startupIconLabel.text = icon;
    _startupPercentLabel.text = [NSString stringWithFormat:@"%ld%%", (long)round(progress * 100.0f)];

    CGFloat trackW = _startupProgressTrack.bounds.size.width;
    CGFloat targetW = MAX(0.0f, MIN(trackW, trackW * progress));

    [UIView animateWithDuration:0.45
                          delay:0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self.startupProgressFill.frame = CGRectMake(0, 0, targetW, self.startupProgressTrack.bounds.size.height);
        self.startupIconCircle.transform = CGAffineTransformMakeScale(1.0f, 1.0f);
    } completion:nil];

    [_startupIconCircle.layer removeAnimationForKey:@"startupGlow"];
    CABasicAnimation *glow = [CABasicAnimation animationWithKeyPath:@"shadowOpacity"];
    glow.fromValue = @0.25;
    glow.toValue = @0.85;
    glow.duration = 0.65;
    glow.autoreverses = YES;
    glow.repeatCount = 1.5f;
    [_startupIconCircle.layer addAnimation:glow forKey:@"startupGlow"];

    if (index == 6) {
        _startupIconCircle.layer.borderColor = [UIColor systemOrangeColor].CGColor;
        _startupIconCircle.layer.shadowColor = [UIColor systemOrangeColor].CGColor;
    } else if (index == 7) {
        _startupIconCircle.layer.borderColor = [UIColor systemGreenColor].CGColor;
        _startupIconCircle.layer.shadowColor = [UIColor systemGreenColor].CGColor;
    } else {
        _startupIconCircle.layer.borderColor = [UIColor systemGreenColor].CGColor;
        _startupIconCircle.layer.shadowColor = [UIColor systemGreenColor].CGColor;
    }
}

- (void)finishStartupAnimation {
    if (!_startupContainer) return;

    [_startupIconCircle.layer removeAnimationForKey:@"startupGlow"];

    // 不再瞬间隐藏/恢复尺寸：先让“启动完成”状态自然停留，再做
    // 轻微缩小 + 淡出，并与原浮窗内容交叉淡入，避免视觉上像被硬切掉。
    _performanceContainer.hidden = NO;
    _performanceContainer.alpha = 0.0f;
    _startupContainer.hidden = NO;
    _startupContainer.alpha = 1.0f;
    _startupContainer.transform = CGAffineTransformIdentity;

    [UIView animateWithDuration:0.62
                          delay:0.18
                        options:UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        self.startupContainer.alpha = 0.0f;
        self.startupContainer.transform = CGAffineTransformMakeScale(0.94f, 0.94f);
        self.performanceContainer.alpha = 1.0f;
    } completion:^(BOOL finished) {
        self.bounds = self.startupRestoreBounds;
        self.center = self.startupRestoreCenter;
        self.startupContainer.hidden = YES;
        self.startupContainer.alpha = 0.0f;
        self.startupContainer.transform = CGAffineTransformIdentity;
        self.performanceContainer.alpha = 1.0f;
        self.startupProgressFill.frame = CGRectMake(0, 0, 0, self.startupProgressTrack.bounds.size.height);

        updateFloatingSize();
        [self resetInactivityTimer];
    }];
}

- (void)triggerPlugAnimation {
    CAKeyframeAnimation *animation = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale"];
    animation.values = @[@1.0, @1.08, @0.96, @1.02, @1.0];
    animation.keyTimes = @[@0.0, @0.35, @0.65, @0.85, @1.0];
    animation.duration = 0.45;
    animation.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [_blurView.layer addAnimation:animation forKey:@"plugBounce"];

    CABasicAnimation *glowAnim = [CABasicAnimation animationWithKeyPath:@"borderColor"];
    glowAnim.fromValue = (id)[UIColor colorWithRed:0.2f green:0.95f blue:0.5f alpha:1.0f].CGColor;
    glowAnim.toValue = (id)[UIColor colorWithWhite:1.0f alpha:0.60f].CGColor;
    glowAnim.duration = 0.7;
    [_blurView.layer addAnimation:glowAnim forKey:@"borderGlow"];
}

- (void)updateLayoutWithShowCpuFreq:(BOOL)showFreq
                            showFps:(BOOL)showFps
                 showBatteryPercent:(BOOL)showBattery
                    showBatteryTemp:(BOOL)showTemp
                 showBatteryCurrent:(BOOL)showCurrent
                         isCharging:(BOOL)isCharging {
    
    if (self.isCollapsed && !self.isShowingNotification) return;

    BOOL hasUnread = (historyNotifications.count > 0 && !self.isShowingNotification);
    self.badgeLabel.hidden = !hasUnread;
    if (hasUnread) self.badgeLabel.text = [NSString stringWithFormat:@"%lu", (unsigned long)historyNotifications.count];

    BOOL showCombinedMode = (!self.isCollapsed && historyNotifications.count > 0) || self.isShowingNotification;

    self.performanceContainer.hidden = NO;
    self.performanceContainer.alpha = 1.0;

    _cpuTitleLabel.hidden = NO;
    _cpuValueLabel.hidden = NO;

    _cpuFreqLabel.hidden = !showFreq;
    _fpsTitleLabel.hidden = !showFps;
    _fpsValueLabel.hidden = !showFps;
    _fpsSubLabel.hidden = !showFps;
    _batteryIconLabel.hidden = !showBattery;
    _batteryValueLabel.hidden = !showBattery;
    _batterySubLabel.hidden = !showBattery;
    _tempIconView.hidden = !showTemp;
    _tempValueLabel.hidden = !showTemp;
    _tempSubLabel.hidden = !showTemp;

    BOOL actualShowCurrent = showBatteryCurrent && isCharging;
    _currentIconLabel.hidden = !actualShowCurrent;
    _currentValueLabel.hidden = !actualShowCurrent;
    _currentSubLabel.hidden = !actualShowCurrent;
    _bottomCapsule.hidden = !isCharging;

    CGFloat currentX = 14.0f;
    CGFloat padY = 6.0f; 

    CGFloat cpuW = 46.0f;
    _cpuTitleLabel.frame = CGRectMake(currentX, padY, cpuW, 12);
    _cpuValueLabel.frame = CGRectMake(currentX, padY + 12, cpuW, 18);
    if (showFreq) _cpuFreqLabel.frame = CGRectMake(currentX, padY + 31, cpuW, 12);
    else _cpuFreqLabel.frame = CGRectZero;
    currentX += cpuW + 4.0f;

    if (showFps || showBattery || showTemp || actualShowCurrent) {
        _div1.hidden = NO;
        _div1.frame = CGRectMake(currentX, padY + 4, 0.5f, 30.0f);
        currentX += 6.5f;
    } else { _div1.hidden = YES; }

    if (showFps) {
        CGFloat fpsW = 32.0f;
        _fpsTitleLabel.frame = CGRectMake(currentX, padY, fpsW, 12);
        _fpsValueLabel.frame = CGRectMake(currentX, padY + 12, fpsW, 18);
        _fpsSubLabel.frame = CGRectMake(currentX, padY + 31, fpsW, 12);
        currentX += fpsW + 4.0f;

        if (showBattery || showTemp || actualShowCurrent) {
            _divFps.hidden = NO;
            _divFps.frame = CGRectMake(currentX, padY + 4, 0.5f, 30.0f);
            currentX += 6.5f;
        } else { _divFps.hidden = YES; }
    } else { _divFps.hidden = YES; }

    if (showBattery) {
        CGFloat batW = 44.0f;
        _batteryIconLabel.frame = CGRectMake(currentX, padY + 10, 18, 18);
        _batteryValueLabel.frame = CGRectMake(currentX + 20, padY + 10, batW - 20, 16);
        _batterySubLabel.frame = CGRectMake(currentX + 20, padY + 27, batW - 20, 12);
        currentX += batW + 4.0f;

        if (showTemp || actualShowCurrent) {
            _div2.hidden = NO;
            _div2.frame = CGRectMake(currentX, padY + 4, 0.5f, 30.0f);
            currentX += 6.5f;
        } else { _div2.hidden = YES; }
    } else { _div2.hidden = YES; }

    if (showTemp) {
        CGFloat tempW = 54.0f;
        _tempIconView.frame = CGRectMake(currentX + 2, padY + 10, 16, 16); 
        _tempValueLabel.frame = CGRectMake(currentX + 20, padY + 10, tempW - 20, 16);
        _tempSubLabel.frame = CGRectMake(currentX + 20, padY + 27, tempW - 20, 12);
        currentX += tempW + 4.0f;

        if (actualShowCurrent) {
            _div3.hidden = NO;
            _div3.frame = CGRectMake(currentX, padY + 4, 0.5f, 30.0f);
            currentX += 6.5f;
        } else { _div3.hidden = YES; }
    } else { _div3.hidden = YES; }

    if (actualShowCurrent) {
        CGFloat curW = 56.0f;
        _currentIconLabel.frame = CGRectMake(currentX, padY + 11, 14, 18);
        _currentValueLabel.frame = CGRectMake(currentX + 16, padY + 10, curW - 16, 16);
        _currentSubLabel.frame = CGRectMake(currentX + 16, padY + 27, curW - 16, 12);
        currentX += curW + 4.0f;
    }

    CGFloat finalW = currentX + 10.0f; 
    if (finalW < 40.0f) finalW = 40.0f;
    if (showCombinedMode && finalW < 240.0f) finalW = 240.0f; 
    
    CGFloat currentY = padY + 44.0f; 

    if (isCharging) {
        currentY += 4.0f;
        _bottomCapsule.layer.cornerRadius = 7.0f;
        _batteryProgressView.layer.cornerRadius = 7.0f;
        _bottomCapsule.frame = CGRectMake(12.0f, currentY, finalW - 24.0f, 14.0f);
        _statusLabel.frame = CGRectMake(0, 0, finalW - 24.0f, 14.0f);
        currentY += 14.0f;
    }

    // 温控状态独立一行；updateCPU() 每秒调用 updateDataWithCPU，因此这里会实时刷新。
    currentY += 2.0f;
    _thermalStatusLabel.frame = CGRectMake(12.0f, currentY, finalW - 24.0f, 16.0f);
    currentY += 16.0f;

    // 时间显示行（仅横屏显示，竖屏隐藏并节省高度）
    BOOL isLandscapeNow = ([UIScreen mainScreen].bounds.size.width > [UIScreen mainScreen].bounds.size.height);
    if (isLandscapeNow) {
        _timeLabel.hidden = NO;
        currentY += 2.0f;
        _timeLabel.frame = CGRectMake(12.0f, currentY, finalW - 24.0f, 14.0f);
        currentY += 14.0f;
    } else {
        _timeLabel.hidden = YES;
    }

    if (showCombinedMode) {
        self.horizontalDiv.hidden = NO;
        self.notificationContainer.hidden = NO;
        self.notificationContainer.alpha = 1.0;

        currentY += 4.0f;
        self.horizontalDiv.frame = CGRectMake(14.0f, currentY, finalW - 28.0f, 0.5f);
        currentY += 4.0f;

        SBNotifReq *req = self.currentNotification ?: historyNotifications.firstObject;
        NSString *appName = @"消息";
        NSString *icon = @"💬";
        if ([req.bundleID isEqualToString:@"com.tencent.xin"]) { appName = @"微信"; icon = @"🟢"; }
        else if ([req.bundleID.lowercaseString containsString:@"qq"]) { appName = @"QQ"; icon = @"🔵"; }
        else if ([req.bundleID isEqualToString:@"com.tencent.tim"]) { appName = @"TIM"; icon = @"🔷"; }
        
        NSUInteger count = historyNotifications.count;
        if (count == 0 && self.currentNotification) count = 1;
        
        self.notifAppNameLabel.text = [NSString stringWithFormat:@"%@ %@ • %@", icon, appName, req.title];
        
        BOOL isLocked = NO;
        Class lockClass = NSClassFromString(@"SBLockScreenManager");
        if (lockClass && [lockClass respondsToSelector:@selector(sharedInstance)]) {
            id mgr = [lockClass performSelector:@selector(sharedInstance)];
            if ([mgr respondsToSelector:@selector(isUILocked)]) {
                isLocked = (BOOL)[mgr performSelector:@selector(isUILocked)];
            }
        }
        self.notifMessageLabel.text = (hideContentOnLockScreen && isLocked) ? @"你收到一条新消息" : req.message;

        self.notificationContainer.frame = CGRectMake(0, currentY, finalW, 38.0f);
        self.notifAppNameLabel.frame = CGRectMake(14.0f, 4.0f, finalW - 28.0f, 14.0f);
        self.notifMessageLabel.frame = CGRectMake(14.0f, 20.0f, finalW - 28.0f, 14.0f);

        currentY += 38.0f;
    } else {
        self.horizontalDiv.hidden = YES;
        self.notificationContainer.hidden = YES;
        self.notificationContainer.alpha = 0.0;
    }

    currentY += 8.0f; 

    if (!self.badgeLabel.hidden) {
        UIView *parent = self.superview;
        CGFloat screenW = parent ? parent.bounds.size.width : [UIScreen mainScreen].bounds.size.width;
        BOOL isLeft = (self.center.x <= screenW / 2.0f);
        
        CGFloat badgeW = 20.0f;
        CGFloat targetBadgeX = isLeft ? (finalW - badgeW/2.0f - 4.0f) : (-badgeW/2.0f + 4.0f);
        self.badgeLabel.frame = CGRectMake(targetBadgeX, -6.0f, badgeW, 14.0f);
    }

    _blurView.frame = CGRectMake(0, 0, finalW, currentY);
    
    CGFloat cornerRad = floatingCornerRadius;
    if (cornerRad > currentY / 2.0f) cornerRad = currentY / 2.0f;
    
    _blurView.layer.cornerRadius = cornerRad;
    self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, finalW, currentY) cornerRadius:cornerRad].CGPath;

    _marqueeLayer.frame = _blurView.bounds;
    _marqueeLayer.path = [UIBezierPath bezierPathWithRoundedRect:_blurView.bounds cornerRadius:cornerRad].CGPath;

    // 液态玻璃 specular 高光层与边缘光跟随布局
    if (_glassBackdropLayer) {
        _glassBackdropLayer.frame = _blurView.bounds;
        _glassBackdropLayer.cornerRadius = cornerRad;
    }
    if (_glassTintLayer) {
        _glassTintLayer.frame = _blurView.bounds;
        _glassTintLayer.cornerRadius = cornerRad;
    }
    _glassSheenLayer.frame = _blurView.bounds;
    _glassSheenMask.frame = _blurView.bounds;
    _glassSheenMask.cornerRadius = cornerRad;
    _glassBoostLayer.frame = _blurView.bounds;
    _glassBoostMask.frame = _blurView.bounds;
    _glassBoostMask.cornerRadius = cornerRad;
    _glassEdgeLayer.frame = _blurView.bounds;
    _glassEdgeLayer.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(_blurView.bounds, 0.5f, 0.5f) cornerRadius:cornerRad].CGPath;

    if (isCharging) {
        _marqueeLayer.hidden = NO;
        if (![_marqueeLayer animationForKey:@"marqueeDashAnim"]) {
            CABasicAnimation *dashAnim = [CABasicAnimation animationWithKeyPath:@"lineDashPhase"];
            dashAnim.fromValue = @(0);
            dashAnim.toValue = @(-40);
            dashAnim.duration = 0.8;
            dashAnim.repeatCount = HUGE_VALF;
            [_marqueeLayer addAnimation:dashAnim forKey:@"marqueeDashAnim"];
        }
    } else {
        _marqueeLayer.hidden = YES;
        [_marqueeLayer removeAnimationForKey:@"marqueeDashAnim"];
    }

    self.bounds = CGRectMake(0, 0, finalW, currentY);
    self.performanceContainer.frame = self.bounds;
}

- (void)resetInactivityTimer {
    if (_inactivityTimer) {
        [_inactivityTimer invalidate];
        _inactivityTimer = nil;
    }

    // 超级快充启动动画期间，绝对不能启动自动折叠计时器。
    // 否则动画运行到一半时 inactivityTimer 会把原浮窗折叠成小胶囊，
    // 导致启动动画一起消失。动画结束后 finishStartupAnimation 会重新启动计时器。
    if (fastChargeStartupAnimating) return;

    if (autoCollapseEnable && !_isCollapsed && !settingsShowing && !detailShowing && !self.isShowingNotification) {
        if (autoExpandLandscape) {
            UIInterfaceOrientation orientation = getEffectiveFloatingOrientation();
            BOOL isLandscape = (orientation == UIInterfaceOrientationLandscapeLeft || orientation == UIInterfaceOrientationLandscapeRight);
            if (isLandscape) return; 
        }
        
        _inactivityTimer = [NSTimer scheduledTimerWithTimeInterval:autoCollapseDelay
                                                             target:self
                                                           selector:@selector(inactivityTimerFired)
                                                           userInfo:nil
                                                            repeats:NO];
    }
}

- (void)inactivityTimerFired {
    [_inactivityTimer invalidate];
    _inactivityTimer = nil;

    // 启动动画拥有更高优先级：即使旧 NSTimer 已经进入回调，
    // 也不能在动画未完成前折叠/隐藏浮窗。
    if (fastChargeStartupAnimating) return;

    if (!settingsShowing && !detailShowing && !_isCollapsed && !self.isShowingNotification) {
        UIInterfaceOrientation orientation = getEffectiveFloatingOrientation();
        BOOL isLandscape = (orientation == UIInterfaceOrientationLandscapeLeft || orientation == UIInterfaceOrientationLandscapeRight);
        if (autoExpandLandscape && isLandscape) {
            return;
        }
        [self collapseToEdgeAnimated:YES];
    }
}

- (void)collapseToEdgeAnimated:(BOOL)animated {
    if (_isCollapsed || self.isShowingNotification) return;
    _isCollapsed = YES;

    UIView *parent = self.superview;
    CGRect containerBounds = parent ? parent.bounds : [UIScreen mainScreen].bounds;

    CGFloat targetW = 68.0f;
    CGFloat targetH = 28.0f;
    CGFloat targetHalfW = targetW / 2.0f;
    CGFloat targetHalfH = targetH / 2.0f;

    BOOL isLeft = (self.center.x <= containerBounds.size.width / 2.0f);
    CGFloat targetX = isLeft ? (targetHalfW + 4.0f) : (containerBounds.size.width - targetHalfW - 4.0f);
    
    CGFloat minY = targetHalfH + floatingTopSafeMargin(parent);
    CGFloat maxY = containerBounds.size.height - targetHalfH - 10.0f;
    CGFloat targetY = MIN(MAX(self.center.y, minY), maxY);

    CGPoint targetCenter = CGPointMake(targetX, targetY);

    self.performanceContainer.hidden = NO;
    self.performanceContainer.alpha = 1.0;
    self.collapsedContainerView.hidden = NO;

    void (^animationsBlock)(void) = ^{
        for (UIView *v in self.performanceContainer.subviews) {
            if (v != self.collapsedContainerView) v.alpha = 0.0;
        }
        self.horizontalDiv.alpha = 0.0;
        self.notificationContainer.alpha = 0.0;

        self.collapsedContainerView.alpha = 1.0;
        self.collapsedContainerView.frame = CGRectMake(0, 0, targetW, targetH);

        self.blurView.frame = CGRectMake(0, 0, targetW, targetH);
        
        CGFloat cornerRad = floatingCornerRadius;
        if (cornerRad > targetH / 2.0f) cornerRad = targetH / 2.0f;
        
        self.blurView.layer.cornerRadius = cornerRad;
        self.bounds = CGRectMake(0, 0, targetW, targetH);
        self.center = targetCenter;

        if (!self.badgeLabel.hidden) {
            CGFloat badgeW = 20.0f;
            CGFloat targetBadgeX = isLeft ? (targetW - badgeW/2.0f - 4.0f) : (-badgeW/2.0f + 4.0f);
            self.badgeLabel.frame = CGRectMake(targetBadgeX, -6.0f, badgeW, 14.0f);
        }

        self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, targetW, targetH) cornerRadius:cornerRad].CGPath;
        self.marqueeLayer.frame = self.blurView.bounds;
        self.marqueeLayer.path = [UIBezierPath bezierPathWithRoundedRect:self.blurView.bounds cornerRadius:cornerRad].CGPath;

        // 液态玻璃 specular 高光层与边缘光跟随折叠尺寸
        if (self.glassBackdropLayer) {
            self.glassBackdropLayer.frame = self.blurView.bounds;
            self.glassBackdropLayer.cornerRadius = cornerRad;
        }
        if (self.glassTintLayer) {
            self.glassTintLayer.frame = self.blurView.bounds;
            self.glassTintLayer.cornerRadius = cornerRad;
        }
        self.glassSheenLayer.frame = self.blurView.bounds;
        self.glassSheenMask.frame = self.blurView.bounds;
        self.glassSheenMask.cornerRadius = cornerRad;
        self.glassBoostLayer.frame = self.blurView.bounds;
        self.glassBoostMask.frame = self.blurView.bounds;
        self.glassBoostMask.cornerRadius = cornerRad;
        self.glassEdgeLayer.frame = self.blurView.bounds;
        self.glassEdgeLayer.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(self.blurView.bounds, 0.5f, 0.5f) cornerRadius:cornerRad].CGPath;
    };

    void (^completionBlock)(BOOL) = ^(BOOL finished) {
        (void)finished;
        if (self.isCollapsed) {
            for (UIView *v in self.performanceContainer.subviews) {
                if (v != self.collapsedContainerView) v.hidden = YES;
            }
            self.horizontalDiv.hidden = YES;
            self.notificationContainer.hidden = YES;
            self.notificationContainer.alpha = 0.0;
            self.collapsedContainerView.hidden = NO;
            self.collapsedContainerView.alpha = 1.0;
        }
    };

    if (animated) {
        // 折叠动画期间不要人为显示 notificationContainer，否则消息到达时会和折叠动画竞争。
        self.collapsedContainerView.hidden = NO;
        self.collapsedContainerView.alpha = 0.0;
        self.notificationContainer.hidden = YES;
        self.notificationContainer.alpha = 0.0;
        self.horizontalDiv.hidden = YES;
        self.horizontalDiv.alpha = 0.0;

        [UIView animateWithDuration:0.45 delay:0 usingSpringWithDamping:0.75 initialSpringVelocity:0.4 options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState animations:animationsBlock completion:completionBlock];
    } else {
        animationsBlock();
        completionBlock(YES);
    }
}

- (void)expandFromEdgeAnimated:(BOOL)animated {
    if (!_isCollapsed || self.isShowingNotification) {
        [self resetInactivityTimer];
        return;
    }
    _isCollapsed = NO;
    self.collapsedContainerView.hidden = NO;
    self.collapsedContainerView.alpha = 0.0;
    self.notificationContainer.hidden = YES;
    self.notificationContainer.alpha = 0.0;

    BOOL charging = isChargingInternal();
    UIView *parent = self.superview;
    CGRect containerBounds = parent ? parent.bounds : [UIScreen mainScreen].bounds;

    for (UIView *v in self.performanceContainer.subviews) {
        if (v != self.collapsedContainerView) {
            v.hidden = NO;
            v.alpha = 0.0;
        }
    }

    [self updateLayoutWithShowCpuFreq:showCpuFrequency
                               showFps:showFps
                    showBatteryPercent:showBatteryPercent
                       showBatteryTemp:showBatteryTemperature
                    showBatteryCurrent:showBatteryCurrent
                            isCharging:charging];

    CGFloat expandedW = self.bounds.size.width;
    CGFloat expandedH = self.bounds.size.height;
    CGFloat expandedHalfW = expandedW / 2.0f;
    CGFloat expandedHalfH = expandedH / 2.0f;

    BOOL isLeft = (self.center.x <= containerBounds.size.width / 2.0f);
    CGFloat targetX = isLeft ? (expandedHalfW + 4.0f) : (containerBounds.size.width - expandedHalfW - 4.0f);
    
    CGFloat minY = expandedHalfH + floatingTopSafeMargin(parent);
    CGFloat maxY = containerBounds.size.height - expandedHalfH - 10.0f;
    CGFloat targetY = MIN(MAX(self.center.y, minY), maxY);

    CGPoint targetCenter = CGPointMake(targetX, targetY);

    void (^animationsBlock)(void) = ^{
        self.collapsedContainerView.alpha = 0.0;
        self.horizontalDiv.alpha = 1.0;
        
        for (UIView *v in self.performanceContainer.subviews) {
            if (v != self.collapsedContainerView && !v.hidden) v.alpha = 1.0;
        }

        self.center = targetCenter;
    };

    void (^completionBlock)(BOOL) = ^(BOOL finished) {
        (void)finished;
        if (!self.isCollapsed) {
            self.collapsedContainerView.hidden = YES;
            self.collapsedContainerView.alpha = 0.0;
        }
        [self resetInactivityTimer];
    };

    if (animated) {
        [UIView animateWithDuration:0.45 delay:0 usingSpringWithDamping:0.75 initialSpringVelocity:0.5 options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState animations:animationsBlock completion:completionBlock];
    } else {
        animationsBlock();
        completionBlock(YES);
    }
}

- (void)showNotification:(SBNotifReq *)req {
    if (!req) return;

    if (!self.isShowingNotification) {
        self.wasCollapsedBeforeNotification = self.isCollapsed;
    }

    // 收到新消息时，无论之前是否处于折叠状态，都先恢复完整的展开视觉状态。
    // 旧版本只把 hidden=NO，却没有恢复 alpha；折叠完成后各信息项 alpha=0，
    // 因此会出现“只有消息在下面、上面全部空白”以及“折叠后完全没有信息”的问题。
    [self.layer removeAllAnimations];
    self.isCollapsed = NO;
    self.isShowingNotification = YES;
    self.currentNotification = req;

    [self.inactivityTimer invalidate];
    self.inactivityTimer = nil;

    [self.notificationTimer invalidate];
    self.notificationTimer = [NSTimer scheduledTimerWithTimeInterval:notificationDuration
                                                               target:self
                                                             selector:@selector(hideNotification)
                                                             userInfo:nil
                                                              repeats:NO];

    self.performanceContainer.hidden = NO;
    self.performanceContainer.alpha = 1.0;
    self.collapsedContainerView.hidden = YES;
    self.collapsedContainerView.alpha = 0.0;

    // 恢复折叠时被隐藏/淡出的所有性能信息。
    for (UIView *v in self.performanceContainer.subviews) {
        if (v != self.collapsedContainerView) {
            v.hidden = NO;
            v.alpha = 1.0;
        }
    }

    self.horizontalDiv.hidden = NO;
    self.horizontalDiv.alpha = 1.0;
    self.notificationContainer.hidden = NO;
    self.notificationContainer.alpha = 1.0;

    // 先立即重建完整布局，再做一次轻微动画，避免消息区域出现空白。
    updateFloatingSize();

    [UIView animateWithDuration:0.25
                          delay:0
                        options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseOut
                     animations:^{
                         self.collapsedContainerView.alpha = 0.0;
                         self.notificationContainer.alpha = 1.0;
                     }
                     completion:nil];
}

- (void)hideNotification {
    if (self.notificationQueue.count > 0) [self.notificationQueue removeObjectAtIndex:0];
    if (self.notificationQueue.count > 0) {
        [self showNotification:self.notificationQueue.firstObject];
        return;
    }
    
    self.isShowingNotification = NO;
    self.currentNotification = nil;
    
    if (self.wasCollapsedBeforeNotification) {
        [self collapseToEdgeAnimated:YES];
    } else {
        [self resetInactivityTimer];
        [UIView animateWithDuration:0.4 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0.5 options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState animations:^{
            updateFloatingSize(); 
        } completion:^(BOOL finished) {
            [self resetInactivityTimer];
        }];
    }
}

- (void)updateDataWithCPU:(double)cpu 
                  cpuFreq:(double)cpuFreq
                      fps:(double)fps
                  battery:(NSInteger)battery 
                     temp:(double)temp 
                  current:(double)current 
               isCharging:(BOOL)isCharging {
    
    _cpuValueLabel.text = [NSString stringWithFormat:@"%.1f%%", cpu];
    _cpuValueLabel.textColor = (cpu >= 80.0) ? [UIColor systemRedColor] : [UIColor colorWithRed:0.18f green:0.75f blue:0.35f alpha:1.0f];

    _cpuFreqLabel.text = [NSString stringWithFormat:@"%.0f MHz", cpuFreq];
    _fpsValueLabel.text = [NSString stringWithFormat:@"%.0f", fps];
    _batteryValueLabel.text = [NSString stringWithFormat:@"%ld%%", (long)battery];
    _tempValueLabel.text = (temp > 0) ? [NSString stringWithFormat:@"%.1f°C", temp] : @"--°C";
    _currentValueLabel.text = [NSString stringWithFormat:@"%.0f mA", current];

    // 直接读取 SBCPUThermal 的核心心跳、保护状态和诊断热压力。
    // 不读取设置页面的静态文字，所以浮窗每次刷新都会显示最新状态。
    if (!fastChargeStartupAnimating) {
        NSString *thermalText = nil;
        UIColor *thermalColor = nil;
        sbcputhermalFloatingStatus(&thermalText, &thermalColor);
        _thermalStatusLabel.text = thermalText ?: @"温控：检测中";
        _thermalStatusLabel.textColor = thermalColor ?: [UIColor systemBlueColor];
    }
    
    if (!fastChargeStartupAnimating) {
        if (smartChargeEnable) {
            NSInteger scPercent = getBatteryPercentForSmartCharge();
            if (smartChargeStopped) {
                _statusLabel.text = [NSString stringWithFormat:@"🛑 停充中 · %ld%% (上限%ld)", (long)scPercent, (long)smartChargeUpperLimit];
                _statusLabel.textColor = [UIColor systemOrangeColor];
            } else if (isCharging) {
                _statusLabel.text = [NSString stringWithFormat:@"🔋 智能停充待触发 · %ld%%→%ld%%", (long)scPercent, (long)smartChargeUpperLimit];
                _statusLabel.textColor = [UIColor systemBlueColor];
            } else {
                _statusLabel.text = [NSString stringWithFormat:@"🔋 智能停充已启用 · %ld%%", (long)scPercent];
                _statusLabel.textColor = [UIColor systemGrayColor];
            }
        } else if (forceFastChargeEnable && isCharging) {
            NSDictionary *chargeInfo = getRealBatteryDetails();
            double watts = [chargeInfo[@"CalculatedWatts"] doubleValue];
            _statusLabel.text = [NSString stringWithFormat:@"🔥 强制满血快充 · %.1fW", MAX(0.0, watts)];
            _statusLabel.textColor = [UIColor systemRedColor];
        } else if (chargeBoostEnable && isCharging) {
            NSDictionary *chargeInfo = getRealBatteryDetails();
            double watts = [chargeInfo[@"CalculatedWatts"] doubleValue];
            NSString *verify = chargeBoostVerified ? @"已验证功率提升" : @"实时验证中";
            _statusLabel.text = [NSString stringWithFormat:@"⚡ 充电增强 · %.1fW · %@", MAX(0.0, watts), verify];
            _statusLabel.textColor = chargeBoostVerified ? [UIColor systemGreenColor] : [UIColor systemBlueColor];
        } else {
            _statusLabel.text = isCharging ? @"正在充电" : @"未在充电";
            _statusLabel.textColor = [UIColor colorWithRed:0.15f green:0.65f blue:0.3f alpha:1.0f];
        }
    }

    if (isCharging && !fastChargeStartupAnimating) {
        CGFloat capsuleW = _bottomCapsule.bounds.size.width;
        CGFloat capsuleH = _bottomCapsule.bounds.size.height > 0 ? _bottomCapsule.bounds.size.height : 14.0f;
        CGFloat targetProgressW = MAX(0, MIN(capsuleW, capsuleW * (battery / 100.0f)));
        
        [UIView animateWithDuration:0.35 animations:^{
            self.batteryProgressView.frame = CGRectMake(0, 0, targetProgressW, capsuleH);
        }];
    }

    if (collapsedDisplayMode == 0) {
        _miniCpuLabel.text = [NSString stringWithFormat:@"%.0f%%", cpu];
    } else if (collapsedDisplayMode == 1) {
        _miniCpuLabel.text = [NSString stringWithFormat:@"%.0f", fps];
    } else if (collapsedDisplayMode == 2) {
        _miniCpuLabel.text = (temp > 0) ? [NSString stringWithFormat:@"%.0f°", temp] : @"--°";
    } else if (collapsedDisplayMode == 3) {
        _miniCpuLabel.text = [NSString stringWithFormat:@"%.0fmA", current];
    } else if (collapsedDisplayMode == 4) {
        _miniCpuLabel.text = [NSString stringWithFormat:@"%ld%%", (long)MAX(0, MIN(100, battery))];
    }
    
    if (YES) {
        UIColor *statusColor = [UIColor darkGrayColor];
        if (isCharging) {
            if (forceFastChargeEnable) statusColor = [UIColor systemRedColor];
            else statusColor = chargeBoostEnable ? [UIColor systemBlueColor] : [UIColor colorWithRed:0.0f green:0.8f blue:0.4f alpha:1.0f];
        } else if (cpu >= 80.0 || temp >= 42.0) statusColor = [UIColor systemRedColor];
        else if (temp >= 38.0) statusColor = [UIColor systemOrangeColor];
        _statusDot.backgroundColor = statusColor;
    }
    // 更新时间显示（HH:mm:ss）
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"HH:mm:ss";
    _timeLabel.text = [fmt stringFromDate:[NSDate date]];

    // 液态玻璃：每次数据刷新后更新文字反色（深浅模式自适应）
    [self applyAdaptiveTextColors];
}

@end

#pragma mark - 7. 详细状态 UI 面板与数据绑定

@implementation SBCPUDetailViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0 alpha:0.25];
    _labelsDict = [NSMutableDictionary dictionary];

    if ([CMPedometer isStepCountingAvailable]) {
        _pedometer = [[CMPedometer alloc] init];
    }

    UITapGestureRecognizer *tapBg = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(closeDetailView)];
    [self.view addGestureRecognizer:tapBg];

    CGFloat margin = 16.0;
    CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
    CGFloat screenH = [UIScreen mainScreen].bounds.size.height;
    CGFloat panelW = MIN(screenW - margin * 2, 420.0);
    CGFloat panelH = MIN(screenH - margin * 4, 340.0);

    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialLight];
    _blurEffectView = [[UIVisualEffectView alloc] initWithEffect:blur];
    _blurEffectView.frame = CGRectMake((screenW - panelW)/2.0, (screenH - panelH)/2.0, panelW, panelH);
    _blurEffectView.layer.cornerRadius = 24.0;
    _blurEffectView.layer.masksToBounds = YES;
    _blurEffectView.layer.borderWidth = 0.0;
    [self.view addSubview:_blurEffectView];

    UITapGestureRecognizer *preventTap = [[UITapGestureRecognizer alloc] initWithTarget:nil action:nil];
    [_blurEffectView addGestureRecognizer:preventTap];

    UIView *contentView = _blurEffectView.contentView;

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, panelW - 60, 22)];
    titleLabel.text = @"系统与电池详细状态";
    titleLabel.textColor = [UIColor blackColor];
    titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    [contentView addSubview:titleLabel];

    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    closeBtn.frame = CGRectMake(panelW - 38, 10, 26, 26);
    [closeBtn setTitle:@"✕" forState:UIControlStateNormal];
    [closeBtn setTitleColor:[UIColor darkGrayColor] forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
    [closeBtn addTarget:self action:@selector(closeDetailView) forControlEvents:UIControlEventTouchUpInside];
    [contentView addSubview:closeBtn];

    UIView *line = [[UIView alloc] initWithFrame:CGRectMake(0, 40, panelW, 0.5)];
    line.backgroundColor = [UIColor colorWithWhite:0 alpha:0.1]; 
    [contentView addSubview:line];

    CGFloat colW = (panelW - 20) / 2.0;
    CGFloat startY = 46.0;
    CGFloat rowH = 22.0;

    NSArray *leftKeys = @[
        @"电池健康程度", @"电池循环次数", @"电池预计充满", @"电池充电类型",
        @"电池充电功率", @"电池当前电流", @"电池当前电压", @"电池当前温度",
        @"电池当前电量", @"电池设计容量", @"电池实际容量", @"电池当前容量"
    ];

    NSArray *rightKeys = @[
        @"设备名称", @"软件版本", @"网络信息", @"内网地址",
        @"实时网速", @"系统总 CPU", @"CPU主频 / FPS", @"内存剩余",
        @"存储剩余", @"蜂窝/WiFi", @"运动信息", @"设备运行"
    ];

    for (NSInteger i = 0; i < leftKeys.count; i++) {
        NSString *key = leftKeys[i];
        UILabel *lbl = [self createRowWithTitle:key x:10 y:startY + i * rowH width:colW parent:contentView];
        _labelsDict[key] = lbl;
    }

    for (NSInteger i = 0; i < rightKeys.count; i++) {
        NSString *key = rightKeys[i];
        UILabel *lbl = [self createRowWithTitle:key x:10 + colW y:startY + i * rowH width:colW parent:contentView];
        _labelsDict[key] = lbl;
    }
}

- (UILabel *)createRowWithTitle:(NSString *)title x:(CGFloat)x y:(CGFloat)y width:(CGFloat)width parent:(UIView *)parent {
    UILabel *keyLbl = [[UILabel alloc] initWithFrame:CGRectMake(x, y, width * 0.46, 20)];
    keyLbl.text = [NSString stringWithFormat:@"%@:", title];
    keyLbl.textColor = [UIColor darkGrayColor];
    keyLbl.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightMedium];
    keyLbl.adjustsFontSizeToFitWidth = YES;
    [parent addSubview:keyLbl];

    UILabel *valLbl = [[UILabel alloc] initWithFrame:CGRectMake(x + width * 0.46, y, width * 0.52, 20)];
    valLbl.textColor = [UIColor blackColor];
    valLbl.font = [UIFont monospacedDigitSystemFontOfSize:10.5 weight:UIFontWeightBold];
    valLbl.adjustsFontSizeToFitWidth = YES;
    valLbl.minimumScaleFactor = 0.5;
    [parent addSubview:valLbl];

    return valLbl;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshAllDetailData];
    _refreshTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(refreshAllDetailData) userInfo:nil repeats:YES];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [_refreshTimer invalidate];
    _refreshTimer = nil;
}

- (void)closeDetailView {
    detailShowing = NO;
    [self dismissViewControllerAnimated:YES completion:^{
        if (floatingView) [floatingView resetInactivityTimer];
    }];
}

- (void)refreshAllDetailData {
    DeviceSpec spec = getDeviceSpec();
    NSDictionary *batInfo = getRealBatteryDetails();

    NSInteger designCap = [batInfo[@"DesignCapacity"] integerValue];
    if (designCap <= 0) designCap = spec.designBatteryCapacity;

    NSInteger maxCap = [batInfo[@"MaxCapacity"] integerValue];
    if (maxCap <= 100 && designCap > 0) {
        maxCap = designCap;
    }

    [UIDevice currentDevice].batteryMonitoringEnabled = YES;
    NSInteger batPercent = (NSInteger)([UIDevice currentDevice].batteryLevel * 100);
    if (batPercent < 0) batPercent = 100;

    NSInteger curCap = [batInfo[@"CurrentCapacity"] integerValue];
    if (curCap <= 100) {
        curCap = (NSInteger)(maxCap * (batPercent / 100.0));
    }

    double health = (designCap > 0) ? ((double)maxCap / (double)designCap * 100.0) : 100.0;
    if (health > 105.0) health = 100.0;

    NSString *mfg = batInfo[@"Manufacturer"] ?: @"Apple";
    if (mfg.length == 0) mfg = @"Apple";

    _labelsDict[@"电池健康程度"].text = [NSString stringWithFormat:@"%.0f%% %@", health, mfg];

    NSInteger cycles = [batInfo[@"CycleCount"] integerValue];
    _labelsDict[@"电池循环次数"].text = [NSString stringWithFormat:@"%ld次", (long)cycles];

    BOOL charging = isChargingInternal();
    NSInteger timeToFull = [batInfo[@"AvgTimeToFull"] integerValue];
    if (charging && timeToFull > 0 && timeToFull < 600) {
        _labelsDict[@"电池预计充满"].text = [NSString stringWithFormat:@"%ld小时 %ld分钟", (long)(timeToFull / 60), (long)(timeToFull % 60)];
    } else {
        _labelsDict[@"电池预计充满"].text = charging ? @"计算中..." : @"未在充电";
    }

    _labelsDict[@"电池充电类型"].text = charging ? (batInfo[@"ChargerType"] ?: @"PD 快充") : @"未充电";

    double watts = [batInfo[@"CalculatedWatts"] doubleValue];
    if (watts < 0.1) watts = 0.0;
    _labelsDict[@"电池充电功率"].text = charging ? [NSString stringWithFormat:@"%.1fW%@", watts, (chargeBoostEnable || forceFastChargeEnable) ? @" · 增强" : @""] : @"0W";

    double currentmA = getBatteryCurrentInternal();
    _labelsDict[@"电池当前电流"].text = [NSString stringWithFormat:@"%.0fmA", currentmA];

    double voltage = [batInfo[@"Voltage"] doubleValue] / 1000.0;
    _labelsDict[@"电池当前电压"].text = (voltage > 0) ? [NSString stringWithFormat:@"%.2fV", voltage] : @"3.95V";

    double temp = getBatteryTemperatureInternal();
    _labelsDict[@"电池当前温度"].text = (temp > -10) ? [NSString stringWithFormat:@"%.1f°C", temp] : @"--°C";

    _labelsDict[@"电池当前电量"].text = [NSString stringWithFormat:@"%ld%%", (long)batPercent];

    _labelsDict[@"电池设计容量"].text = [NSString stringWithFormat:@"%ldmAh", (long)designCap];
    _labelsDict[@"电池实际容量"].text = [NSString stringWithFormat:@"%ldmAh", (long)maxCap];
    _labelsDict[@"电池当前容量"].text = [NSString stringWithFormat:@"%ldmAh", (long)curCap];

    _labelsDict[@"设备名称"].text = [NSString stringWithUTF8String:spec.modelName];
    _labelsDict[@"软件版本"].text = [UIDevice currentDevice].systemVersion;
    
    _labelsDict[@"网络信息"].text = getNetworkType();
    
    NSString *address = @"127.0.0.1";
    struct ifaddrs *interfaces = NULL;
    struct ifaddrs *temp_addr = NULL;
    if (getifaddrs(&interfaces) == 0) {
        temp_addr = interfaces;
        while (temp_addr != NULL) {
            if (temp_addr->ifa_addr && temp_addr->ifa_addr->sa_family == AF_INET) {
                NSString *name = [NSString stringWithUTF8String:temp_addr->ifa_name];
                if ([name isEqualToString:@"en0"]) {
                    address = [NSString stringWithUTF8String:inet_ntoa(((struct sockaddr_in *)temp_addr->ifa_addr)->sin_addr)];
                }
            }
            temp_addr = temp_addr->ifa_next;
        }
    }
    if (interfaces) freeifaddrs(interfaces);
    _labelsDict[@"内网地址"].text = address;

    struct ifaddrs *ifa_list = NULL;
    if (getifaddrs(&ifa_list) >= 0) {
        uint64_t wifiIn = 0, wifiOut = 0, cellIn = 0, cellOut = 0;
        for (struct ifaddrs *ifa = ifa_list; ifa; ifa = ifa->ifa_next) {
            if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_LINK) continue;
            struct if_data *if_data = (struct if_data *)ifa->ifa_data;
            if (!if_data) continue;
            NSString *name = [NSString stringWithUTF8String:ifa->ifa_name];
            if ([name hasPrefix:@"en"]) { wifiIn += if_data->ifi_ibytes; wifiOut += if_data->ifi_obytes; }
            else if ([name hasPrefix:@"pdp_ip"] || [name hasPrefix:@"ipsec"] || [name hasPrefix:@"rmnet"] || [name hasPrefix:@"pdp"]) { cellIn += if_data->ifi_ibytes; cellOut += if_data->ifi_obytes; }
        }
        freeifaddrs(ifa_list);
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        double timeDiff = now - lastNetSpeedTime;
        if (timeDiff <= 0) timeDiff = 1.0;
        if (lastWifiInBytes > 0) {
            speedDownBytesPerSec = (uint64_t)((wifiIn - lastWifiInBytes + cellIn - lastCellInBytes) / timeDiff);
            speedUpBytesPerSec = (uint64_t)((wifiOut - lastWifiOutBytes + cellOut - lastCellOutBytes) / timeDiff);
        }
        lastWifiInBytes = wifiIn; lastWifiOutBytes = wifiOut; lastCellInBytes = cellIn; lastCellOutBytes = cellOut; lastNetSpeedTime = now;
    }
    _labelsDict[@"实时网速"].text = [NSString stringWithFormat:@"↑%lluK ↓%lluK", speedUpBytesPerSec / 1024, speedDownBytesPerSec / 1024];

    double totalSystemCpu = getTotalCPUUsage();
    _labelsDict[@"系统总 CPU"].text = [NSString stringWithFormat:@"%s %ld核心 %.0f%%", spec.chipName, (long)spec.cores, totalSystemCpu];

    double freq = getRealCPUFrequency(totalSystemCpu);
    double fps = [SBCPUFPSHelper sharedInstance].currentFPS;
    _labelsDict[@"CPU主频 / FPS"].text = [NSString stringWithFormat:@"%.0fMHz | %.0fFPS", freq, fps];

    uint64_t memsize = 0;
    size_t size = sizeof(memsize);
    if (sysctlbyname("hw.memsize", &memsize, &size, NULL, 0) != 0 || memsize == 0) {
        memsize = [NSProcessInfo processInfo].physicalMemory;
    }
    uint64_t totalRAM_GB = (uint64_t)ceil((double)memsize / (1024.0 * 1024.0 * 1024.0));
    if (totalRAM_GB == 0) totalRAM_GB = 6;

    mach_port_t host_port = mach_host_self();
    mach_msg_type_number_t host_size = sizeof(vm_statistics64_data_t) / sizeof(integer_t);
    vm_size_t pagesize;
    host_page_size(host_port, &pagesize);
    vm_statistics64_data_t vm_stat;
    if (host_statistics64(host_port, HOST_VM_INFO64, (host_info64_t)&vm_stat, &host_size) == KERN_SUCCESS) {
        uint64_t freeBytes = (uint64_t)(vm_stat.free_count + vm_stat.inactive_count + vm_stat.speculative_count) * (uint64_t)pagesize;
        uint64_t freeMB = freeBytes / (1024 * 1024);
        _labelsDict[@"内存剩余"].text = [NSString stringWithFormat:@"%lluMB / %lluGB", freeMB, totalRAM_GB];
    }

    NSDictionary *fsAttrs = [[NSFileManager defaultManager] attributesOfFileSystemForPath:NSHomeDirectory() error:nil];
    int64_t freeDisk = [fsAttrs[NSFileSystemFreeSize] longLongValue];
    int64_t totalDisk = [fsAttrs[NSFileSystemSize] longLongValue];
    _labelsDict[@"存储剩余"].text = [NSString stringWithFormat:@"%.2fGB / %lldGB", freeDisk / (1024.0 * 1024.0 * 1024.0), (int64_t)round((double)totalDisk / (1024.0 * 1024.0 * 1024.0))];

    _labelsDict[@"蜂窝/WiFi"].text = [NSString stringWithFormat:@"%lluMB / %lluMB", lastCellInBytes / (1024 * 1024), lastWifiInBytes / (1024 * 1024)];

    if (_pedometer) {
        NSDate *now = [NSDate date];
        NSCalendar *cal = [NSCalendar currentCalendar];
        NSDateComponents *comp = [cal components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay fromDate:now];
        NSDate *zeroDate = [cal dateFromComponents:comp];

        [_pedometer queryPedometerDataFromDate:zeroDate toDate:now withHandler:^(CMPedometerData * _Nullable pedometerData, NSError * _Nullable error) {
            (void)error;
            if (pedometerData) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.labelsDict[@"运动信息"].text = [NSString stringWithFormat:@"%@步 %@层 %@m", pedometerData.numberOfSteps ?: @0, pedometerData.floorsAscended ?: @0, pedometerData.distance ? [NSString stringWithFormat:@"%.0f", pedometerData.distance.doubleValue] : @"0"];
                });
            }
        }];
    }

    NSTimeInterval uptime = [[NSProcessInfo processInfo] systemUptime];
    NSInteger days = (NSInteger)(uptime / 86400);
    NSInteger hours = (NSInteger)((uptime - days * 86400) / 3600);
    NSInteger mins = (NSInteger)((uptime - days * 86400 - hours * 3600) / 60);
    _labelsDict[@"设备运行"].text = [NSString stringWithFormat:@"%ld天 %ld小时 %ld分", (long)days, (long)hours, (long)mins];
}
@end

@implementation SBCPUPassthroughView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hitView = [super hitTest:point withEvent:event];
    if (hitView == self) return nil;
    return hitView;
}
@end

@implementation SBCPURootViewController

- (void)loadView {
    SBCPUPassthroughView *passView = [[SBCPUPassthroughView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    passView.backgroundColor = UIColor.clearColor;
    self.view = passView;
}

- (BOOL)shouldAutorotate { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }
- (BOOL)prefersStatusBarHidden { return YES; }

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        (void)context;
        if (floatingView) updateFloatingSize();
    } completion:nil];
}

@end

@implementation SBCPUWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (settingsShowing || detailShowing || self.rootViewController.presentedViewController) {
        return [super hitTest:point withEvent:event];
    }

    if (floatingView && !floatingView.hidden && floatingView.alpha > 0.01) {
        CGPoint p = [self convertPoint:point toView:floatingView];
        if ([floatingView pointInside:p withEvent:event]) return floatingView;
    }
    return nil;
}
@end

@implementation SBCPUValuePickerController
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { 
    (void)tableView;
    (void)section;
    return 7; 
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { 
    (void)tableView;
    (void)section;
    return @"CPU 触发值"; 
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    NSArray *titles = @[@"80%", @"100%", @"120%", @"140%", @"160%", @"180%", @"200%"];
    NSArray *values = @[@80, @100, @120, @140, @160, @180, @200];

    cell.textLabel.text = titles[indexPath.row];
    if ([values[indexPath.row] doubleValue] == logoutCPUThreshold) {
        cell.accessoryType = UITableViewCellAccessoryCheckmark;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSArray *values = @[@80, @100, @120, @140, @160, @180, @200];
    logoutCPUThreshold = [values[indexPath.row] doubleValue];
    SavePreferencesAndNotify();
    [tableView reloadData];
}
@end

@implementation SBCPUTimePickerController
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { 
    (void)tableView;
    (void)section;
    return 7; 
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { 
    (void)tableView;
    (void)section;
    return @"持续时间"; 
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    NSArray *titles = @[@"10 秒", @"30 秒", @"60 秒", @"120 秒", @"180 秒", @"300 秒", @"600 秒"];
    NSArray *values = @[@10, @30, @60, @120, @180, @300, @600];

    cell.textLabel.text = titles[indexPath.row];
    if ([values[indexPath.row] integerValue] == logoutDuration) {
        cell.accessoryType = UITableViewCellAccessoryCheckmark;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSArray *values = @[@10, @30, @60, @120, @180, @300, @600];
    logoutDuration = [values[indexPath.row] integerValue];
    SavePreferencesAndNotify();
    [tableView reloadData];
}
@end

// ==============================================
// CPUthermal merged-engine preference bridge
// 与 CPUthermal 引擎共享同一份 RootHide/rootless 偏好文件。
// ==============================================
static NSMutableDictionary *sbcputhermalPrefsMutable(void) {
    NSMutableDictionary *d = SBCPUThermalReadMutablePrefs();
    return d ? [d mutableCopy] : [NSMutableDictionary dictionary];
}
static BOOL sbcputhermalGetBoolPref(NSString *key, BOOL def) {
    NSDictionary *d = SBCPUThermalReadPrefs();
    id v = d[key];
    return v ? [v boolValue] : def;
}
static NSString *sbcputhermalGetStringPref(NSString *key, NSString *def) {
    NSDictionary *d = SBCPUThermalReadPrefs();
    id v = d[key];
    return [v isKindOfClass:[NSString class]] ? v : def;
}
static void sbcputhermalSetPref(NSString *key, id value) {
    NSMutableDictionary *d = sbcputhermalPrefsMutable();
    if (value) d[key] = value;
    else [d removeObjectForKey:key];
    SBCPUThermalWritePrefs(d);
    notify_post("com.yourname.sbcpufloating/settingsChanged");
}
static void sbcputhermalSetBoolPref(NSString *key, BOOL value) {
    sbcputhermalSetPref(key, [NSNumber numberWithBool:value]);
}
static void sbcputhermalSetStringPref(NSString *key, NSString *value) {
    sbcputhermalSetPref(key, value);
}

// ==============================================
// 温控核心启动状态
// 开启温度保护后，UI 先显示“核心启动中”，给温控核心约 8 秒完成加载；
// 倒计时结束后直接显示“核心已运行”。这里不再依赖 thermalmonitord 的模块扫描结果，
// 避免 RootHide 环境下跨进程模块路径读取造成误判。
// ==============================================
#define SBCPUThermalStartupGraceSeconds 8.0

static CFTimeInterval sbcputhermalStartupElapsed(void) {
    if (!sbcputhermalGetBoolPref(@"thermalEngineEnabled", YES)) return -1.0;

    NSDictionary *prefs = SBCPUThermalReadPrefs();
    id value = prefs[@"thermalEngineStartupAt"];
    if (![value respondsToSelector:@selector(doubleValue)]) {
        // 第一次启用/升级到此版本时，从现在开始计算启动等待。
        CFTimeInterval now = CFAbsoluteTimeGetCurrent();
        sbcputhermalSetPref(@"thermalEngineStartupAt", @(now));
        return 0.0;
    }

    CFTimeInterval started = [value doubleValue];
    CFTimeInterval elapsed = CFAbsoluteTimeGetCurrent() - started;
    if (elapsed < 0.0) {
        sbcputhermalSetPref(@"thermalEngineStartupAt", @(CFAbsoluteTimeGetCurrent()));
        return 0.0;
    }
    return elapsed;
}

static BOOL sbcputhermalIsStarting(void) {
    CFTimeInterval elapsed = sbcputhermalStartupElapsed();
    return elapsed >= 0.0 && elapsed < SBCPUThermalStartupGraceSeconds;
}

// ==============================================
// 温控状态诊断：只读系统通知状态，不参与温控控制
// ==============================================
static uint64_t sbcputhermalReadNotifyState(const char *name, uint64_t fallback) {
    int token = -1;
    uint64_t state = fallback;
    if (!name) return fallback;
    if (notify_register_check(name, &token) == NOTIFY_STATUS_OK) {
        if (notify_get_state(token, &state) != NOTIFY_STATUS_OK) state = fallback;
        notify_cancel(token);
    }
    return state;
}

static NSString *sbcputhermalPressureChinese(SBCPUThermalPressureLevel pressure) {
    switch (pressure) {
        case SBCPUThermalPressureLevelNominal: return @"正常";
        case SBCPUThermalPressureLevelLight: return @"轻微升温";
        case SBCPUThermalPressureLevelModerate: return @"中度升温";
        case SBCPUThermalPressureLevelHeavy: return @"高温";
        case SBCPUThermalPressureLevelTrapping: return @"严重高温";
        case SBCPUThermalPressureLevelSleeping: return @"极端高温";
        case SBCPUThermalPressureLevelError: return @"读取失败";
        default: return @"正在检测";
    }
}

static void registerThermalHeartbeatListener(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        int token = -1;
        uint32_t result = notify_register_dispatch(SBCPUThermalDiagEngineHeartbeatNotif,
                                                    &token,
                                                    dispatch_get_main_queue(),
                                                    ^(int receivedToken) {
            uint64_t state = 0;
            if (notify_get_state(receivedToken, &state) == NOTIFY_STATUS_OK && state > 0) {
                g_lastThermalHeartbeatMS = state;
            }
        });
        if (result == NOTIFY_STATUS_OK) {
            g_thermalHeartbeatNotifyToken = token;
            uint64_t state = 0;
            if (notify_get_state(token, &state) == NOTIFY_STATUS_OK && state > 0) {
                g_lastThermalHeartbeatMS = state;
            }
        }
    });
}


// ============================================================================
// 温控核心启动状态
// 总开关打开后先显示“核心启动中”，等待约 8 秒后显示“核心已运行”。
// 不再做 thermalmonitord 跨进程 dylib 扫描，避免 RootHide 权限差异和私有
// libproc 接口导致误判或编译问题。温控引擎本身仍由 SBCPUThermal.dylib
// 注入 thermalmonitord 后负责实际温度读取与保护。
// ============================================================================

static void sbcputhermalFloatingStatus(NSString **textOut, UIColor **colorOut) {
    BOOL engineEnabled = sbcputhermalGetBoolPref(@"thermalEngineEnabled", YES);

    if (!engineEnabled) {
        if (textOut) *textOut = @"温控：保护已关闭";
        if (colorOut) *colorOut = [UIColor systemBlueColor];
        return;
    }

    // 用户打开总开关后，先显示启动中，等待温控核心完成初始化。
    // 这样设置页和悬浮窗不会因为 RootHide 的跨进程模块枚举权限而误报“核心未运行”。
    if (sbcputhermalIsStarting()) {
        if (textOut) *textOut = @"温控：核心启动中";
        if (colorOut) *colorOut = [UIColor systemOrangeColor];
        return;
    }

    // 8 秒启动窗口结束后，状态稳定显示为核心已运行。
    // 实际温度压力仍由 SBCPUThermal 核心负责读取和控制，不改变原有保护逻辑。
    uint64_t rawPressure = sbcputhermalReadNotifyState(SBCPUThermalDiagPressureNotif, 999);
    SBCPUThermalPressureLevel pressure = SBCPUThermalPressureLevelUnknown;
    switch (rawPressure) {
        case 0:  pressure = SBCPUThermalPressureLevelNominal; break;
        case 10: pressure = SBCPUThermalPressureLevelLight; break;
        case 20: pressure = SBCPUThermalPressureLevelModerate; break;
        case 30: pressure = SBCPUThermalPressureLevelHeavy; break;
        case 40: pressure = SBCPUThermalPressureLevelTrapping; break;
        case 50: pressure = SBCPUThermalPressureLevelSleeping; break;
        default: pressure = SBCPUThermalPressureLevelUnknown; break;
    }

    BOOL protectionActive = sbcputhermalReadNotifyState(SBCPUThermalDiagProtectionNotif, 0) != 0;
    if (protectionActive || pressure >= SBCPUThermalPressureLevelHeavy) {
        if (textOut) *textOut = protectionActive ? @"温控：高温保护中" : @"温控：高温预警";
        if (colorOut) *colorOut = [UIColor systemRedColor];
    } else if (pressure == SBCPUThermalPressureLevelModerate) {
        if (textOut) *textOut = @"温控：中度升温";
        if (colorOut) *colorOut = [UIColor systemOrangeColor];
    } else if (pressure == SBCPUThermalPressureLevelLight) {
        if (textOut) *textOut = @"温控：轻微升温";
        if (colorOut) *colorOut = [UIColor systemOrangeColor];
    } else {
        if (textOut) *textOut = @"温控：核心已运行";
        if (colorOut) *colorOut = [UIColor systemGreenColor];
    }
}

static NSString *sbcputhermalCurrentStatusDetail(void) {
    BOOL engineEnabled = sbcputhermalGetBoolPref(@"thermalEngineEnabled", YES);
    BOOL pressureProtectionEnabled = sbcputhermalGetBoolPref(@"thermalPressureAutoProtectionEnabled", YES);
    BOOL recoveryEnabled = sbcputhermalGetBoolPref(@"thermalNominalAutoRecoveryEnabled", YES);
    SBCPUThermalPressureLevel pressure = SBCPUThermalGetPressureLevel();
    NSString *pressureText = sbcputhermalPressureChinese(pressure);
    NSString *mode = sbcputhermalGetStringPref(@"powerMode", @"fullPower");
    BOOL lowPowerMode = [mode isEqualToString:@"lowPower"];

    if (!engineEnabled) {
        return [NSString stringWithFormat:@"当前：温控保护已关闭\n开启总开关后，温控核心会开始启动。\n系统温度状态：%@", pressureText];
    }

    if (sbcputhermalIsStarting()) {
        CFTimeInterval elapsed = MAX(0.0, sbcputhermalStartupElapsed());
        NSInteger remaining = (NSInteger)ceil(SBCPUThermalStartupGraceSeconds - elapsed);
        remaining = MAX(1, remaining);
        return [NSString stringWithFormat:@"当前：温控核心启动中\n温控保护已开启，正在等待温控核心完成初始化（约 %ld 秒）。\n系统温度状态：%@", (long)remaining, pressureText];
    }

    uint64_t protection = sbcputhermalReadNotifyState(SBCPUThermalDiagProtectionNotif, 0);
    if (protection) {
        return [NSString stringWithFormat:@"当前：温控核心已运行\n检测到温度压力较高，正在自动降低功耗帮助降温。\n系统温度状态：%@", pressureText];
    }

    if (pressure >= SBCPUThermalPressureLevelHeavy && pressure <= SBCPUThermalPressureLevelSleeping) {
        if (pressureProtectionEnabled) {
            return [NSString stringWithFormat:@"当前：温控核心已运行\n检测到高温，自动保护已准备/正在介入。\n系统温度状态：%@", pressureText];
        }
        return [NSString stringWithFormat:@"当前：温控核心已运行\n当前检测到高温，但自动保护已关闭。\n系统温度状态：%@", pressureText];
    }

    if (lowPowerMode) {
        NSString *recoveryText = recoveryEnabled ? @"温度恢复正常后会自动恢复。" : @"已关闭温度恢复自动切换。";
        return [NSString stringWithFormat:@"当前：温控核心已运行\n当前为省电保护模式。%@\n系统温度状态：%@", recoveryText, pressureText];
    }

    return [NSString stringWithFormat:@"当前：温控核心已运行\n温控保护正在正常工作，目前没有启动高温保护。\n系统温度状态：%@", pressureText];
}

// ==============================================
// 100% 完整保留的设置中心
// ==============================================
@implementation SBCPUSettingsController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"SBCPUFloating V3.3.3";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(closeSettings)];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshThermalStatus];
    [self startThermalStatusTimer];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self stopThermalStatusTimer];
}

- (void)startThermalStatusTimer {
    [self stopThermalStatusTimer];
    __weak typeof(self) weakSelf = self;
    objc_setAssociatedObject(self, @selector(startThermalStatusTimer), [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
        (void)timer;
        __strong typeof(weakSelf) self = weakSelf;
        [self refreshThermalStatus];
    }], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)stopThermalStatusTimer {
    NSTimer *timer = objc_getAssociatedObject(self, @selector(startThermalStatusTimer));
    [timer invalidate];
    objc_setAssociatedObject(self, @selector(startThermalStatusTimer), nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)refreshThermalStatus {
    if (!self.isViewLoaded || !self.view.window) return;

    NSString *detail = sbcputhermalCurrentStatusDetail();
    UITableViewCell *targetCell = nil;

    // 不再依赖固定 section/row，避免以后新增设置项导致状态刷新错位。
    for (UITableViewCell *cell in self.tableView.visibleCells) {
        if ([cell.textLabel.text isEqualToString:@"温度保护当前状态"]) {
            targetCell = cell;
            break;
        }
    }

    if (!targetCell) {
        NSIndexPath *path = [NSIndexPath indexPathForRow:8 inSection:6];
        targetCell = [self.tableView cellForRowAtIndexPath:path];
    }

    if (targetCell) {
        targetCell.detailTextLabel.text = detail;
        targetCell.detailTextLabel.numberOfLines = 0;
        targetCell.detailTextLabel.lineBreakMode = NSLineBreakByWordWrapping;
        [targetCell setNeedsLayout];
    }
}

- (void)closeSettings {
    settingsShowing = NO;
    [self dismissViewControllerAnimated:YES completion:^{
        if (cpuWindow) [cpuWindow setNeedsLayout];
        if (floatingView) [floatingView resetInactivityTimer];
    }];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { 
    (void)tableView;
    return 12;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) return 5; 
    if (section == 1) return 3;
    if (section == 2) return 5;
    if (section == 3) return 7; // 通知管理
    if (section == 4) return 3;
    if (section == 5) return 1;
    if (section == 6) return 10;
    if (section == 7) return 2; 
    if (section == 8) return 7;
    if (section == 9) return 4; // 🔋 智能停充
    if (section == 10) return 5; // 📖 功能说明行数
    if (section == 11) return 8; // 🌡️ 温控功能说明
    return 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) return @"📱 智能缩进与侧边吸附";
    if (section == 1) return @"⚡ 自动控制与防护";
    if (section == 2) return @"🔲 悬浮窗外观";
    if (section == 3) return @"💬 消息与通知管理";
    if (section == 4) return @"🧠 智能选项";
    if (section == 5) return @"🎮 性能与高刷锁定";
    if (section == 6) return @"🌡️ 温度保护"; 
    if (section == 7) return @"🔌 充电增强";
    if (section == 8) return @"📍 位置与显示";
    if (section == 9) return @"🔋 智能停充";
    if (section == 10) return @"📖 功能与使用说明";
    if (section == 11) return @"🌡️ 温度保护功能说明"; 
    return @"";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:(indexPath.section == 6 ? UITableViewCellStyleSubtitle : UITableViewCellStyleValue1) reuseIdentifier:nil];

    if (indexPath.section == 6) {
        cell.textLabel.numberOfLines = 0;
        cell.detailTextLabel.numberOfLines = 0;
        cell.textLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightRegular];
        cell.detailTextLabel.textColor = [UIColor grayColor];
    }

    if (indexPath.section == 9) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"智能停充";
            cell.detailTextLabel.text = @"充到指定电量自动停充，降到下限自动恢复，保护电池";
            UISwitch *sw = [UISwitch new];
            sw.on = smartChargeEnable;
            [sw addTarget:self action:@selector(changeSmartChargeEnable:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"预设模式";
            NSArray *titles = @[@"日常保护 80%", @"满电出行 100%", @"深度保养 60%"];
            CGFloat btnW = (cell.contentView.bounds.size.width > 320) ? (cell.contentView.bounds.size.width - 40) / 3.0 : 90;
            for (int i = 0; i < 3; i++) {
                UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
                btn.frame = CGRectMake(15 + i * (btnW + 5), 44, btnW, 28);
                [btn setTitle:titles[i] forState:UIControlStateNormal];
                btn.titleLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
                btn.titleLabel.adjustsFontSizeToFitWidth = YES;
                btn.titleLabel.minimumScaleFactor = 0.7;
                btn.layer.cornerRadius = 8;
                btn.layer.borderWidth = 1;
                if (smartChargeMode == i) {
                    btn.backgroundColor = [UIColor systemBlueColor];
                    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
                    btn.layer.borderColor = [UIColor systemBlueColor].CGColor;
                } else {
                    btn.backgroundColor = [UIColor clearColor];
                    [btn setTitleColor:[UIColor systemBlueColor] forState:UIControlStateNormal];
                    btn.layer.borderColor = [UIColor systemBlueColor].CGColor;
                }
                btn.tag = i;
                [btn addTarget:self action:@selector(changeSmartChargeMode:) forControlEvents:UIControlEventTouchUpInside];
                [cell.contentView addSubview:btn];
            }
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (indexPath.row == 2) {
            cell.textLabel.text = [NSString stringWithFormat:@"停充上限: %ld%%", (long)smartChargeUpperLimit];
            UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(15, 44, cell.contentView.bounds.size.width - 30, 30)];
            slider.minimumValue = 50;
            slider.maximumValue = 100;
            slider.value = smartChargeUpperLimit;
            slider.continuous = NO;
            [slider addTarget:self action:@selector(changeSmartChargeUpper:) forControlEvents:UIControlEventValueChanged];
            [cell.contentView addSubview:slider];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (indexPath.row == 3) {
            cell.textLabel.text = [NSString stringWithFormat:@"回充下限: %ld%%", (long)smartChargeLowerLimit];
            UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(15, 44, cell.contentView.bounds.size.width - 30, 30)];
            slider.minimumValue = 40;
            slider.maximumValue = 90;
            slider.value = smartChargeLowerLimit;
            slider.continuous = NO;
            [slider addTarget:self action:@selector(changeSmartChargeLower:) forControlEvents:UIControlEventValueChanged];
            [cell.contentView addSubview:slider];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
    }

    if (indexPath.section == 10) {
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        cell.textLabel.textColor = [UIColor darkGrayColor];
        cell.textLabel.numberOfLines = 0;
        if (indexPath.row == 0) cell.textLabel.text = @"👆 单击悬浮窗：展开双层 UI / 0延迟直达聊天";
        else if (indexPath.row == 1) cell.textLabel.text = @"✌️ 双击悬浮窗：打开此高级设置中心";
        else if (indexPath.row == 2) cell.textLabel.text = @"👆 长按悬浮窗：全屏展示设备深层物理状态";
        else if (indexPath.row == 3) cell.textLabel.text = @"🤚 拖动悬浮窗：自由挪动位置并带物理回弹";
        else if (indexPath.row == 4) cell.textLabel.text = @"🔋 充电增强：实时功率监测与高电量充电目标";
        return cell;
    }

    // 🌡️ 温控功能说明：独立放在温控设置下面，避免右侧开关挤压说明文字
    if (indexPath.section == 11) {
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
        cell.textLabel.textColor = [UIColor darkTextColor];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightRegular];
        cell.detailTextLabel.textColor = [UIColor grayColor];
        cell.detailTextLabel.numberOfLines = 0;
        cell.textLabel.numberOfLines = 0;

        NSArray *titles = @[
            @"过热自动保护",
            @"锁屏省电保护",
            @"温度正常后自动恢复",
            @"启动后等待 8 秒",
            @"防止温控导致暗屏",
            @"不弹出高温警告",
            @"当前状态怎么看",
            @"运行方式"
        ];
        NSArray *descs = @[
            @"设备温度压力太高时，自动降低功耗，帮助设备减轻发热。",
            @"熄屏后自动省电，亮屏后恢复，不影响正常使用。",
            @"温度恢复正常并稳定约 5 秒后，自动恢复之前的运行状态。",
            @"插件刚启动时先等约 8 秒，让系统温度监测稳定下来，避免误操作。",
            @"尽量避免系统因为温度过高而突然降低屏幕亮度。",
            @"只是不显示高温警告弹窗，温度检测和保护仍然继续。",
            @"“正常”表示正在监测但没有启动保护；“保护中”表示温度压力较高，正在主动降低功耗；“正在启动”表示还在等待 8 秒。",
            @"“正常性能”优先保持性能；“省电保护”会主动限制功耗。遇到高温时，自动保护仍可临时接管。"
        ];
        cell.textLabel.text = titles[indexPath.row];
        cell.detailTextLabel.text = descs[indexPath.row];
        return cell;
    }

    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"无操作自动收起";
            UISwitch *sw = [UISwitch new];
            sw.on = autoCollapseEnable;
            [sw addTarget:self action:@selector(changeAutoCollapse:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"收起延迟时间";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld 秒", (long)autoCollapseDelay];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (indexPath.row == 2) {
            cell.textLabel.text = @"折叠显示内容";
            NSArray *modes = @[@"CPU 使用率", @"FPS 帧率", @"电池温度", @"电池电流", @"电池电量"];
            cell.detailTextLabel.text = (collapsedDisplayMode >= 0 && collapsedDisplayMode < modes.count) ? modes[collapsedDisplayMode] : modes[0];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (indexPath.row == 3) {
            cell.textLabel.text = @"横屏游戏自动展开";
            UISwitch *sw = [UISwitch new];
            sw.on = autoExpandLandscape;
            [sw addTarget:self action:@selector(changeAutoExpandLandscape:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (indexPath.row == 4) {
            cell.textLabel.text = @"横屏模式";
            cell.detailTextLabel.text = @"修正横屏锁定时浮窗仍竖着的问题";
            UISwitch *sw = [UISwitch new];
            sw.on = landscapeModeEnable;
            [sw addTarget:self action:@selector(changeLandscapeMode:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        }
    } else if (indexPath.section == 1) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"自动注销";
            UISwitch *sw = [UISwitch new];
            sw.on = autoLogoutEnable;
            [sw addTarget:self action:@selector(changeLogout:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"CPU 触发值";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%.0f%%", logoutCPUThreshold];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (indexPath.row == 2) {
            cell.textLabel.text = @"持续时间";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld 秒", (long)logoutDuration];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    } else if (indexPath.section == 2) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"透明度开关";
            UISwitch *sw = [UISwitch new];
            sw.on = floatingAlphaEnable;
            [sw addTarget:self action:@selector(changeAlphaEnable:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"透明度";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%.0f%%", floatingAlpha * 100.0];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (indexPath.row == 2) {
            cell.textLabel.text = @"浮窗大小";
            UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(0,0,130,30)];
            slider.minimumValue = 0.4; slider.maximumValue = 1.6; slider.value = floatingScale;
            [slider addTarget:self action:@selector(changeScaleSlider:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = slider;
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%.0f%%", floatingScale * 100];
        } else if (indexPath.row == 3) {
            cell.textLabel.text = @"字体大小";
            UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(0,0,130,30)];
            slider.minimumValue = 8.0; slider.maximumValue = 15.0; slider.value = floatingFontSize;
            [slider addTarget:self action:@selector(changeFontSlider:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = slider;
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%.0fpt", floatingFontSize];
        } else if (indexPath.row == 4) {
            cell.textLabel.text = @"圆角大小";
            UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(0,0,130,30)];
            slider.minimumValue = 4.0; slider.maximumValue = 35.0; slider.value = floatingCornerRadius;
            [slider addTarget:self action:@selector(changeCornerRadiusSlider:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = slider;
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%.0f", floatingCornerRadius];
        }
    } else if (indexPath.section == 3) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"启用通知管理";
            UISwitch *sw = [UISwitch new];
            sw.on = notificationEnable;
            [sw addTarget:self action:@selector(changeNotificationEnable:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"微信通知";
            UISwitch *sw = [UISwitch new];
            sw.on = wechatEnable;
            [sw addTarget:self action:@selector(changeWechatEnable:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (indexPath.row == 2) {
            cell.textLabel.text = @"QQ通知";
            UISwitch *sw = [UISwitch new];
            sw.on = qqEnable;
            [sw addTarget:self action:@selector(changeQqEnable:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (indexPath.row == 3) {
            cell.textLabel.text = @"TIM通知";
            UISwitch *sw = [UISwitch new];
            sw.on = timEnable;
            [sw addTarget:self action:@selector(changeTimEnable:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (indexPath.row == 4) {
            cell.textLabel.text = @"横屏状态消息通知";
            cell.detailTextLabel.text = @"关闭后横屏不弹出消息悬浮通知";
            UISwitch *sw = [UISwitch new];
            sw.on = landscapeNotificationEnable;
            [sw addTarget:self action:@selector(changeLandscapeNotificationEnable:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (indexPath.row == 5) {
            cell.textLabel.text = @"锁屏隐私隐藏";
            UISwitch *sw = [UISwitch new];
            sw.on = hideContentOnLockScreen;
            [sw addTarget:self action:@selector(changeHideContentLockScreen:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (indexPath.row == 6) {
            cell.textLabel.text = @"通知显示时间";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld 秒", (long)notificationDuration];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    } else if (indexPath.section == 4) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"键盘避让";
            UISwitch *sw = [UISwitch new];
            sw.on = keyboardAvoidEnable;
            [sw addTarget:self action:@selector(changeKeyboardAvoid:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"智能吸附";
            UISwitch *sw = [UISwitch new];
            sw.on = smartDockEnable;
            [sw addTarget:self action:@selector(changeSmartDock:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (indexPath.row == 2) {
            cell.textLabel.text = @"吸附模式";
            NSArray *modes = @[@"自动", @"左侧", @"右侧", @"顶部", @"底部"];
            cell.detailTextLabel.text = (dockMode >= 0 && dockMode < modes.count) ? modes[dockMode] : @"自动";
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    } else if (indexPath.section == 5) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"强制 120Hz 高刷模式";
            UISwitch *sw = [UISwitch new];
            sw.on = force120HzEnable;
            [sw addTarget:self action:@selector(changeForce120Hz:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        }
    } else if (indexPath.section == 6) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"温度保护总开关";
            cell.detailTextLabel.text = @"开启后，插件会根据系统温度压力自动保护设备。";
            UISwitch *sw = [UISwitch new];
            sw.on = sbcputhermalGetBoolPref(@"thermalEngineEnabled", YES);
            [sw addTarget:self action:@selector(changeThermalEngine:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"运行方式";
            NSString *mode = sbcputhermalGetStringPref(@"powerMode", @"fullPower");
            cell.detailTextLabel.text = [mode isEqualToString:@"lowPower"] ? @"省电保护" : @"正常性能";
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (indexPath.row == 2) {
            cell.textLabel.text = @"过热自动保护";
            cell.detailTextLabel.text = @"温度压力达到较高等级时，自动降低功耗帮助降温。";
            UISwitch *sw = [UISwitch new];
            sw.on = sbcputhermalGetBoolPref(@"thermalPressureAutoProtectionEnabled", YES);
            [sw addTarget:self action:@selector(changeThermalPressureProtection:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (indexPath.row == 3) {
            cell.textLabel.text = @"锁屏省电保护";
            cell.detailTextLabel.text = @"熄屏后降低功耗，亮屏后自动恢复。";
            UISwitch *sw = [UISwitch new];
            sw.on = sbcputhermalGetBoolPref(@"thermalLockScreenLowPowerEnabled", YES);
            [sw addTarget:self action:@selector(changeThermalLockScreenLowPower:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (indexPath.row == 4) {
            cell.textLabel.text = @"温度正常后自动恢复";
            cell.detailTextLabel.text = @"温度恢复正常并保持约 5 秒后，自动恢复正常性能。";
            UISwitch *sw = [UISwitch new];
            sw.on = sbcputhermalGetBoolPref(@"thermalNominalAutoRecoveryEnabled", YES);
            [sw addTarget:self action:@selector(changeThermalNominalRecovery:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (indexPath.row == 5) {
            cell.textLabel.text = @"启动保护等待";
            cell.detailTextLabel.text = @"每次插件启动后先等待约 8 秒，再开始温度保护，避免刚启动时误判。";
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (indexPath.row == 6) {
            cell.textLabel.text = @"防止温控导致暗屏";
            cell.detailTextLabel.text = @"尽量避免系统因为温度保护突然把屏幕亮度压低。";
            UISwitch *sw = [UISwitch new];
            sw.on = sbcputhermalGetBoolPref(@"thermalPreventDimmingEnabled", NO);
            [sw addTarget:self action:@selector(changeThermalDimming:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (indexPath.row == 7) {
            cell.textLabel.text = @"不弹出高温警告";
            cell.detailTextLabel.text = @"只隐藏高温警告弹窗，不关闭温度检测和保护。";
            UISwitch *sw = [UISwitch new];
            sw.on = sbcputhermalGetBoolPref(@"thermalBlockNotifPopup", NO);
            [sw addTarget:self action:@selector(changeThermalPopup:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (indexPath.row == 8) {
            cell.textLabel.text = @"温度保护当前状态";
            cell.detailTextLabel.text = sbcputhermalCurrentStatusDetail();
            cell.detailTextLabel.numberOfLines = 0;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (indexPath.row == 9) {
            cell.textLabel.text = @"温控核心版本";
            cell.detailTextLabel.text = @"CPUthermal 1.6.4-53\n负责读取系统温度压力并执行保护。";
            cell.detailTextLabel.numberOfLines = 2;
            cell.detailTextLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightRegular];
            cell.detailTextLabel.adjustsFontSizeToFitWidth = NO;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
    } else if (indexPath.section == 7) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"充电增强（实时验证）";
            UISwitch *sw = [UISwitch new];
            sw.on = chargeBoostEnable;
            [sw addTarget:self action:@selector(changeChargeBoost:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"🔥 强制满血快充";
            cell.detailTextLabel.text = @"保留原有快充控制";
            UISwitch *sw = [UISwitch new];
            sw.on = forceFastChargeEnable;
            [sw addTarget:self action:@selector(changeForceFastCharge:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        }
    } else if (indexPath.section == 8) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"记忆悬浮窗位置";
            UISwitch *sw = [UISwitch new];
            sw.on = rememberPositionEnable;
            [sw addTarget:self action:@selector(changeRememberPosition:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"显示 CPU 频率";
            UISwitch *sw = [UISwitch new];
            sw.on = showCpuFrequency;
            [sw addTarget:self action:@selector(changeShowCpuFreq:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (indexPath.row == 2) {
            cell.textLabel.text = @"显示 FPS 帧率";
            UISwitch *sw = [UISwitch new];
            sw.on = showFps;
            [sw addTarget:self action:@selector(changeShowFps:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (indexPath.row == 3) {
            cell.textLabel.text = @"显示电池百分比";
            UISwitch *sw = [UISwitch new];
            sw.on = showBatteryPercent;
            [sw addTarget:self action:@selector(changeShowBattery:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (indexPath.row == 4) {
            cell.textLabel.text = @"显示电池温度";
            UISwitch *sw = [UISwitch new];
            sw.on = showBatteryTemperature;
            [sw addTarget:self action:@selector(changeShowTemp:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (indexPath.row == 5) {
            cell.textLabel.text = @"显示实时电流";
            UISwitch *sw = [UISwitch new];
            sw.on = showBatteryCurrent;
            [sw addTarget:self action:@selector(changeShowCurrent:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (indexPath.row == 6) {
            cell.textLabel.text = @"液态玻璃效果";
            cell.detailTextLabel.text = @"开启后浮窗呈 iOS 26 液态玻璃风格（透明+高光+文字反色）";
            UISwitch *sw = [UISwitch new];
            sw.on = liquidGlassEnabled;
            [sw addTarget:self action:@selector(changeLiquidGlass:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        }
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == 0) {
        if (indexPath.row == 1) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"无操作收起延迟" message:@"选择多长时间无操作后自动折叠" preferredStyle:UIAlertControllerStyleActionSheet];
            NSArray *titles = @[@"2 秒", @"3 秒", @"4 秒", @"5 秒", @"8 秒", @"10 秒"];
            NSArray *values = @[@2, @3, @4, @5, @8, @10];
            for (NSInteger i = 0; i < titles.count; i++) {
                [alert addAction:[UIAlertAction actionWithTitle:titles[i] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                    autoCollapseDelay = [values[i] integerValue];
                    SavePreferencesAndNotify();
                    [self.tableView reloadData];
                }]];
            }
            [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        } else if (indexPath.row == 2) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"折叠显示内容" message:@"选择悬浮窗隐藏后显示的信息" preferredStyle:UIAlertControllerStyleActionSheet];
            NSArray *titles = @[@"CPU 使用率", @"FPS 帧率", @"电池温度", @"电池电流", @"电池电量"];
            for (NSInteger i = 0; i < titles.count; i++) {
                [alert addAction:[UIAlertAction actionWithTitle:titles[i] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                    collapsedDisplayMode = i;
                    SavePreferencesAndNotify();
                    [self.tableView reloadData];
                }]];
            }
            [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        }
    } else if (indexPath.section == 1) {
        if (indexPath.row == 1) {
            SBCPUValuePickerController *vc = [[SBCPUValuePickerController alloc] initWithStyle:UITableViewStyleInsetGrouped];
            [self.navigationController pushViewController:vc animated:YES];
        } else if (indexPath.row == 2) {
            SBCPUTimePickerController *vc = [[SBCPUTimePickerController alloc] initWithStyle:UITableViewStyleInsetGrouped];
            [self.navigationController pushViewController:vc animated:YES];
        }
    } else if (indexPath.section == 2) {
        if (indexPath.row == 1) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"透明度" message:@"选择悬浮窗透明度" preferredStyle:UIAlertControllerStyleActionSheet];
            NSArray *titles = @[@"20%", @"40%", @"60%", @"70%", @"85%", @"100%"];
            NSArray *values = @[@0.2, @0.4, @0.6, @0.7, @0.85, @1.0];
            for (NSInteger i = 0; i < titles.count; i++) {
                [alert addAction:[UIAlertAction actionWithTitle:titles[i] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                    floatingAlpha = [values[i] floatValue];
                    SavePreferencesAndNotify();
                    applyFloatingAlpha();
                    [self.tableView reloadData];
                }]];
            }
            [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        }
    } else if (indexPath.section == 3) {
        if (indexPath.row == 6) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"通知显示时间" message:@"选择消息浮窗保留多长时间" preferredStyle:UIAlertControllerStyleActionSheet];
            NSArray *titles = @[@"3 秒", @"5 秒", @"8 秒", @"10 秒"];
            NSArray *values = @[@3, @5, @8, @10];
            for (NSInteger i = 0; i < titles.count; i++) {
                [alert addAction:[UIAlertAction actionWithTitle:titles[i] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                    notificationDuration = [values[i] integerValue];
                    SavePreferencesAndNotify();
                    [self.tableView reloadData];
                }]];
            }
            [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        }
    } else if (indexPath.section == 4) {
        if (indexPath.row == 2) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"吸附模式" message:@"选择悬浮窗贴边时的吸附位置" preferredStyle:UIAlertControllerStyleActionSheet];
            NSArray *modes = @[@"自动", @"左侧", @"右侧", @"顶部", @"底部"];
            for (NSInteger i = 0; i < modes.count; i++) {
                [alert addAction:[UIAlertAction actionWithTitle:modes[i] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                    dockMode = i;
                    SavePreferencesAndNotify();
                    [self.tableView reloadData];
                }]];
            }
            [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        }
    } else if (indexPath.section == 6) {
        if (indexPath.row == 1) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"温控模式"
                                                                             message:@"选择 CPUthermal 1.6.4-53 温控核心的运行模式"
                                                                      preferredStyle:UIAlertControllerStyleActionSheet];
            NSArray *titles = @[@"低功耗", @"解除温控"];
            NSArray *values = @[@"lowPower", @"fullPower"];
            for (NSInteger i = 0; i < titles.count; i++) {
                [alert addAction:[UIAlertAction actionWithTitle:titles[i] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                    sbcputhermalSetStringPref(@"powerMode", values[i]);
                    [self.tableView reloadData];
                }]];
            }
            [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        }
    }
}

- (void)saveConfigs { SavePreferencesAndNotify(); }

// ==========================================
// 🚀 核心修复区：滑块拖动事件，实时寻找 Cell 并更新数值，带防抖保护
// ==========================================
- (UITableViewCell *)_cellForView:(UIView *)view {
    UIView *v = view.superview;
    while (v != nil) {
        if ([v isKindOfClass:[UITableViewCell class]]) return (UITableViewCell *)v;
        v = v.superview;
    }
    return nil;
}

- (void)changeScaleSlider:(UISlider *)s { 
    floatingScale = s.value; 
    UITableViewCell *cell = [self _cellForView:s];
    if (cell) cell.detailTextLabel.text = [NSString stringWithFormat:@"%.0f%%", floatingScale * 100];
    
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(saveConfigs) object:nil];
    [self performSelector:@selector(saveConfigs) withObject:nil afterDelay:0.5];
}

- (void)changeFontSlider:(UISlider *)s { 
    floatingFontSize = s.value;
    UITableViewCell *cell = [self _cellForView:s];
    if (cell) cell.detailTextLabel.text = [NSString stringWithFormat:@"%.0fpt", floatingFontSize];

    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(saveConfigs) object:nil];
    [self performSelector:@selector(saveConfigs) withObject:nil afterDelay:0.5];
}

- (void)changeCornerRadiusSlider:(UISlider *)s { 
    floatingCornerRadius = s.value;
    UITableViewCell *cell = [self _cellForView:s];
    if (cell) cell.detailTextLabel.text = [NSString stringWithFormat:@"%.0f", floatingCornerRadius];

    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(saveConfigs) object:nil];
    [self performSelector:@selector(saveConfigs) withObject:nil afterDelay:0.5];
}
// ==========================================

// UI Switch Actions
- (void)changeAutoCollapse:(UISwitch *)sw { autoCollapseEnable = sw.isOn; SavePreferencesAndNotify(); }
- (void)changeAutoExpandLandscape:(UISwitch *)sw { autoExpandLandscape = sw.isOn; SavePreferencesAndNotify(); updateFloatingSize(); }
- (void)changeLandscapeMode:(UISwitch *)sw { landscapeModeEnable = sw.isOn; SavePreferencesAndNotify(); updateFloatingSize(); }
- (void)changeLogout:(UISwitch *)sw { autoLogoutEnable = sw.isOn; SavePreferencesAndNotify(); }
- (void)changeAlphaEnable:(UISwitch *)sw { floatingAlphaEnable = sw.isOn; SavePreferencesAndNotify(); applyFloatingAlpha(); }
- (void)changeKeyboardAvoid:(UISwitch *)sw { keyboardAvoidEnable = sw.isOn; SavePreferencesAndNotify(); }
- (void)changeSmartDock:(UISwitch *)sw { smartDockEnable = sw.isOn; SavePreferencesAndNotify(); }
- (void)changeRememberPosition:(UISwitch *)sw { rememberPositionEnable = sw.isOn; SavePreferencesAndNotify(); }
- (void)changeForce120Hz:(UISwitch *)sw { force120HzEnable = sw.isOn; SavePreferencesAndNotify(); }
- (void)changeShowCpuFreq:(UISwitch *)sw { showCpuFrequency = sw.isOn; SavePreferencesAndNotify(); updateFloatingSize(); }
- (void)changeShowFps:(UISwitch *)sw { showFps = sw.isOn; SavePreferencesAndNotify(); updateFloatingSize(); }
- (void)changeShowBattery:(UISwitch *)sw { showBatteryPercent = sw.isOn; SavePreferencesAndNotify(); updateFloatingSize(); }
- (void)changeShowTemp:(UISwitch *)sw { showBatteryTemperature = sw.isOn; SavePreferencesAndNotify(); updateFloatingSize(); }
- (void)changeShowCurrent:(UISwitch *)sw { showBatteryCurrent = sw.isOn; SavePreferencesAndNotify(); updateFloatingSize(); }
- (void)changeLiquidGlass:(UISwitch *)sw {
    liquidGlassEnabled = sw.isOn;
    SavePreferencesAndNotify();
    if (floatingView) {
        [floatingView applyLiquidGlassStyle];
        [floatingView applyAdaptiveTextColors];
    }
}

// 智能停充：开关
- (void)changeSmartChargeEnable:(UISwitch *)sw {
    smartChargeEnable = sw.isOn;
    SavePreferencesAndNotify();
    if (!smartChargeEnable) {
        smartChargeStopped = NO;
    }
    [self.tableView reloadData];
}

// 智能停充：预设模式
- (void)changeSmartChargeMode:(UIButton *)btn {
    smartChargeMode = btn.tag;
    if (smartChargeMode == 0) { smartChargeUpperLimit = 80; smartChargeLowerLimit = 70; }
    else if (smartChargeMode == 1) { smartChargeUpperLimit = 100; smartChargeLowerLimit = 90; }
    else if (smartChargeMode == 2) { smartChargeUpperLimit = 60; smartChargeLowerLimit = 50; }
    SavePreferencesAndNotify();
    smartChargeStopped = NO;
    [self.tableView reloadData];
}

// 智能停充：停充上限
- (void)changeSmartChargeUpper:(UISlider *)slider {
    smartChargeUpperLimit = (NSInteger)slider.value;
    if (smartChargeUpperLimit <= smartChargeLowerLimit) {
        smartChargeLowerLimit = MAX(40, smartChargeUpperLimit - 5);
    }
    SavePreferencesAndNotify();
    smartChargeStopped = NO;
    [self.tableView reloadData];
}

// 智能停充：回充下限
- (void)changeSmartChargeLower:(UISlider *)slider {
    smartChargeLowerLimit = (NSInteger)slider.value;
    if (smartChargeLowerLimit >= smartChargeUpperLimit) {
        smartChargeUpperLimit = MIN(100, smartChargeLowerLimit + 5);
    }
    SavePreferencesAndNotify();
    [self.tableView reloadData];
}
- (void)changeChargeBoost:(UISwitch *)sw {
    chargeBoostEnable = sw.isOn;
    chargeBoostStartTime = sw.isOn ? CFAbsoluteTimeGetCurrent() : 0;
    lastChargeWatts = 0;
    previousChargeWatts = 0;
    chargeBoostBaselineWatts = 0;
    chargeBoostVerified = NO;
    applyExperimentalChargeLimit100(chargeBoostEnable);
    SavePreferencesAndNotify();
}

- (void)changeForceFastCharge:(UISwitch *)sw {
    if (sw.isOn) {
        sw.on = NO;
        forceFastChargeEnable = NO;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"⚠️ 极度危险警告"
                                                                         message:@"强制快充会绕过部分原厂充电限制，充电时可能明显升温。仅建议在充分散热条件下使用。"
                                                                  preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
            (void)action;
            sw.on = NO;
            forceFastChargeEnable = NO;
            SavePreferencesAndNotify();
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"我知晓风险并开启" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            (void)action;
            forceFastChargeEnable = YES;
            sw.on = YES;
            SavePreferencesAndNotify();
            // 用户在已经插着充电器时开启超级快充，立即启动一次流程。
            if (isChargingInternal()) {
                startFastChargeStartupAnimation();
            }
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    } else {
        // 关闭时先同步全局状态，再保存，避免旧状态被重新写回 YES。
        forceFastChargeEnable = NO;
        sw.on = NO;
        SavePreferencesAndNotify();
    }
}

- (void)changeThermalEngine:(UISwitch *)sw {
    if (sw.isOn) {
        // 每次用户重新打开总开关，都重新进入约 8 秒“核心启动中”状态。
        sbcputhermalSetPref(@"thermalEngineStartupAt", @(CFAbsoluteTimeGetCurrent()));
        sbcputhermalSetBoolPref(@"thermalEngineEnabled", YES);
    } else {
        sbcputhermalSetBoolPref(@"thermalEngineEnabled", NO);
        sbcputhermalSetPref(@"thermalEngineStartupAt", nil);
    }
    [self refreshThermalStatus];
}
- (void)changeThermalPressureProtection:(UISwitch *)sw {
    sbcputhermalSetBoolPref(@"thermalPressureAutoProtectionEnabled", sw.isOn);
}
- (void)changeThermalLockScreenLowPower:(UISwitch *)sw {
    sbcputhermalSetBoolPref(@"thermalLockScreenLowPowerEnabled", sw.isOn);
}
- (void)changeThermalNominalRecovery:(UISwitch *)sw {
    sbcputhermalSetBoolPref(@"thermalNominalAutoRecoveryEnabled", sw.isOn);
}
- (void)changeThermalDimming:(UISwitch *)sw {
    sbcputhermalSetBoolPref(@"thermalPreventDimmingEnabled", sw.isOn);
}
- (void)changeThermalPopup:(UISwitch *)sw {
    sbcputhermalSetBoolPref(@"thermalBlockNotifPopup", sw.isOn);
}
- (void)changeNotificationEnable:(UISwitch *)sw { notificationEnable = sw.isOn; SavePreferencesAndNotify(); }
- (void)changeLandscapeNotificationEnable:(UISwitch *)sw { landscapeNotificationEnable = sw.isOn; SavePreferencesAndNotify(); }
- (void)changeWechatEnable:(UISwitch *)sw { wechatEnable = sw.isOn; SavePreferencesAndNotify(); }
- (void)changeQqEnable:(UISwitch *)sw { qqEnable = sw.isOn; SavePreferencesAndNotify(); }
- (void)changeTimEnable:(UISwitch *)sw { timEnable = sw.isOn; SavePreferencesAndNotify(); }
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    if (indexPath.section == 6) {
        if (indexPath.row == 8) return 150.0;
        return (indexPath.row == 9) ? 72.0 : 64.0;
    }
    if (indexPath.section == 9) {
        // 智能停充：预设按钮行和滑块行需要更高的高度
        if (indexPath.row == 1) return 82.0;  // 预设按钮
        if (indexPath.row == 2 || indexPath.row == 3) return 82.0; // 滑块
        return 64.0;
    }
    if (indexPath.section == 11) {
        return 82.0;
    }
    return UITableViewAutomaticDimension;
}

- (void)changeHideContentLockScreen:(UISwitch *)sw { hideContentOnLockScreen = sw.isOn; SavePreferencesAndNotify(); }

@end

#pragma mark - 8. 进程通知与 SpringBoard 状态初始化

static void onCCNotificationReceived(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    LoadPreferences();
}

static void registerV160Observers(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserverForName:UIDeviceOrientationDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            if (cpuWindow && floatingView) updateFloatingSize();
        }];
        [nc addObserverForName:UIKeyboardWillShowNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            if (settingsShowing || detailShowing || !keyboardAvoidEnable) return;
            if (cpuWindow && floatingView) {
                UIWindowScene *scene = getWindowScene();
                CGRect screenBounds = scene ? scene.coordinateSpace.bounds : UIScreen.mainScreen.bounds;
                if (CGRectGetMidY(floatingView.frame) < CGRectGetMidY(screenBounds)) return;
                if (!keyboardMoved) keyboardBeforeFrame = floatingView.frame;
                NSDictionary *info = n.userInfo;
                NSValue *endFrameValue = info[UIKeyboardFrameEndUserInfoKey];
                CGFloat keyboardHeight = MIN(320.0, endFrameValue ? [endFrameValue CGRectValue].size.height : 220.0);
                CGRect f = keyboardBeforeFrame; f.origin.y = MAX(20.0, f.origin.y - keyboardHeight);
                [UIView animateWithDuration:0.25 animations:^{ floatingView.frame = f; }]; keyboardMoved = YES;
            }
        }];
        [nc addObserverForName:UIKeyboardWillHideNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            if (!settingsShowing && !detailShowing && keyboardMoved && floatingView) {
                [UIView animateWithDuration:0.25 animations:^{ floatingView.frame = keyboardBeforeFrame; }]; keyboardMoved = NO;
            }
        }];
    });
}

// 🚀 终极通知拦截阵列
%hook NCNotificationDispatcher
- (void)postNotificationWithRequest:(id)arg1 { %orig; [[SBNotificationManager sharedInstance] extractAndHandleRequest:arg1]; }
- (void)receiveNotificationRequest:(id)arg1 { %orig; [[SBNotificationManager sharedInstance] extractAndHandleRequest:arg1]; }
- (void)addNotificationRequest:(id)arg1 { %orig; [[SBNotificationManager sharedInstance] extractAndHandleRequest:arg1]; }
- (void)insertNotificationRequest:(id)arg1 { %orig; [[SBNotificationManager sharedInstance] extractAndHandleRequest:arg1]; }
%end
%hook SBNCNotificationDispatcher
- (void)postNotificationWithRequest:(id)arg1 { %orig; [[SBNotificationManager sharedInstance] extractAndHandleRequest:arg1]; }
- (void)receiveNotificationRequest:(id)arg1 { %orig; [[SBNotificationManager sharedInstance] extractAndHandleRequest:arg1]; }
- (void)addNotificationRequest:(id)arg1 { %orig; [[SBNotificationManager sharedInstance] extractAndHandleRequest:arg1]; }
%end

#pragma mark - 10. 构造函数入口

%ctor {
    %init;
    NSString *processName = [NSProcessInfo processInfo].processName;
    if ([processName isEqualToString:@"SpringBoard"]) {
        LoadPreferences();
        registerThermalHeartbeatListener();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, onCCNotificationReceived, kPrefChangedNotification, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            createCPUWindow();
            registerV160Observers();
            [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) { updateCPU(); }];
        });
    }
}

