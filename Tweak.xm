
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <mach/mach.h>
#import <mach/mach_time.h>
#import <mach/host_info.h>
#import <mach/processor_info.h>
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
@property (nonatomic, strong) UIView *collapsedContainerView;
@property (nonatomic, strong) UIView *statusDot;
@property (nonatomic, strong) UILabel *miniCpuLabel;

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
static CGFloat floatingCornerRadius = 16.0f; 

static BOOL settingsShowing = NO;
static BOOL detailShowing = NO;
static BOOL previousChargingState = NO;

static BOOL autoCollapseEnable = YES;
static NSInteger autoCollapseDelay = 4;
static NSInteger collapsedDisplayMode = 0; 
static BOOL autoExpandLandscape = YES;
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
static void clampAndPositionFloatingView(CGPoint targetCenter, BOOL animate);
static void updateFloatingSize(void);
static void createCPUWindow(void);
static void openDetailView(void);
static void openSettings(void);
static void checkHighCPU(double cpu);
static void updateCPU(void);

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

static void clampAndPositionFloatingView(CGPoint targetCenter, BOOL animate) {
    if (!floatingView || !floatingView.superview) return;

    CGRect containerBounds = floatingView.superview.bounds;
    if (CGRectIsEmpty(containerBounds)) containerBounds = [UIScreen mainScreen].bounds;

    CGRect realFrame = floatingView.frame;
    CGFloat halfW = realFrame.size.width / 2.0f;
    CGFloat halfH = realFrame.size.height / 2.0f;

    CGFloat minX = halfW + 4.0f;
    CGFloat maxX = containerBounds.size.width - halfW - 4.0f;
    CGFloat minY = halfH + 20.0f;
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
        CGFloat colMinY = targetHalfH + 20.0f;
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
    UIInterfaceOrientation orientation = getActiveInterfaceOrientation();

    floatingView.transform = CGAffineTransformIdentity;

    [floatingView updateLayoutWithShowCpuFreq:showCpuFrequency
                                       showFps:showFps
                            showBatteryPercent:showBatteryPercent
                               showBatteryTemp:showBatteryTemperature
                            showBatteryCurrent:showBatteryCurrent
                                    isCharging:charging];

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
            if (root.presentedViewController) return;

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
        }
        previousChargingState = charging;

        if (autoExpandLandscape) {
            UIInterfaceOrientation orientation = getActiveInterfaceOrientation();
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


@implementation SBCPUFloatingView

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
        self.layer.shadowOpacity = 0.18f;
        self.layer.shadowOffset = CGSizeMake(0, 4);
        self.layer.shadowRadius = 12.0f;

        UIBlurEffect *blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialLight];
        _blurView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
        CGFloat cornerRad = floatingCornerRadius;
        _blurView.layer.cornerRadius = cornerRad;
        _blurView.layer.masksToBounds = YES;
        _blurView.layer.borderWidth = 0.5f;
        _blurView.layer.borderColor = [UIColor colorWithWhite:1.0f alpha:0.60f].CGColor;
        _blurView.userInteractionEnabled = NO;
        [self addSubview:_blurView];

        _marqueeLayer = [CAShapeLayer layer];
        _marqueeLayer.fillColor = [UIColor clearColor].CGColor;
        _marqueeLayer.strokeColor = [UIColor colorWithRed:0.2f green:0.85f blue:0.4f alpha:0.6f].CGColor;
        _marqueeLayer.lineWidth = 2.0f;
        _marqueeLayer.lineDashPattern = @[@14, @8];
        _marqueeLayer.hidden = YES;
        [_blurView.layer addSublayer:_marqueeLayer];

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
                
                self.badgeLabel.hidden = YES;
                self.isShowingNotification = NO;
                self.currentNotification = nil;
                [historyNotifications removeAllObjects];
                
                [self collapseToEdgeAnimated:YES];
                
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
        CGFloat minY = halfH + 20.0f;
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
    if (autoCollapseEnable && !_isCollapsed && !settingsShowing && !detailShowing && !self.isShowingNotification) {
        if (autoExpandLandscape) {
            UIInterfaceOrientation orientation = getActiveInterfaceOrientation();
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

    if (!settingsShowing && !detailShowing && !_isCollapsed && !self.isShowingNotification) {
        UIInterfaceOrientation orientation = getActiveInterfaceOrientation();
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
    
    CGFloat minY = targetHalfH + 20.0f;
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
    };

    void (^completionBlock)(BOOL) = ^(BOOL finished) {
        (void)finished;
        if (self.isCollapsed) {
            for (UIView *v in self.performanceContainer.subviews) {
                if (v != self.collapsedContainerView) v.hidden = YES;
            }
            self.horizontalDiv.hidden = YES;
            self.notificationContainer.hidden = YES;
        }
    };

    if (animated) {
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
    
    CGFloat minY = expandedHalfH + 20.0f;
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
    if (!self.isShowingNotification) {
        self.wasCollapsedBeforeNotification = self.isCollapsed;
    }
    self.isShowingNotification = YES;
    self.currentNotification = req;
    
    if (self.isCollapsed) {
        self.isCollapsed = NO; 
    }
    
    [self.inactivityTimer invalidate]; self.inactivityTimer = nil;
    
    [self.notificationTimer invalidate];
    self.notificationTimer = [NSTimer scheduledTimerWithTimeInterval:notificationDuration target:self selector:@selector(hideNotification) userInfo:nil repeats:NO];
    
    for (UIView *v in self.performanceContainer.subviews) {
        if (v != self.collapsedContainerView) v.hidden = NO;
    }

    [UIView animateWithDuration:0.4 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0.5 options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState animations:^{
        updateFloatingSize(); 
    } completion:nil];
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
    
    if (YES) {
        if (forceFastChargeEnable && isCharging) {
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

    if (isCharging) {
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
    if (settingsShowing || detailShowing) return [super hitTest:point withEvent:event];

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
// 100% 完整保留的设置中心
// ==============================================
@implementation SBCPUSettingsController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"SBCPUFloating V3.0";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(closeSettings)];
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
    return 11; 
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) return 4; 
    if (section == 1) return 3;
    if (section == 2) return 5;
    if (section == 3) return 7; // 通知管理
    if (section == 4) return 3;
    if (section == 5) return 1;
    if (section == 6) return 10;
    if (section == 7) return 2; 
    if (section == 8) return 6;
    if (section == 9) return 5; // 📖 功能说明行数
    if (section == 10) return 8; // 🌡️ 温控功能说明
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
    if (section == 6) return @"🌡️ CPUthermal 温控核心"; 
    if (section == 7) return @"🔌 充电增强";
    if (section == 8) return @"📍 位置与显示";
    if (section == 9) return @"📖 功能与使用说明";
    if (section == 10) return @"🌡️ 温控功能说明（这些功能是做什么的）"; 
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
    if (indexPath.section == 10) {
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
        cell.textLabel.textColor = [UIColor darkTextColor];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightRegular];
        cell.detailTextLabel.textColor = [UIColor grayColor];
        cell.detailTextLabel.numberOfLines = 0;
        cell.textLabel.numberOfLines = 0;

        NSArray *titles = @[
            @"Thermal Pressure 自动保护",
            @"锁屏自动低功耗",
            @"Thermal Nominal 自动恢复",
            @"启动 8 秒温控保护",
            @"防温控暗屏",
            @"屏蔽高温温度计警告",
            @"Thermal Notification 状态",
            @"温控模式"
        ];
        NSArray *descs = @[
            @"检测系统 Thermal Pressure；达到 Heavy 及以上时自动进入低功耗保护，降低设备持续发热压力。",
            @"设备锁屏后自动进入低功耗保护；解锁后按温控状态自动恢复，减少锁屏期间不必要的功耗。",
            @"当系统 Thermal Pressure 回到 Nominal 并持续约 5 秒后，自动结束保护状态，恢复正常运行。",
            @"插件启动后先保持约 8 秒静默期，避免初始化阶段的温控状态误判或控制竞态。",
            @"开启后尽量避免系统因温控策略而主动降低屏幕亮度，减少使用过程中突然暗屏的情况。",
            @"开启后尝试屏蔽系统高温温度计警告弹窗；不会关闭温控检测本身。",
            @"显示当前 CPUthermal 检测到的 Thermal Notification / Pressure 状态，方便查看当前温控等级。",
            @"手动选择温控运行模式：低功耗或解除温控；自动保护功能仍根据对应开关决定是否参与。"
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
            cell.textLabel.text = @"CPUthermal 温控引擎";
            cell.detailTextLabel.text = @"CPUthermal 温控核心总开关，关闭后不主动执行温控控制。";
            UISwitch *sw = [UISwitch new];
            sw.on = sbcputhermalGetBoolPref(@"thermalEngineEnabled", YES);
            [sw addTarget:self action:@selector(changeThermalEngine:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"温控模式";
            cell.detailTextLabel.text = @"选择温控核心当前运行模式；详细说明见下方“温控功能说明”。";
            NSString *mode = sbcputhermalGetStringPref(@"powerMode", @"fullPower");
            cell.detailTextLabel.text = [mode isEqualToString:@"lowPower"] ? @"低功耗" : @"解除温控";
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (indexPath.row == 2) {
            cell.textLabel.text = @"Thermal Pressure 自动保护";
            cell.detailTextLabel.text = @"Heavy 及以上自动进入低功耗保护。";
            cell.detailTextLabel.text = @"Heavy 以上自动进入低功耗";
            UISwitch *sw = [UISwitch new];
            sw.on = sbcputhermalGetBoolPref(@"thermalPressureAutoProtectionEnabled", YES);
            [sw addTarget:self action:@selector(changeThermalPressureProtection:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (indexPath.row == 3) {
            cell.textLabel.text = @"锁屏自动低功耗";
            cell.detailTextLabel.text = @"锁屏降低功耗，解锁后自动恢复。";
            cell.detailTextLabel.text = @"熄屏降低功耗，解锁自动恢复";
            UISwitch *sw = [UISwitch new];
            sw.on = sbcputhermalGetBoolPref(@"thermalLockScreenLowPowerEnabled", YES);
            [sw addTarget:self action:@selector(changeThermalLockScreenLowPower:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (indexPath.row == 4) {
            cell.textLabel.text = @"Thermal Nominal 自动恢复";
            cell.detailTextLabel.text = @"Nominal 持续约 5 秒后自动恢复。";
            cell.detailTextLabel.text = @"Nominal 持续 5 秒后恢复";
            UISwitch *sw = [UISwitch new];
            sw.on = sbcputhermalGetBoolPref(@"thermalNominalAutoRecoveryEnabled", YES);
            [sw addTarget:self action:@selector(changeThermalNominalRecovery:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (indexPath.row == 5) {
            cell.textLabel.text = @"启动 8 秒温控保护";
            cell.detailTextLabel.text = @"启动后固定 8 秒静默期，避免初始化阶段误判。";
            cell.detailTextLabel.text = @"启动静默期固定 8 秒，避免初始化竞态";
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (indexPath.row == 6) {
            cell.textLabel.text = @"防温控暗屏";
            cell.detailTextLabel.text = @"尽量避免温控策略导致屏幕自动变暗。";
            UISwitch *sw = [UISwitch new];
            sw.on = sbcputhermalGetBoolPref(@"thermalPreventDimmingEnabled", NO);
            [sw addTarget:self action:@selector(changeThermalDimming:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (indexPath.row == 7) {
            cell.textLabel.text = @"屏蔽高温温度计警告";
            cell.detailTextLabel.text = @"尝试屏蔽高温警告弹窗，但保留温控检测。";
            UISwitch *sw = [UISwitch new];
            sw.on = sbcputhermalGetBoolPref(@"thermalBlockNotifPopup", NO);
            [sw addTarget:self action:@selector(changeThermalPopup:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (indexPath.row == 8) {
            cell.textLabel.text = @"Thermal Notification 状态";
            SBCPUThermalPressureLevel pressure = SBCPUThermalGetPressureLevel();
            cell.detailTextLabel.text = [NSString stringWithFormat:@"当前：%@", [NSString stringWithUTF8String:SBCPUThermalPressureString(pressure)]];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (indexPath.row == 9) {
            cell.textLabel.text = @"温控核心";
            cell.detailTextLabel.text = @"CPUthermal1.6.4\n由可爱的群主大大 Huayuarc 提供支持";
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
- (void)changeAutoExpandLandscape:(UISwitch *)sw { autoExpandLandscape = sw.isOn; SavePreferencesAndNotify(); }
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
    forceFastChargeEnable = sw.isOn;
    if (sw.isOn) {
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
            SavePreferencesAndNotify();
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    } else {
        SavePreferencesAndNotify();
    }
}

- (void)changeThermalEngine:(UISwitch *)sw {
    sbcputhermalSetBoolPref(@"thermalEngineEnabled", sw.isOn);
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
        return (indexPath.row == 9) ? 72.0 : 64.0;
    }
    if (indexPath.section == 10) {
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
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, onCCNotificationReceived, kPrefChangedNotification, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            createCPUWindow();
            registerV160Observers();
            [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) { updateCPU(); }];
        });
    }
}

