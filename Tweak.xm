#import "SBCPUTextOnlyPolicy.h"
#import "SBCPUTextOnlyColor.h"
#import "SBCPUTextOnlyFormat.h"
#import "SBCPUTextOnlyCurrent.h"

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
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <spawn.h>
#import <sys/mount.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <arpa/inet.h>
#import <CoreMotion/CoreMotion.h>
#import <notify.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <substrate.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#import "SBCPUChargeStore.h"
#import "SBCPUChargeDayNight.h"
#import "SBCPUBatteryMetrics.h"
#import "SBCPUMemoryMetrics.h"
#import "SBCPUFloatingDisplayPolicy.h"
#import "SBCPUFloatingLockPolicy.h"
#import "Shared/LGLiveBackdropView.h"

#ifndef kIOMainPortDefault
#define kIOMainPortDefault kIOMasterPortDefault
#endif

#define kPrefAppID CFSTR("com.yourname.sbcpufloating")
#define kPrefChangedNotification CFSTR("com.yourname.sbcpufloating.prefschanged")

// V4.22 — AppleSMC 控制层前向声明（实现在"充电器输入功率"区之前）
// SpringBoard 无 AppleSMC entitlement，经 SBCPUChargeDaemon(root daemon) socket 转发
static IOReturn sbSMCInit(void);
static IOReturn sbSMCSetChargeBlock(BOOL inhibit, BOOL overrideOBC);
static IOReturn sbSMCSetPowerBlock(BOOL inhibit, BOOL overrideOBC);
static BOOL sbSMCGetChargeBlocked(void);
static BOOL sbSMCGetPowerBlocked(void);
static NSString *sbSMCAvailableString(void);
static IOReturn sbSMCRedecide(void);
static void updateSmartCharge(void);

#pragma mark - 1. 👑 幽灵代理类 (欺骗 Objective-C++ 编译器)

// 插件冲突检测 - 全局变量（移到文件开头，所有方法可访问）
static NSMutableArray *gInstalledPlugins = nil;
static NSMutableArray *gPluginConflicts = nil;
static BOOL gPluginScanDone = NO;
static NSInteger gPluginTotalCount = 0;
static NSInteger gPluginConflictCount = 0;
static NSInteger gDpkgOutputLength = 0;
static NSInteger gDpkgParsedCount = 0;
static NSString *gScanMethod = @"";
static NSString *gScanError = @"";
static NSInteger gDylibCount = 0;
static NSUInteger gPluginScanDirectoryCount = 0;
static NSString *gDylibPath = @"";
static NSMutableArray *gPluginCategories = nil; // 分类列表
static void scanInstalledPlugins(void);
static void onPluginScanRequested(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo);


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
@property (nonatomic, assign) double currentFPS;
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

// iOS 26 私有 Liquid Glass 容器（运行时探测；不存在时安全回退）
@interface CCLiquidGlassView : UIView
- (void)updateForHostView:(UIView *)hostView;
- (void)updateForHostView:(UIView *)hostView preferredStyle:(NSInteger)style;
@end

@interface SBCPUFloatingView : UIView <UIGestureRecognizerDelegate>
@property (nonatomic, assign) CGPoint lastPoint;
@property (nonatomic, strong) UIVisualEffectView *blurView; // 兼容旧版 fallback
@property (nonatomic, strong) UIView *glassSurfaceView; // 当前浮窗唯一可见背景表面
@property (nonatomic, strong) UIView *glassContentView; // 内容层
@property (nonatomic, strong) UIView *nativeLiquidGlassView; // CCLiquidGlassView
@property (nonatomic, assign) BOOL usingNativeLiquidGlass;
@property (nonatomic, strong) CAShapeLayer *marqueeLayer;
@property (nonatomic, strong) CAShapeLayer *marqueeFlowLayerA;
@property (nonatomic, strong) CAShapeLayer *marqueeFlowLayerB;
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
@property (nonatomic, strong) UILabel *timeLabel; // 游戏/横屏时显示时间 HH:mm:ss
@property (nonatomic, strong) UILabel *signalLabel; // 📶 SIM 卡信号行（V4.18.0）
@property (nonatomic, strong) UIView *collapsedContainerView;
@property (nonatomic, strong) UIView *statusDot;
@property (nonatomic, strong) UILabel *miniCpuLabel;
@property (nonatomic, strong) UILabel *miniFpsLabel;   // 横屏迷你胶囊：FPS
@property (nonatomic, strong) UILabel *miniBattLabel;  // 横屏迷你胶囊：电量
@property (nonatomic, strong) UILabel *miniTempLabel;  // 横屏迷你胶囊：温度
@property (nonatomic, strong) UILabel *miniDockInfoLabel; // 状态栏胶囊：可选信息条
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
// 展开/收起动画期间锁住周期性 updateFloatingSize，避免 1s 刷新打断尺寸动画造成“打开后又扩大一下”。
@property (nonatomic, assign) BOOL layoutTransitionAnimating;
@property (nonatomic, strong) NSTimer *inactivityTimer;
@property (nonatomic, strong) NSTimer *statusDockReturnTimer;
@property (nonatomic, assign) BOOL statusDockDragging;
@property (nonatomic, assign) BOOL positionLocked;
@property (nonatomic, assign) CGPoint lockedCenter;
@property (nonatomic, strong) UITapGestureRecognizer *doubleTapGesture;
@property (nonatomic, strong) UITapGestureRecognizer *singleTapGesture;
@property (nonatomic, strong) UILongPressGestureRecognizer *longPressGesture;

- (void)applyLiquidGlassStyle;
- (void)refreshNativeLiquidGlass;
- (void)resetInactivityTimer;
- (void)scheduleStatusDockReturn;
- (void)returnToStatusDock;
- (void)collapseToEdgeAnimated:(BOOL)animated;
- (void)expandFromEdgeAnimated:(BOOL)animated;
- (void)syncCollapsedLayoutForOrientation;
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
@interface SBCPULockCleanupAddAppController : UITableViewController <UISearchBarDelegate>
@property (nonatomic, strong) NSArray *allApps;
@property (nonatomic, strong) NSArray *filteredApps;
@property (nonatomic, strong) UISearchBar *searchBar;
@end
@interface SBCPUSpringBoardLockCleanupWhitelistController : UITableViewController
@end
@interface SBCPUSpringBoardChargeHistoryController : UITableViewController
@end
@interface SBCPUSettingsController : UITableViewController <UIGestureRecognizerDelegate>
- (void)saveConfigs;
@property (nonatomic, strong) CALayer *glassBackdrop;  // 设置中心 backdrop 模糊层（可调磨砂强度）
@property (nonatomic, strong) CAGradientLayer *glassGradient; // 设置中心蓝紫渐变玻璃底（图二风格）
@property (nonatomic, strong) UIView *glassDimView;    // 兼容保留
// V4.18.1 — 分组折叠：记录被折叠的 section，支持点击标题栏展开/收起
@property (nonatomic, strong) NSMutableSet *collapsedSections;
- (void)toggleSection:(UITapGestureRecognizer *)gr;
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
static BOOL compactLandscapeCapsule = NO; // 横屏迷你胶囊：开启后收成竖屏式单段（仅 CPU），不碍眼
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
static NSInteger statusDockReturnDelay = 5;
static NSTimer *gFloatingUpdateTimer = nil;
static BOOL gCPUUpdatePending = NO;
static NSTimeInterval floatingValueRefreshInterval = 1.0;
static BOOL statusBarDockEnable = NO; // 开启后浮窗吸附到顶部状态栏安全区域

// Presentation-only mode: never overwrite normal docking/geometry preferences.
static BOOL floatingTextOnlyMode = NO;
static NSInteger floatingTextOnlyPreset = 1;
static CGFloat floatingTextOnlyX = 0, floatingTextOnlyY = 0;
static CGFloat floatingTextOnlyFontSize = 13;
static NSInteger floatingTextOnlyColor = 0; // 0 system appearance, 1 white, 2 black, 3 custom
static SBCPUTextRGBA textOnlyCustomRGBA = {0, 122.0/255.0, 1, 1};
static BOOL textOnlyShowCPU = YES, textOnlyShowFrequency = YES, textOnlyShowFPS = YES;
static BOOL textOnlyShowBattery = YES, textOnlyShowTemperature = YES, textOnlyShowCurrent = YES;
static BOOL textOnlyShowSIM1 = YES, textOnlyShowSIM2 = YES;
static NSArray<NSDictionary *> *textOnlySignals = nil;
// Updated on the existing UI sampling tick; never reuse the ordinary label's
// smart-stop zero or the legacy 150 mA fallback.
static NSNumber *textOnlyBatteryCurrent = nil;
static NSTimeInterval textOnlyCurrentUptime = 0;
static UILabel *textOnlyLabel = nil;
static BOOL textOnlyDragging = NO;
static BOOL textOnlySnapshotValid = NO, textOnlySnapshotCollapsed = NO;
static CGPoint textOnlySnapshotCenter;
static NSMapTable<UIView *, NSNumber *> *textOnlyHiddenSnapshot;
static float textOnlyShadowOpacity;
static CGFloat textOnlyBorderWidth;
static inline BOOL sbcpuStatusBarDockEffective(void) { return SBCPUTextOnlyDockEffective(statusBarDockEnable, floatingTextOnlyMode); }
static BOOL statusDockShowCPU = YES;
static BOOL statusDockShowFPS = YES;
static BOOL statusDockShowFrequency = NO;
static BOOL statusDockShowCurrent = NO;
static BOOL statusDockShowTemperature = NO;
static BOOL statusDockShowBattery = YES;
static BOOL statusDockShowSIM1 = NO;
static BOOL statusDockShowSIM2 = NO;

static BOOL showCpuFrequency = YES;
static BOOL showFps = YES;
static BOOL showSignalStrength = YES; // 📶 浮窗底部显示 SIM 卡信号（V4.18.0）


static NSInteger chargeMarqueeStyle = 0; // 0=呼吸渐变，1=双向对流光
static BOOL chargeBoostEnable = NO;
static BOOL suppressPartRepairEnabled = NO; // 🛡️ 屏蔽部件与维修记录（移植自 CPUthermal）
static BOOL forceFastChargeEnable = NO; // 保留原有强制满血快充开关
static BOOL fastChargeStartupAnimating = NO;

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
static float liquidGlassStrength = 0.75f;
static float liquidGlassRefraction = 0.65f;
static float liquidGlassThickness = 0.70f;
static float liquidGlassSpecular = 0.65f;
static float liquidGlassDispersion = 0.20f;
static float liquidGlassBezel = 0.90f;
static float liquidGlassRefractiveIndex = 1.70f;
static float liquidGlassQuality = 1.0f;
// V4.8 液态玻璃自定义：背景白雾透明度 / 磨砂强度(blurRadius) / 卡片不透明度
static float glassDimOpacity = 0.90f;
static float glassBlurRadius = 50.0f;
static float glassCardOpacity = 0.80f;
// 智能停充
static BOOL smartChargeEnable = NO;
static NSInteger smartChargeUpperLimit = 80;  // 停充上限
static NSInteger smartChargeLowerLimit = 70;  // 回充下限
static NSInteger smartChargeMode = 0;          // 0=日常80%, 1=出行100%, 2=保养60%
static BOOL smartChargeStopped = NO;           // 当前是否处于停充状态
static BOOL blockChargingEnable = NO;          // V4.21 — 阻止充电（SMC CH0C，经 daemon）
static BOOL blockPowerEnable = NO;             // V4.21 — 阻止外部供电（SMC CH0I，经 daemon）
static BOOL chargeKeepAC = YES;                // V4.25 — 达到上限时保留外部供电（只停充不断 AC）
static BOOL gSmartChargeHoldDisplay = NO; // V4.34：CH0I 停充时仍保持浮窗充电布局
static BOOL chargeOverrideOBC = NO;            // V4.25 — 覆盖系统"优化电池充电"接管（OBC）
// 智能温度停充（独立于 CPU thermalmonitord 温控）
static BOOL smartThermalChargeEnable = NO;
static NSInteger smartThermalUpperC = 42;
static NSInteger smartThermalLowerC = 38;

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
static BOOL lockCleanupEnable = NO; // 锁屏清理后台：锁屏后自动关闭所有第三方后台应用
static NSMutableArray *lockCleanupWhitelist = nil; // 锁屏清理白名单：这些应用不会被清理（bundle id 数组）
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
static void createCPUWindow(void);
static void openDetailView(void);
static void checkHighCPU(double cpu);
static void updateCPU(void);
static void applyTextOnlyMode(void);
static void applyTextOnlyTextFilter(void);
static void handleTextOnlyModeTransition(BOOL wasEnabled);
static void LGRemoveLabelShadowInView(UIView *view);

// ============================================================
// 📶 SIM 卡信号显示（V4.18.0）
// 运营商/制式走 CoreTelephony 公开 API（KVC 动态调用，不链接框架）；
// 信号强度读 SpringBoard 私有 SBTelephonyManager（signalStrengthBars），
// 全部动态检测，拿不到就只显示运营商 + 制式，绝不崩溃。
// ============================================================

static NSString *shortRadioTech(NSString *tech) {
    if (!tech.length) return nil;
    if ([tech containsString:@"NR"]) return @"5G";
    if ([tech containsString:@"LTE"]) return @"4G";
    if ([tech containsString:@"UTRAN"] || [tech containsString:@"WCDMA"]) return @"3G";
    if ([tech containsString:@"GPRS"] || [tech containsString:@"EDGE"]) return @"2G";
    return @"?G";
}

// ============================================================
// SIM 双卡蜂窝数据读取（iOS 13+ CoreTelephonyClient XPC ObjC API）
// 依据 iOS 17.1 classdump：
//   -getSubscriptionInfoWithError: → subscriptions（每卡一个 context，天然双卡）
//   -getSignalStrengthInfo:error:  → displayBars/bars（信号格）
//   -getSignalStrengthMeasurements:error: → rsrp/rssi(dBm)、rsrq、snr
//   -copyRadioAccessTechnology:error: → 制式字符串
//   -getOperatorName:error:        → 当前注册网络运营商名（iOS 16+）
//   -getDataStatus:error:          → SA/NSA 覆盖、漫游(inHomeCountry)、数据卡、attached
//   -copyCellInfo:completion:      → 异步：频段/频宽/ARFCN/PCI/CellID/TAC/MCC/MNC
//   -getMobileEquipmentInfo:       → IMEI/MEID/EID/ICCID
// 全程 ObjC 消息派发 + @try 兜底；不使用会崩溃的 _CTServerConnection C 函数。
// tweak 注入 SpringBoard，进程本身具备 CommCenter XPC 权限。
// ============================================================
#import <objc/message.h>

typedef id (*SBMsgSendErr1)(id, SEL, NSError **);
typedef id (*SBMsgSendErr2)(id, SEL, id, NSError **);
typedef void (*SBMsgSendErr3Obj)(id, SEL, id, id, NSError **);
typedef void (*SBMsgSendAsyncCell)(id, SEL, id, void (^)(id info, NSError *error));

// XPC 客户端复用（只创建一次）
static id gCTClientXPC = nil;
static id ctXPCClient(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @try {
            Class cls = NSClassFromString(@"CoreTelephonyClient");
            if ([cls instancesRespondToSelector:@selector(init)]) {
                gCTClientXPC = [[cls alloc] init];
            }
        } @catch (NSException *e) { gCTClientXPC = nil; }
    });
    return gCTClientXPC;
}

// 运营商全称 → 中文简称
static NSString *carrierShortName(NSString *name) {
    if (!name || name.length == 0) return nil;
    NSString *s = name.lowercaseString;
    if ([s containsString:@"移动"] || [s containsString:@"cmcc"] || [s containsString:@"china mobile"]) return @"移动";
    if ([s containsString:@"联通"] || [s containsString:@"unicom"] || [s containsString:@"cucc"]) return @"联通";
    if ([s containsString:@"电信"] || [s containsString:@"telecom"] || [s containsString:@"ctcc"]) return @"电信";
    if ([s containsString:@"广电"] || [s containsString:@"broadnet"] || [s containsString:@"cbn"]) return @"广电";
    // 境外/其它运营商：保留原名前 6 个字符，避免浮窗过长
    return (name.length > 6) ? [name substringToIndex:6] : name;
}

// 基站小区信息缓存（copyCellInfo 为异步 XPC，不能每秒同步等待，故后台刷新、浮窗读缓存）
// key = 卡槽序号(NSNumber)，value = 字典 band/bandwidth/nrarfcn/uarfcn/pci/cellid/tac/scs/mcc/mnc
static NSMutableDictionary<NSNumber *, NSDictionary *> *gCellInfoCache = nil;
static NSTimeInterval gLastCellInfoFetch = 0;

static NSDictionary *cellInfoForSlot(NSInteger slot) {
    if (!gCellInfoCache) return nil;
    @synchronized (gCellInfoCache) {
        return gCellInfoCache[@(slot)];
    }
}

// 从 CTCellInfo.legacyInfo 中取 Serving Cell 字典
static NSDictionary *servingCellFromInfo(id info) {
    @try {
        NSArray *legacy = [info valueForKey:@"legacyInfo"];
        if (![legacy isKindOfClass:[NSArray class]] || legacy.count == 0) return nil;
        for (id entry in legacy) {
            if (![entry isKindOfClass:[NSDictionary class]]) continue;
            if ([[entry objectForKey:@"kCTCellMonitorCellType"] isEqual:@"kCTCellMonitorCellTypeServing"]) {
                return entry;
            }
        }
        for (id entry in legacy) {
            if ([entry isKindOfClass:[NSDictionary class]]) return entry;
        }
    } @catch (NSException *e) {}
    return nil;
}

// 触发一次全部卡的基站信息异步查询（非阻塞，结果进缓存）。节流 8 秒。
static void refreshCellInfoAsync(NSArray *contexts) {
    @try {
        id client = ctXPCClient();
        if (!client || contexts.count == 0) return;
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        if (now - gLastCellInfoFetch < 8.0) return;
        gLastCellInfoFetch = now;
        if (!gCellInfoCache) gCellInfoCache = [NSMutableDictionary dictionary];
        if (![client respondsToSelector:@selector(copyCellInfo:completion:)]) return;
        SBMsgSendAsyncCell callAsync = (SBMsgSendAsyncCell)objc_msgSend;
        NSInteger order = 1;
        for (id context in contexts) {
            NSNumber *slotKey = @(order);
            callAsync(client, @selector(copyCellInfo:completion:), context, ^(id info, NSError *error) {
                @try {
                    NSDictionary *cell = servingCellFromInfo(info);
                    if (!cell) return;
                    id (^num)(NSString *) = ^id(NSString *k) {
                        id v = cell[k];
                        return [v isKindOfClass:[NSNumber class]] ? v : nil;
                    };
                    NSMutableDictionary *d = [NSMutableDictionary dictionary];
                    if (num(@"kCTCellMonitorBandInfo")) d[@"band"] = num(@"kCTCellMonitorBandInfo");
                    if (num(@"kCTCellMonitorBandwidth")) d[@"bandwidth"] = num(@"kCTCellMonitorBandwidth");
                    if (num(@"kCTCellMonitorNRARFCN")) d[@"nrarfcn"] = num(@"kCTCellMonitorNRARFCN");
                    if (num(@"kCTCellMonitorUARFCN")) d[@"uarfcn"] = num(@"kCTCellMonitorUARFCN");
                    if (num(@"kCTCellMonitorPID")) d[@"pci"] = num(@"kCTCellMonitorPID");
                    if (num(@"kCTCellMonitorCellId")) d[@"cellid"] = num(@"kCTCellMonitorCellId");
                    if (num(@"kCTCellMonitorTAC")) d[@"tac"] = num(@"kCTCellMonitorTAC");
                    if (num(@"kCTCellMonitorSCS")) d[@"scs"] = num(@"kCTCellMonitorSCS");
                    if (num(@"kCTCellMonitorMCC")) d[@"mcc"] = num(@"kCTCellMonitorMCC");
                    if (num(@"kCTCellMonitorMNC")) d[@"mnc"] = num(@"kCTCellMonitorMNC");
                    if (d.count > 0) {
                        @synchronized (gCellInfoCache) { gCellInfoCache[slotKey] = d; }
                    }
                } @catch (NSException *e) {}
            });
            order++;
        }
    } @catch (NSException *e) {}
}

// 频段显示：5G→n78，4G→B3，其它为空
static NSString *bandStringForSlot(NSInteger slot, NSString *tech) {
    @try {
        NSDictionary *c = cellInfoForSlot(slot);
        NSNumber *band = c[@"band"];
        if (!band || band.integerValue <= 0) return nil;
        if ([tech isEqual:@"5G"]) return [NSString stringWithFormat:@"n%ld", (long)band.integerValue];
        if ([tech isEqual:@"4G"]) return [NSString stringWithFormat:@"B%ld", (long)band.integerValue];
    } @catch (NSException *e) {}
    return nil;
}

// 读取全部卡的真实信号快照（同步、轻量，可供浮窗每秒调用）
static NSArray<NSDictionary *> *readAllSimSignals(void) {
    NSMutableArray *out = [NSMutableArray array];
    @try {
        id client = ctXPCClient();
        if (!client) return out;
        SBMsgSendErr1 call1 = (SBMsgSendErr1)objc_msgSend;
        SBMsgSendErr2 call2 = (SBMsgSendErr2)objc_msgSend;

        NSError *subErr = nil;
        id subInfo = call1(client, @selector(getSubscriptionInfoWithError:), &subErr);
        if (!subInfo) return out;
        NSArray *contexts = [subInfo valueForKey:@"subscriptions"];
        if (![contexts isKindOfClass:[NSArray class]] || contexts.count == 0) return out;

        // 异步刷新基站信息（内部节流，不阻塞本次调用）
        refreshCellInfoAsync(contexts);

        Class descCls = NSClassFromString(@"CTServiceDescriptor");
        NSInteger order = 1;
        for (id context in contexts) {
            @try {
                NSInteger bars = -1;
                NSString *dbm = nil, *rsrq = nil, *snr = nil, *tech = nil, *carrier = nil;
                BOOL attached = NO, roaming = NO, dataSim = NO, sa = NO, nsa = NO, nr = NO;

                // 1) 信号格数
                NSError *e1 = nil;
                id sigInfo = call2(client, @selector(getSignalStrengthInfo:error:), context, &e1);
                if (sigInfo) {
                    NSNumber *display = [sigInfo valueForKey:@"displayBars"];
                    NSNumber *rawBars = [sigInfo valueForKey:@"bars"];
                    NSNumber *use = ([display isKindOfClass:[NSNumber class]]) ? display : rawBars;
                    if ([use isKindOfClass:[NSNumber class]]) {
                        NSInteger b = use.integerValue;
                        if (b >= 0 && b <= 5) bars = b;
                    }
                }

                // 2) 信号测量：dBm(rsrp/rssi)、rsrq、snr
                if (descCls && [descCls respondsToSelector:@selector(descriptorWithSubscriptionContext:)]) {
                    id desc = [descCls performSelector:@selector(descriptorWithSubscriptionContext:) withObject:context];
                    if (desc) {
                        NSError *e2 = nil;
                        id meas = call2(client, @selector(getSignalStrengthMeasurements:error:), desc, &e2);
                        if (meas) {
                            NSNumber *rsrpN = [meas valueForKey:@"rsrp"];
                            NSNumber *rssiN = [meas valueForKey:@"rssi"];
                            NSNumber *use = ([rsrpN isKindOfClass:[NSNumber class]] && rsrpN.integerValue < 0) ? rsrpN : rssiN;
                            if ([use isKindOfClass:[NSNumber class]] && use.integerValue < 0)
                                dbm = [NSString stringWithFormat:@"%ld", (long)use.integerValue];
                            NSNumber *rsrqN = [meas valueForKey:@"rsrq"];
                            if ([rsrqN isKindOfClass:[NSNumber class]] && rsrqN.floatValue != 0)
                                rsrq = [NSString stringWithFormat:@"%.0f", rsrqN.floatValue];
                            NSNumber *snrN = [meas valueForKey:@"snr"];
                            if ([snrN isKindOfClass:[NSNumber class]] && snrN.floatValue != 0)
                                snr = [NSString stringWithFormat:@"%.0f", snrN.floatValue];
                        }
                    }
                }

                // 3) 制式
                NSError *e3 = nil;
                id techRaw = call2(client, @selector(copyRadioAccessTechnology:error:), context, &e3);
                if ([techRaw isKindOfClass:[NSString class]]) tech = shortRadioTech(techRaw);

                // 4) 运营商名（iOS 16+）
                if ([client respondsToSelector:@selector(getOperatorName:error:)]) {
                    NSError *e4 = nil;
                    id op = call2(client, @selector(getOperatorName:error:), context, &e4);
                    if ([op isKindOfClass:[NSString class]] && ((NSString *)op).length > 0
                        && ![(NSString *)op isEqualToString:@"--"]) {
                        carrier = carrierShortName(op);
                    }
                }

                // 5) 数据状态：SA/NSA、漫游、数据卡、附着
                if ([client respondsToSelector:@selector(getDataStatus:error:)]) {
                    NSError *e5 = nil;
                    id ds = call2(client, @selector(getDataStatus:error:), context, &e5);
                    if (ds) {
                        attached = [[ds valueForKey:@"attached"] boolValue];
                        dataSim  = [[ds valueForKey:@"dataSim"] boolValue];
                        nr       = [[ds valueForKey:@"newRadioCoverage"] boolValue];
                        sa       = [[ds valueForKey:@"newRadioSaCoverage"] boolValue];
                        nsa      = [[ds valueForKey:@"newRadioNsaCoverage"] boolValue];
                        roaming  = ![[ds valueForKey:@"inHomeCountry"] boolValue];
                    }
                }

                NSMutableDictionary *d = [NSMutableDictionary dictionary];
                d[@"slot"] = @(order);
                d[@"bars"] = @(bars);
                d[@"attached"] = @(attached);
                d[@"roaming"] = @(roaming);
                d[@"dataSim"] = @(dataSim);
                d[@"sa"] = @(sa); d[@"nsa"] = @(nsa); d[@"nr"] = @(nr);
                if (dbm) d[@"dbm"] = dbm;
                if (rsrq) d[@"rsrq"] = rsrq;
                if (snr) d[@"snr"] = snr;
                if (tech) d[@"tech"] = tech;
                if (carrier) d[@"carrier"] = carrier;
                [out addObject:d];
            } @catch (NSException *e) {}
            order++;
        }
    } @catch (NSException *e) {}
    return out;
}

// 设备移动台信息列表（IMEI/MEID/EID/ICCID），详情页打开时读一次，失败返回空
static NSArray<NSDictionary *> *readMobileEquipmentInfo(void) {
    NSMutableArray *out = [NSMutableArray array];
    @try {
        id client = ctXPCClient();
        if (!client || ![client respondsToSelector:@selector(getMobileEquipmentInfo:)]) return out;
        SBMsgSendErr1 call1 = (SBMsgSendErr1)objc_msgSend;
        NSError *err = nil;
        id list = call1(client, @selector(getMobileEquipmentInfo:), &err);
        NSArray *items = [list valueForKey:@"meInfoList"];
        if (![items isKindOfClass:[NSArray class]]) return out;
        for (id it in items) {
            NSMutableDictionary *d = [NSMutableDictionary dictionary];
            NSString *(^s)(NSString *) = ^NSString *(NSString *k) {
                id v = [it valueForKey:k];
                return ([v isKindOfClass:[NSString class]] && ((NSString *)v).length > 0) ? v : nil;
            };
            if (s(@"IMEI")) d[@"imei"] = s(@"IMEI");
            if (s(@"MEID")) d[@"meid"] = s(@"MEID");
            if (s(@"ICCID")) d[@"iccid"] = s(@"ICCID");
            if (s(@"IMSI")) d[@"imsi"] = s(@"IMSI");
            if (s(@"CSN")) d[@"eid"] = s(@"CSN");
            if (d.count) [out addObject:d];
        }
    } @catch (NSException *e) {}
    return out;
}

// ============================================================
// 网络频段锁定（Band Selection）— iOS14+ CTBandInfo / setActiveBandInfo
// 写操作需 com.apple.CommCenter.fine-grained 的 spi 授权；注入 SpringBoard
// 时权限随宿主进程，失败时返回 NSError 由 UI 明示，不做“点了没反应”的假动作。
// ============================================================

// 取第 slot 张卡（1-based）的 subscription context
static id ctContextForSlot(NSInteger slot) {
    @try {
        id client = ctXPCClient();
        if (!client) return nil;
        SBMsgSendErr1 call1 = (SBMsgSendErr1)objc_msgSend;
        NSError *subErr = nil;
        id subInfo = call1(client, @selector(getSubscriptionInfoWithError:), &subErr);
        if (!subInfo) return nil;
        NSArray *contexts = [subInfo valueForKey:@"subscriptions"];
        if (![contexts isKindOfClass:[NSArray class]] || contexts.count == 0) return nil;
        NSInteger idx = slot - 1;
        if (idx < 0 || idx >= (NSInteger)contexts.count) return nil;
        return contexts[idx];
    } @catch (NSException *e) { return nil; }
}

// 读取某卡 CTBandInfo（fSupportedBands 设备支持 / fActiveBands 当前启用）
static id readBandInfoForSlot(NSInteger slot, NSError **outErr) {
    @try {
        id client = ctXPCClient();
        id context = ctContextForSlot(slot);
        if (!client || !context) {
            if (outErr) *outErr = [NSError errorWithDomain:@"SBCPU" code:-100
                userInfo:@{NSLocalizedDescriptionKey:@"无法获取该卡槽基带上下文（无 SIM 卡？）"}];
            return nil;
        }
        if (![client respondsToSelector:@selector(getBandInfo:error:)]) {
            if (outErr) *outErr = [NSError errorWithDomain:@"SBCPU" code:-101
                userInfo:@{NSLocalizedDescriptionKey:@"当前系统不支持频段读取接口（需 iOS 14+）"}];
            return nil;
        }
        SBMsgSendErr2 call2 = (SBMsgSendErr2)objc_msgSend;
        NSError *err = nil;
        id bandInfo = call2(client, @selector(getBandInfo:error:), context, &err);
        if (outErr) *outErr = err;
        return bandInfo;
    } @catch (NSException *e) {
        if (outErr) *outErr = [NSError errorWithDomain:@"SBCPU" code:-102
            userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"读取频段异常: %@", e.name]}];
        return nil;
    }
}

// 下发活动频段（锁定）。bandInfo 须为读取对象修改 fActiveBands 后的同一实例
static BOOL writeActiveBandInfoForSlot(NSInteger slot, id bandInfo, NSError **outErr) {
    @try {
        id client = ctXPCClient();
        id context = ctContextForSlot(slot);
        if (!client || !context || !bandInfo) {
            if (outErr) *outErr = [NSError errorWithDomain:@"SBCPU" code:-200
                userInfo:@{NSLocalizedDescriptionKey:@"下发失败：上下文或频段数据缺失"}];
            return NO;
        }
        if (![client respondsToSelector:@selector(setActiveBandInfo:bands:error:)]) {
            if (outErr) *outErr = [NSError errorWithDomain:@"SBCPU" code:-201
                userInfo:@{NSLocalizedDescriptionKey:@"当前系统不支持频段设置接口"}];
            return NO;
        }
        SBMsgSendErr3Obj call3 = (SBMsgSendErr3Obj)objc_msgSend;
        NSError *err = nil;
        call3(client, @selector(setActiveBandInfo:bands:error:), context, bandInfo, &err);
        if (outErr) *outErr = err;
        return (err == nil);
    } @catch (NSException *e) {
        if (outErr) *outErr = [NSError errorWithDomain:@"SBCPU" code:-202
            userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"下发异常: %@ - %@", e.name, e.reason ?: @""]}];
        return NO;
    }
}

// 组装浮窗底部信号行：运营商 dBm 频段 制式（双卡，去格画），全部真实每秒刷新
static NSString *getSignalInfoString(void) {
    if (!showSignalStrength) return @"";
    @try {
        NSArray *sims = readAllSimSignals();
        if (sims.count == 0) return @"";
        NSMutableArray *parts = [NSMutableArray array];
        for (NSDictionary *s in sims) {
            NSInteger slot = [s[@"slot"] integerValue];
            NSString *tech = s[@"tech"];
            NSString *name = s[@"carrier"] ?: [NSString stringWithFormat:@"SIM%ld", (long)slot];
            NSMutableString *seg = [NSMutableString stringWithString:name];
            // 数据卡在名字后加个小标记
            if ([s[@"dataSim"] boolValue]) [seg appendString:@"●"];
            if (s[@"dbm"]) [seg appendFormat:@" %@", s[@"dbm"]];
            NSString *band = bandStringForSlot(slot, tech);
            if (band) [seg appendFormat:@" %@", band];
            if (tech) {
                // SA/NSA 区分：SA 显示 5G⁺，NSA 显示 5G
                if ([tech isEqual:@"5G"]) {
                    [seg appendFormat:@" %@", [s[@"sa"] boolValue] ? @"5G+" : @"5G"];
                } else {
                    [seg appendFormat:@" %@", tech];
                }
            }
            if ([s[@"roaming"] boolValue]) [seg appendString:@" 漫游"];
            [parts addObject:seg];
        }
        return [parts componentsJoinedByString:@" · "];
    } @catch (NSException *e) {
        return @"";
    }
}

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
    if (SBChargeKey((__bridge NSString *)key)) {
        id v = SBChargeRead()[(__bridge NSString *)key];
        return v ? [v boolValue] : defaultVal;
    }
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
    if (SBChargeKey((__bridge NSString *)key)) {
        id v = SBChargeRead()[(__bridge NSString *)key];
        return v ? [v floatValue] : defaultVal;
    }
    CFPropertyListRef val = CFPreferencesCopyValue(key, kPrefAppID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (val) {
        float res = defaultVal;
        if (CFGetTypeID(val) == CFNumberGetTypeID()) CFNumberGetValue((CFNumberRef)val, kCFNumberFloatType, &res);
        CFRelease(val); return res;
    }
    return defaultVal;
}

static NSInteger getIntPref(CFStringRef key, NSInteger defaultVal) {
    if (SBChargeKey((__bridge NSString *)key)) {
        id v = SBChargeRead()[(__bridge NSString *)key];
        return v ? [v integerValue] : defaultVal;
    }
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

static NSArray *getArrayPref(CFStringRef key, NSArray *defaultVal) {
    CFPropertyListRef val = CFPreferencesCopyValue(key, kPrefAppID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (val) {
        if (CFGetTypeID(val) == CFArrayGetTypeID()) {
            return (__bridge_transfer NSArray *)val;
        }
        CFRelease(val);
    }
    return defaultVal;
}

static void setArrayPref(CFStringRef key, NSArray *value) {
    if (value) {
        CFPreferencesSetValue(key, (__bridge CFArrayRef)value, kPrefAppID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    }
}

static void applyVisibility(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (cpuWindow) cpuWindow.hidden = !isEnabled;
    });
}

static void applyFloatingAlpha(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (floatingView) floatingView.alpha = floatingTextOnlyMode ? 1.0 : (floatingAlphaEnable ? floatingAlpha : 1.0);
    });
}

static void LoadPreferences(void) {
    BOOL wasTextOnly = floatingTextOnlyMode;
    CFPreferencesAppSynchronize(kPrefAppID);

    isEnabled = getBoolPref(CFSTR("isEnabled"), YES);
    autoCollapseEnable = getBoolPref(CFSTR("autoCollapseEnable"), YES);
    autoCollapseDelay = getIntPref(CFSTR("autoCollapseDelay"), 4);
    collapsedDisplayMode = getIntPref(CFSTR("collapsedDisplayMode"), 0);
    autoExpandLandscape = getBoolPref(CFSTR("autoExpandLandscape"), YES);
    compactLandscapeCapsule = getBoolPref(CFSTR("compactLandscapeCapsule"), NO);
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
    statusBarDockEnable = getBoolPref(CFSTR("statusBarDockEnable"), NO);
    floatingTextOnlyMode = getBoolPref(CFSTR("floatingTextOnlyMode"), NO);
    floatingTextOnlyPreset = MAX(0, MIN(2, getIntPref(CFSTR("floatingTextOnlyPreset"), 1)));
    floatingTextOnlyX = SBCPUTextOnlyBound(getFloatPref(CFSTR("floatingTextOnlyX"), 0), -1000, 1000, 0);
    floatingTextOnlyY = SBCPUTextOnlyBound(getFloatPref(CFSTR("floatingTextOnlyY"), 0), -1000, 1000, 0);
    floatingTextOnlyFontSize = SBCPUTextOnlyBound(getFloatPref(CFSTR("floatingTextOnlyFontSize"), 13), 8, 24, 13);
    floatingTextOnlyColor = getIntPref(CFSTR("floatingTextOnlyColor"), 0);
    if (floatingTextOnlyColor < 0 || floatingTextOnlyColor > 3) floatingTextOnlyColor = 0;
    textOnlyCustomRGBA = SBCPUTextDecodeRGBA(getArrayPref(CFSTR("floatingTextOnlyRGBA"), nil));
    // Independent defaults: ordinary show flags never govern this row.
    textOnlyShowCPU = getBoolPref(CFSTR("floatingTextOnlyShowCPU"), YES);
    textOnlyShowFrequency = getBoolPref(CFSTR("floatingTextOnlyShowFrequency"), YES);
    textOnlyShowFPS = getBoolPref(CFSTR("floatingTextOnlyShowFPS"), YES);
    textOnlyShowBattery = getBoolPref(CFSTR("floatingTextOnlyShowBattery"), YES);
    textOnlyShowTemperature = getBoolPref(CFSTR("floatingTextOnlyShowTemperature"), YES);
    textOnlyShowCurrent = getBoolPref(CFSTR("floatingTextOnlyShowCurrent"), YES);
    textOnlyShowSIM1 = getBoolPref(CFSTR("floatingTextOnlyShowSIM1"), YES);
    textOnlyShowSIM2 = getBoolPref(CFSTR("floatingTextOnlyShowSIM2"), YES);
    statusDockReturnDelay = MAX(1, MIN(30, getIntPref(CFSTR("statusDockReturnDelay"), 5)));
    floatingValueRefreshInterval = MAX(1.0, MIN(2.0, getFloatPref(CFSTR("floatingValueRefreshInterval"), 1.0f)));
    statusDockShowCPU = getBoolPref(CFSTR("statusDockShowCPU"), YES);
    statusDockShowFPS = getBoolPref(CFSTR("statusDockShowFPS"), YES);
    statusDockShowFrequency = getBoolPref(CFSTR("statusDockShowFrequency"), NO);
    statusDockShowCurrent = getBoolPref(CFSTR("statusDockShowCurrent"), NO);
    statusDockShowTemperature = getBoolPref(CFSTR("statusDockShowTemperature"), NO);
    statusDockShowBattery = getBoolPref(CFSTR("statusDockShowBattery"), YES);
    statusDockShowSIM1 = getBoolPref(CFSTR("statusDockShowSIM1"), NO);
    statusDockShowSIM2 = getBoolPref(CFSTR("statusDockShowSIM2"), NO);

    showCpuFrequency = getBoolPref(CFSTR("showCpuFrequency"), YES);
    showFps = getBoolPref(CFSTR("showFps"), YES);
    showSignalStrength = getBoolPref(CFSTR("showSignalStrength"), YES);

    showBatteryPercent = getBoolPref(CFSTR("showBatteryPercent"), YES);
    showBatteryTemperature = getBoolPref(CFSTR("showBatteryTemperature"), YES);
    showBatteryCurrent = getBoolPref(CFSTR("showBatteryCurrent"), YES);
    liquidGlassEnabled = getBoolPref(CFSTR("liquidGlassEnabled"), YES);
    // V4.36 Liquid Glass renderer tuning.
    liquidGlassStrength = getFloatPref(CFSTR("SBCPU.LiquidGlass.Strength"), 0.75f);
    liquidGlassRefraction = getFloatPref(CFSTR("SBCPU.LiquidGlass.Refraction"), 0.65f);
    liquidGlassThickness = getFloatPref(CFSTR("SBCPU.LiquidGlass.Thickness"), 0.70f);
    liquidGlassSpecular = getFloatPref(CFSTR("SBCPU.LiquidGlass.Specular"), 0.65f);
    liquidGlassDispersion = getFloatPref(CFSTR("SBCPU.LiquidGlass.Dispersion"), 0.20f);
    liquidGlassBezel = getFloatPref(CFSTR("SBCPU.LiquidGlass.Bezel"), 0.90f);
    liquidGlassRefractiveIndex = getFloatPref(CFSTR("SBCPU.LiquidGlass.RefractiveIndex"), 1.70f);
    liquidGlassQuality = getFloatPref(CFSTR("SBCPU.LiquidGlass.Quality"), 1.0f);
    NSDictionary *chargeStore = SBChargeRead();
    smartChargeEnable = [chargeStore[@"smartChargeEnable"] ?: @NO boolValue];
    smartChargeUpperLimit = [chargeStore[@"smartChargeUpperLimit"] ?: @80 integerValue];
    smartChargeLowerLimit = [chargeStore[@"smartChargeLowerLimit"] ?: @70 integerValue];
    chargeMarqueeStyle = MAX(0, MIN(1, [chargeStore[@"chargeMarqueeStyle"] ?: @0 integerValue]));
    smartChargeMode = [chargeStore[@"smartChargeMode"] ?: @0 integerValue];
    blockChargingEnable = [chargeStore[@"blockChargingEnable"] ?: @NO boolValue];
    blockPowerEnable = [chargeStore[@"blockPowerEnable"] ?: @NO boolValue];
    chargeKeepAC = [chargeStore[@"chargeKeepAC"] ?: @YES boolValue];
    chargeOverrideOBC = [chargeStore[@"chargeOverrideOBC"] ?: @NO boolValue];
    smartThermalChargeEnable = [chargeStore[@"smartThermalChargeEnable"] ?: @NO boolValue];
    /* Show effective mode, never the stale CFPreferences copy. */
    if ([chargeStore[@"chargeDayNightAutoEnable"] boolValue]) {
        NSInteger day = [chargeStore[@"chargeDayStartHour"] integerValue] * 60 + [chargeStore[@"chargeDayStartMinute"] integerValue];
        NSInteger night = [chargeStore[@"chargeNightStartHour"] integerValue] * 60 + [chargeStore[@"chargeNightStartMinute"] integerValue];
        NSDateComponents *dc = [[NSCalendar currentCalendar] components:(NSCalendarUnitHour | NSCalendarUnitMinute) fromDate:[NSDate date]];
        BOOL isDay = sb_charge_is_daytime((int)(dc.hour * 60 + dc.minute), (int)day, (int)night);
        smartChargeEnable = isDay;
    }
    smartThermalUpperC = MAX(35, MIN(60, (NSInteger)getFloatPref(CFSTR("smartThermalUpperC"), 42.0f)));
    smartThermalLowerC = MAX(25, MIN(55, (NSInteger)getFloatPref(CFSTR("smartThermalLowerC"), 38.0f)));
    if (smartThermalLowerC >= smartThermalUpperC) smartThermalLowerC = MAX(25, smartThermalUpperC - 1);
    glassDimOpacity = getFloatPref(CFSTR("glassDimOpacity"), 0.90f);
    if (glassDimOpacity < 0.40f) glassDimOpacity = 0.90f; // 旧版语义（白雾透明度）迁移为玻璃不透明度
    glassBlurRadius = getFloatPref(CFSTR("glassBlurRadius"), 50.0f);
    glassCardOpacity = getFloatPref(CFSTR("glassCardOpacity"), 0.80f);

    chargeBoostEnable = getBoolPref(CFSTR("chargeBoostEnable"), NO);
    forceFastChargeEnable = getBoolPref(CFSTR("forceFastChargeEnable"), NO);
    suppressPartRepairEnabled = getBoolPref(CFSTR("suppressPartRepair"), NO);

    notificationEnable = getBoolPref(CFSTR("notificationEnable"), YES);
    wechatEnable = getBoolPref(CFSTR("wechatEnable"), YES);
    qqEnable = getBoolPref(CFSTR("qqEnable"), YES);
    timEnable = getBoolPref(CFSTR("timEnable"), YES);
    hideContentOnLockScreen = getBoolPref(CFSTR("hideContentOnLockScreen"), NO);
    lockCleanupEnable = getBoolPref(CFSTR("lockCleanupEnable"), YES);
    lockCleanupWhitelist = [getArrayPref(CFSTR("lockCleanupWhitelist"), @[]) mutableCopy];
    if (!lockCleanupWhitelist) lockCleanupWhitelist = [NSMutableArray array];
    landscapeNotificationEnable = getBoolPref(CFSTR("landscapeNotificationEnable"), YES);
    notificationDuration = getIntPref(CFSTR("notificationDuration"), 5);

    if ([[NSProcessInfo processInfo].processName isEqualToString:@"SpringBoard"]) {
        applyVisibility();
        if (floatingView && wasTextOnly != floatingTextOnlyMode) handleTextOnlyModeTransition(wasTextOnly);
        if (floatingView && floatingTextOnlyMode) applyTextOnlyMode();
        if (showFps || collapsedDisplayMode == 1 || (floatingTextOnlyMode && textOnlyShowFPS)) {
            [[SBCPUFPSHelper sharedInstance] startMonitoring];
        } else {
            [[SBCPUFPSHelper sharedInstance] stopMonitoring];
        }
}
}

static void SavePreferencesAndNotify(void) {
    setBoolPref(CFSTR("isEnabled"), isEnabled);
    setBoolPref(CFSTR("autoCollapseEnable"), autoCollapseEnable);
    setIntPref(CFSTR("autoCollapseDelay"), autoCollapseDelay);
    setIntPref(CFSTR("collapsedDisplayMode"), collapsedDisplayMode);
    setBoolPref(CFSTR("autoExpandLandscape"), autoExpandLandscape);
    setBoolPref(CFSTR("compactLandscapeCapsule"), compactLandscapeCapsule);
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
    setBoolPref(CFSTR("statusBarDockEnable"), statusBarDockEnable);
    setIntPref(CFSTR("statusDockReturnDelay"), statusDockReturnDelay);
    setBoolPref(CFSTR("statusDockShowCPU"), statusDockShowCPU);
    setBoolPref(CFSTR("statusDockShowFPS"), statusDockShowFPS);
    setBoolPref(CFSTR("statusDockShowFrequency"), statusDockShowFrequency);
    setBoolPref(CFSTR("statusDockShowCurrent"), statusDockShowCurrent);
    setBoolPref(CFSTR("statusDockShowTemperature"), statusDockShowTemperature);
    setBoolPref(CFSTR("statusDockShowBattery"), statusDockShowBattery);
    setBoolPref(CFSTR("statusDockShowSIM1"), statusDockShowSIM1);
    setBoolPref(CFSTR("statusDockShowSIM2"), statusDockShowSIM2);
    setBoolPref(CFSTR("showCpuFrequency"), showCpuFrequency);
    setBoolPref(CFSTR("showFps"), showFps);
    setBoolPref(CFSTR("showSignalStrength"), showSignalStrength);
    setBoolPref(CFSTR("showBatteryPercent"), showBatteryPercent);
    setBoolPref(CFSTR("showBatteryTemperature"), showBatteryTemperature);
    setBoolPref(CFSTR("showBatteryCurrent"), showBatteryCurrent);
    setBoolPref(CFSTR("liquidGlassEnabled"), liquidGlassEnabled);
    setFloatPref(CFSTR("SBCPU.LiquidGlass.Strength"), liquidGlassStrength);
    setFloatPref(CFSTR("SBCPU.LiquidGlass.Refraction"), liquidGlassRefraction);
    setFloatPref(CFSTR("SBCPU.LiquidGlass.Thickness"), liquidGlassThickness);
    setFloatPref(CFSTR("SBCPU.LiquidGlass.Specular"), liquidGlassSpecular);
    setFloatPref(CFSTR("SBCPU.LiquidGlass.Dispersion"), liquidGlassDispersion);
    setFloatPref(CFSTR("SBCPU.LiquidGlass.Bezel"), liquidGlassBezel);
    setFloatPref(CFSTR("SBCPU.LiquidGlass.RefractiveIndex"), liquidGlassRefractiveIndex);
    setFloatPref(CFSTR("SBCPU.LiquidGlass.Quality"), liquidGlassQuality);
    setFloatPref(CFSTR("glassDimOpacity"), glassDimOpacity);
    setFloatPref(CFSTR("glassBlurRadius"), glassBlurRadius);
    setFloatPref(CFSTR("glassCardOpacity"), glassCardOpacity);
    setBoolPref(CFSTR("chargeBoostEnable"), chargeBoostEnable);
    setBoolPref(CFSTR("forceFastChargeEnable"), forceFastChargeEnable);
    setBoolPref(CFSTR("suppressPartRepair"), suppressPartRepairEnabled);
    setBoolPref(CFSTR("notificationEnable"), notificationEnable);
    setBoolPref(CFSTR("wechatEnable"), wechatEnable);
    setBoolPref(CFSTR("qqEnable"), qqEnable);
    setBoolPref(CFSTR("timEnable"), timEnable);
    setBoolPref(CFSTR("hideContentOnLockScreen"), hideContentOnLockScreen);
    setBoolPref(CFSTR("lockCleanupEnable"), lockCleanupEnable);
    setArrayPref(CFSTR("lockCleanupWhitelist"), lockCleanupWhitelist);
    setBoolPref(CFSTR("landscapeNotificationEnable"), landscapeNotificationEnable);
    setIntPref(CFSTR("notificationDuration"), notificationDuration);

    CFPreferencesSynchronize(kPrefAppID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);

    if (showFps || collapsedDisplayMode == 1 || (floatingTextOnlyMode && textOnlyShowFPS)) {
        [[SBCPUFPSHelper sharedInstance] startMonitoring];
    } else {
        [[SBCPUFPSHelper sharedInstance] stopMonitoring];
    }
CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), kPrefChangedNotification, NULL, NULL, YES);


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
    // Match daemon IOPMPowerSource CurrentCapacity; raw mAh / nominal mAh
    // can differ from the percentage actually used for 60/55 decisions.
    io_service_t service = IOServiceGetMatchingService(0, IOServiceMatching("IOPMPowerSource"));
    int percent = -1;
    if (service != IO_OBJECT_NULL) {
        CFTypeRef value = IORegistryEntryCreateCFProperty(service, CFSTR("CurrentCapacity"), kCFAllocatorDefault, 0);
        if (value && CFGetTypeID(value) == CFNumberGetTypeID())
            CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &percent);
        if (value) CFRelease(value);
        IOObjectRelease(service);
    }
    if (percent >= 0 && percent <= 100) return percent;
    [UIDevice currentDevice].batteryMonitoringEnabled = YES;
    float level = [UIDevice currentDevice].batteryLevel;
    if (level >= 0) return (NSInteger)lrintf(level * 100);
    return -1;
}

// 智能停充（V4.22 重构）：本函数不再执行任何 SMC 决策/写入。
// 充电控制全部收口到 SBCPUChargeDaemon（root, 事件驱动, 独立于浮窗）。
// 这里只在设置变化/启动时把配置下发给 daemon，并读取 daemon 状态用于回显。
static void updateSmartCharge(void) {
    // 配置有变化 → 下发 daemon 并立即重新决策
    sbSMCRedecide();
}

// ==========================================================
// 🔌 AppleSMC 控制层（V4.21）：经 SBCPUChargeDaemon(root daemon) 写 AppleSMC
// SpringBoard 无 com.apple.private.applesmc.user-access entitlement，无法直接打开 AppleSMC；
// 故 SMC 读写全部走 unix socket 转发给以 root 运行的 SBCPUChargeDaemon（launchd + ldid 签名）。
// ==========================================================
static BOOL gSMCAvailable = NO;
static BOOL gSMCChecked = NO;

enum {
    kSBCmdPing      = 1,
    kSBCmdSetCharge = 2,
    kSBCmdSetPower  = 3,
    kSBCmdGetCharge = 4,
    kSBCmdGetPower  = 5,
    kSBCmdSetLimits = 6,
    kSBCmdGetLimits = 7,
    kSBCmdRedecide  = 8,
    kSBCmdGetStatus = 9,
    kSBCmdStop      = 10
};

#define SB_SOCKET_PATH "/var/mobile/Library/Preferences/sbcpu_charge.sock"
#define SB_MAGIC 0x53424350
#define SB_DAEMON_VERSION 5

// daemon 返回的 result 语义（与 SBCPUChargeProtocol.h SB_RESULT_* 对齐）
enum {
    kSBResultOK                = 0,
    kSBResultBusy              = 1,
    kSBResultOBCTaken          = 2,
    kSBResultSMCUnavailable    = 3,
    kSBResultNoExternalPower   = 4,
    kSBResultUnsupported       = 5,
    kSBResultIOError           = 6
};

typedef struct {
    uint32_t magic;
    uint8_t  cmd;
    uint8_t  value;
    uint16_t pad;
} sb_cmd_t;

typedef struct {
    uint32_t magic;
    int32_t  result;
    uint8_t  value;
    uint8_t  pad[3];
} sb_resp_t;

// 尝试拉起 SBCPUChargeDaemon（兼容 roothide /var/jb 与 rootful 路径）
// daemon 以 root 运行才有 AppleSMC 权限；这里通过 launchctl 拉起
static void sbSMCLoadDaemon(void) {
    @try {
        NSArray *daemonPaths = @[
            @"/var/jb/usr/libexec/SBCPUChargeDaemon",
            @"/usr/libexec/SBCPUChargeDaemon"
        ];
        NSString *daemonPath = nil;
        for (NSString *p in daemonPaths) {
            if ([[NSFileManager defaultManager] isExecutableFileAtPath:p]) {
                daemonPath = p;
                break;
            }
        }
        if (!daemonPath) return;

        NSArray *plistPaths = @[
            @"/var/jb/Library/LaunchDaemons/com.sbcpu.charged.plist",
            @"/Library/LaunchDaemons/com.sbcpu.charged.plist"
        ];
        NSString *plistPath = nil;
        for (NSString *p in plistPaths) {
            if ([[NSFileManager defaultManager] fileExistsAtPath:p]) {
                plistPath = p;
                break;
            }
        }
        if (!plistPath) return;

        // 用 launchctl 加载（rootful: /bin/launchctl；roothide: /var/jb/usr/bin/launchctl）
        NSArray *launchctls = @[
            @"/var/jb/usr/bin/launchctl",
            @"/usr/bin/launchctl",
            @"/bin/launchctl"
        ];
        NSString *launchctl = nil;
        for (NSString *p in launchctls) {
            if ([[NSFileManager defaultManager] isExecutableFileAtPath:p]) {
                launchctl = p;
                break;
            }
        }
        if (!launchctl) return;

        // 用 posix_spawn 调 launchctl 卸载旧实例并加载（比 NSTask 稳定）
        char *argv1[] = {(char *)launchctl.UTF8String, (char *)"unload", (char *)plistPath.UTF8String, NULL};
        pid_t pid1 = 0;
        posix_spawn(&pid1, argv1[0], NULL, NULL, argv1, NULL);
        if (pid1 > 0) { int st = 0; waitpid(pid1, &st, 0); }
        char *argv2[] = {(char *)launchctl.UTF8String, (char *)"load", (char *)"-w", (char *)plistPath.UTF8String, NULL};
        pid_t pid2 = 0;
        posix_spawn(&pid2, argv2[0], NULL, NULL, argv2, NULL);
        if (pid2 > 0) { int st2 = 0; waitpid(pid2, &st2, 0); }
    } @catch (NSException *e) {}
}

static int sbSMCConnect(void) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, SB_SOCKET_PATH, sizeof(addr.sun_path) - 1);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

// SOCK_STREAM 不保证一次读写完整结构体：全量读写，避免偶发通信失败
static bool sbSMCReadFull(int fd, void *buf, size_t len) {
    size_t done = 0;
    while (done < len) {
        ssize_t n = read(fd, (uint8_t *)buf + done, len - done);
        if (n <= 0) {
            if (n < 0 && errno == EINTR) continue;
            return false;
        }
        done += (size_t)n;
    }
    return true;
}

static bool sbSMCWriteFull(int fd, const void *buf, size_t len) {
    size_t done = 0;
    while (done < len) {
        ssize_t n = write(fd, (const uint8_t *)buf + done, len - done);
        if (n <= 0) {
            if (n < 0 && errno == EINTR) continue;
            return false;
        }
        done += (size_t)n;
    }
    return true;
}

static IOReturn sbSMCRequest(uint8_t cmd, uint8_t value, uint8_t *outValue) {
    int fd = sbSMCConnect();
    if (fd < 0) return kIOReturnNotOpen;
    sb_cmd_t c = {0};
    c.magic = SB_MAGIC;
    c.cmd = cmd;
    c.value = value;
    if (!sbSMCWriteFull(fd, &c, sizeof(c))) {
        close(fd);
        return kIOReturnIOError;
    }
    sb_resp_t r = {0};
    bool ok = sbSMCReadFull(fd, &r, sizeof(r));
    close(fd);
    if (!ok || r.magic != SB_MAGIC)
        return kIOReturnIOError;
    if (outValue) *outValue = r.value;
    return (IOReturn)r.result;
}

static IOReturn sbSMCInit(void) {
    if (gSMCChecked && gSMCAvailable) return kIOReturnSuccess;
    int fd = sbSMCConnect();
    if (fd < 0) {
        // daemon 未运行：尝试拉起一次，等待后重试
        sbSMCLoadDaemon();
        usleep(600 * 1000);
        fd = sbSMCConnect();
    }
    if (fd < 0) {
        gSMCChecked = YES;
        gSMCAvailable = NO;
        return kIOReturnNotOpen;
    }
    close(fd);
    gSMCChecked = YES;
    gSMCAvailable = YES;
    return kIOReturnSuccess;
}

// V4.26 — 智能充电配置载荷（与 daemon 协议一致）
typedef struct {
    uint8_t  smartChargeEnabled;
    uint8_t  chargeLimitEnabled;
    uint8_t  upperLimit;
    uint8_t  lowerLimit;
    uint8_t  drainMode;          // bit0=keepAC bit1=overrideOBC
    uint8_t  manualChargeBlock;
    uint8_t  manualPowerBlock;
    uint8_t  scheduleEnabled;
    uint8_t  scheduleStartHour;
    uint8_t  scheduleStartMinute;
    uint8_t  scheduleStage2Hour;
    uint8_t  scheduleStage2Minute;
    uint8_t  scheduleStage3Hour;
    uint8_t  scheduleStage3Minute;
    uint8_t  smartThermalEnabled;
    uint8_t  thermalUpperC;
    uint8_t  thermalLowerC;
} sb_limits_t;

typedef struct {
    uint8_t  engineState;
    uint8_t  batteryPercent;
    uint8_t  chargeBlocked;
    uint8_t  powerBlocked;
    uint8_t  daemonRunning;
    uint8_t  smcAvailable;
    uint8_t  charging;
    uint8_t  wireless;
    uint8_t  upperLimit;
    uint8_t  lowerLimit;
    uint8_t  obcTaken;
    uint8_t  version;          // daemon 协议版本（SB_DAEMON_VERSION）
    int32_t  lastSMCError;     // 最近一次 SMC 调用原始 IOReturn（0=无错误）
} sb_status_t;

// 下发智能充电配置给 daemon（保存到偏好 + 立即 REDECIDE）
// 立即重新决策（配置变化后调用）
static IOReturn sbSMCRedecide(void) {
    uint8_t v = 0;
    return sbSMCRequest(kSBCmdRedecide, 0, &v);
}

// 读 daemon 状态（引擎状态机）
static BOOL sbSMCGetStatus(sb_status_t *out) {
    if (!out) return NO;
    int fd = sbSMCConnect();
    if (fd < 0) return NO;
    sb_cmd_t c = {0};
    c.magic = SB_MAGIC;
    c.cmd = kSBCmdGetStatus;
    if (!sbSMCWriteFull(fd, &c, sizeof(c))) { close(fd); return NO; }
    sb_resp_t r = {0};
    if (!sbSMCReadFull(fd, &r, sizeof(r)) || r.magic != SB_MAGIC) { close(fd); return NO; }
    bool ok = sbSMCReadFull(fd, out, sizeof(sb_status_t));
    close(fd);
    return ok;
}

static IOReturn sbSMCSetChargeBlock(BOOL inhibit, BOOL overrideOBC) {
    (void)overrideOBC; // daemon 侧固定按 overrideOBC=NO 的安全路径执行
    uint8_t v = 0;
    return sbSMCRequest(kSBCmdSetCharge, inhibit ? 1 : 0, &v);
}

static IOReturn sbSMCSetPowerBlock(BOOL inhibit, BOOL overrideOBC) {
    (void)overrideOBC;
    uint8_t v = 0;
    return sbSMCRequest(kSBCmdSetPower, inhibit ? 1 : 0, &v);
}

static BOOL sbSMCGetChargeBlocked(void) {
    uint8_t v = 0;
    if (sbSMCRequest(kSBCmdGetCharge, 0, &v) == kIOReturnSuccess)
        return v != 0;
    return NO;
}

static BOOL sbSMCGetPowerBlocked(void) {
    uint8_t v = 0;
    if (sbSMCRequest(kSBCmdGetPower, 0, &v) == kIOReturnSuccess)
        return v != 0;
    return NO;
}

// V4.23 — 充电操作失败的统一诊断文案：区分 daemon 未运行 / 旧版未加载 / SMC 不可用 / 真实 IOKit 错误码
static NSString *sbChargeErrorMessage(IOReturn r) {
    sb_status_t st;
    BOOL alive = sbSMCGetStatus(&st);
    if (!alive) {
        return @"充电守护进程未运行。请注销(Respring)或重启手机；若反复出现，请在 NewTerm(root) 运行随附的诊断命令。";
    }
    if (st.version == 0 || st.version < SB_DAEMON_VERSION) {
        return [NSString stringWithFormat:@"充电守护进程仍是旧版本(v%d)，新版尚未加载。请注销(Respring)或重启手机后再试。",
                st.version ? (int)st.version : 1];
    }
    if (!st.smcAvailable) {
        if (st.lastSMCError != 0)
            return [NSString stringWithFormat:@"AppleSMC 无法打开（IOKit 0x%08x）。守护进程可能未以 root 被 launchd 托管，请重启手机。",
                    (unsigned)st.lastSMCError];
        return @"AppleSMC 不可用，守护进程未能访问电源管理，请重启手机。";
    }
    switch (r) {
        case kSBResultNoExternalPower:
            return @"未检测到外部电源，请先连接有线充电器后再操作。";
        case kSBResultOBCTaken:
            return @"系统「优化电池充电」正在接管(OBC)，当前未强制覆盖。请关闭系统优化充电，或开启「覆盖 OBC」后再试。";
        case kSBResultUnsupported:
            return @"当前充电方式（可能为无线充电）暂不支持，请使用有线充电器。";
        case kSBResultBusy:
            return @"电源管理正忙，请稍后再试。";
        case kSBResultSMCUnavailable:
            return st.lastSMCError
                ? [NSString stringWithFormat:@"AppleSMC 不可用（IOKit 0x%08x），请重启手机。", (unsigned)st.lastSMCError]
                : @"AppleSMC 不可用，请重启手机。";
        default:
            if (st.lastSMCError != 0)
                return [NSString stringWithFormat:@"SMC 写入失败（IOKit 0x%08x）。请确认连接的是有线充电器；若反复出现请重启手机。",
                        (unsigned)st.lastSMCError];
            return [NSString stringWithFormat:@"操作失败（代码 %d），请确认充电器已连接后重试。", (int)r];
    }
}

static NSString *sbSMCAvailableString(void) __attribute__((unused));
static NSString *sbSMCAvailableString(void) {
    if (sbSMCInit() != kIOReturnSuccess)
        return @"SMC 守护进程未运行（充电控制不可用）";
    return @"SMC 正常（硬件级控制可用）";
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
    // Reuse existing registry reads; ETA never creates its own IO/socket timer.
    static NSMutableArray *etaHistory = nil;
    static dispatch_once_t etaOnce;
    dispatch_once(&etaOnce, ^{ etaHistory = [NSMutableArray array]; });
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
            if (floatingTextOnlyMode && textOnlyShowCurrent)
                dict[@"SBCPUTextOnlyCurrentMA"] = SBCPUTextOnlyBatteryCurrent(pDict);
            dict[@"Voltage"] = pDict[@"Voltage"];
            dict[@"Manufacturer"] = SBCPUBatteryManufacturerFromProperties(pDict);
            dict[@"AvgTimeToFull"] = pDict[@"AvgTimeToFull"];
            NSDictionary *etaSnapshot = SBCPUBatterySnapshot(pDict, [NSProcessInfo processInfo].systemUptime);
            @synchronized (etaHistory) {
                SBCPUBatteryAppendSample(etaHistory, etaSnapshot);
                dict[@"SBCPUEtaSnapshot"] = etaSnapshot;
                dict[@"SBCPUEtaHistory"] = [etaHistory copy];
            }
            if (pDict[@"AdapterDetails"]) {
                NSDictionary *ad = pDict[@"AdapterDetails"];
                dict[@"Watts"] = ad[@"Watts"];
                dict[@"ChargerType"] = ad[@"Description"] ?: ad[@"Name"];
                dict[@"AdapterName"] = ad[@"Name"] ?: ad[@"Description"];
                dict[@"AdapterSerial"] = ad[@"SerialString"];
                if (ad[@"UsbHvcMenu"]) dict[@"UsbHvcMenu"] = ad[@"UsbHvcMenu"];
            }
            double volts = [dict[@"Voltage"] doubleValue] / 1000.0;
            double amps = [dict[@"Amperage"] doubleValue] / 1000.0;
            if (amps < 0) amps = -amps;
            dict[@"CalculatedWatts"] = @(volts * amps);
            CFRelease(prop);
        }
        IOObjectRelease(service);
    }
    if (!dict[@"SBCPUEtaSnapshot"]) {
        @synchronized (etaHistory) { [etaHistory removeAllObjects]; }
    }
    return dict;
}

// ========== 充电器输入功率 & 停充验证（V4.15.0，移植 MiniWatts 数据层思路） ==========
// HID 电源传感器（IOHIDEventSystemClient 私有 API，dlsym 运行时解析，不链接 IOKit 头）
// 传感器命名（因机型而异）：Charger VQ0u=USB输入电压, IQ0u=USB输入电流, IQ0B=进入电池电流
static CFTypeRef gHIDClient = NULL;
static void (*gHIDSetMatching)(CFTypeRef, CFDictionaryRef) = NULL;
static CFArrayRef (*gHIDCopyServices)(CFTypeRef) = NULL;
static CFTypeRef (*gHIDCopyProperty)(CFTypeRef, CFStringRef) = NULL;
static CFTypeRef (*gHIDCopyEvent)(CFTypeRef, int64_t, int32_t, int64_t) = NULL;
static double (*gHIDGetFloat)(CFTypeRef, int32_t) = NULL;

static void initHIDClient(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
        if (!h) return;
        CFTypeRef (*createFn)(CFAllocatorRef) = (CFTypeRef (*)(CFAllocatorRef))dlsym(h, "IOHIDEventSystemClientCreate");
        gHIDSetMatching = (void (*)(CFTypeRef, CFDictionaryRef))dlsym(h, "IOHIDEventSystemClientSetMatching");
        gHIDCopyServices = (CFArrayRef (*)(CFTypeRef))dlsym(h, "IOHIDEventSystemClientCopyServices");
        gHIDCopyProperty = (CFTypeRef (*)(CFTypeRef, CFStringRef))dlsym(h, "IOHIDServiceClientCopyProperty");
        gHIDCopyEvent = (CFTypeRef (*)(CFTypeRef, int64_t, int32_t, int64_t))dlsym(h, "IOHIDServiceClientCopyEvent");
        gHIDGetFloat = (double (*)(CFTypeRef, int32_t))dlsym(h, "IOHIDEventGetFloatValue");
        if (createFn) gHIDClient = createFn(kCFAllocatorDefault);
    });
}

// 枚举 HID 电源传感器（usage page 0xff08），返回 {传感器名: 数值}
static NSDictionary *getHIDPowerSensors(void) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    initHIDClient();
    if (!gHIDClient || !gHIDSetMatching || !gHIDCopyServices || !gHIDCopyEvent || !gHIDGetFloat) return result;
    @try {
        NSNumber *usagePage = @(0xff08);
        const void *keysArr[] = { CFSTR("PrimaryUsagePage") };
        const void *valuesArr[] = { (__bridge const void *)usagePage };
        CFDictionaryRef match = CFDictionaryCreate(kCFAllocatorDefault, keysArr, valuesArr, 1,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        if (!match) return result;
        gHIDSetMatching(gHIDClient, match);
        CFRelease(match);
        CFArrayRef services = gHIDCopyServices(gHIDClient);
        if (!services) return result;
        for (CFIndex i = 0; i < CFArrayGetCount(services); i++) {
            CFTypeRef service = CFArrayGetValueAtIndex(services, i);
            if (!service) continue;
            NSString *name = @"?";
            CFTypeRef nameRef = gHIDCopyProperty(service, CFSTR("Product"));
            if (nameRef) {
                name = (__bridge NSString *)nameRef;
                CFRelease(nameRef);
            }
            CFTypeRef event = gHIDCopyEvent(service, 25 /*kIOHIDEventTypePower*/, 0, 0);
            if (!event) continue;
            double value = gHIDGetFloat(event, 25 << 16);
            CFRelease(event);
            if (isnan(value) || isinf(value)) continue;
            result[name] = @(value);
        }
        CFRelease(services);
    } @catch (id e) {}
    return result;
}

// 充电器输入功率（W）= USB 口电压 × 电流；0 表示读不到
static double getChargerInputPower(void) {
    NSDictionary *sensors = getHIDPowerSensors();
    if (sensors.count == 0) return 0;
    double voltage = 0, current = 0;
    for (NSString *k in sensors) {
        if ([k localizedCaseInsensitiveContainsString:@"VQ0u"]) voltage = [sensors[k] doubleValue];
        else if ([k localizedCaseInsensitiveContainsString:@"IQ0u"]) current = [sensors[k] doubleValue];
    }
    if (voltage > 0.5 && current > 0) return voltage * current;
    return 0;
}

// 进入电池的电流（A），优先 HID IQ0B，兜底 IOKit Amperage
static double getChargerBatteryCurrentA(void) {
    NSDictionary *sensors = getHIDPowerSensors();
    for (NSString *k in sensors) {
        if ([k localizedCaseInsensitiveContainsString:@"IQ0B"]) {
            return fabs([sensors[k] doubleValue]);
        }
    }
    NSDictionary *bat = getRealBatteryDetails();
    return fabs([bat[@"Amperage"] doubleValue]) / 1000.0;
}

// 适配器信息字符串：名称 · 额定功率 · PD 档位
static NSString *getAdapterInfoString(void) {
    NSDictionary *bat = getRealBatteryDetails();
    NSNumber *watts = bat[@"Watts"];
    NSMutableString *s = [NSMutableString string];
    if ([watts isKindOfClass:[NSNumber class]] && [watts doubleValue] > 0) {
        [s appendFormat:@"%ldW", (long)[watts integerValue]];
    }
    NSArray *menu = bat[@"UsbHvcMenu"];
    if ([menu isKindOfClass:[NSArray class]] && menu.count > 0) {
        NSDictionary *p0 = menu.firstObject;
        NSInteger mv = [p0[@"MaxVoltage"] integerValue];
        NSInteger ma = [p0[@"MaxCurrent"] integerValue];
        if (mv > 0 && ma > 0) {
            if (s.length) [s appendString:@" · "];
            [s appendFormat:@"PD %.1fV/%.2fA", mv / 1000.0, ma / 1000.0];
        }
    }
    // 名称由"电池充电类型"行显示，避免与 PD 档位挤在一行被截断
    return s.length > 0 ? s : @"未连接充电器";
}

// 充电器功率利用率：实际输入功率 ÷ 额定功率（0~100，-1 表示数据不足）
static double getChargerUtilisationPercent(void) {
    NSDictionary *bat = getRealBatteryDetails();
    NSNumber *watts = bat[@"Watts"];
    if (![watts isKindOfClass:[NSNumber class]] || [watts doubleValue] <= 0) return -1;
    double inputW = getChargerInputPower();
    if (inputW <= 0.1) return -1;
    double rated = [watts doubleValue];
    if (rated <= 0) return -1;
    return MIN(inputW / rated * 100.0, 100.0);
}

// 停充实测验证：外部连接 + 未在充电 + 电量 50~99% + 电池电流 < 0.3A → 判定已停充/保持
static BOOL getExternalConnectedState(void) {
    BOOL external = NO;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"));
    if (service) {
        CFMutableDictionaryRef prop = NULL;
        if (IORegistryEntryCreateCFProperties(service, &prop, kCFAllocatorDefault, 0) == KERN_SUCCESS && prop) {
            NSDictionary *pDict = (__bridge NSDictionary *)prop;
            external = [pDict[@"ExternalConnected"] boolValue];
            CFRelease(prop);
        }
        IOObjectRelease(service);
    }
    return external;
}

static BOOL isChargingOnHold(void) {
    @try {
        BOOL external = getExternalConnectedState();
        if (!external) return NO;
        BOOL charging = isChargingInternal();
        if (charging) return NO;
        NSInteger percent = getBatteryPercentForSmartCharge();
        if (percent < 50 || percent >= 100) return NO;
        double currentA = getChargerBatteryCurrentA();
        return currentA < 0.3;
    } @catch (id e) { return NO; }
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

// ========== 无线充电功率 & 充电会话记录器（V4.16.0，移植 MiniWatts PowerSnapshot/ChargeSession/EnergyAccumulator） ==========
// 无线充电功率（W）：MagSafe 线圈电压×电流（Charger VQ1u × IQ1u）
static double getWirelessChargePower(void) {
    NSDictionary *sensors = getHIDPowerSensors();
    double v = 0, c = 0;
    for (NSString *k in sensors) {
        if ([k localizedCaseInsensitiveContainsString:@"VQ1u"]) v = [sensors[k] doubleValue];
        else if ([k localizedCaseInsensitiveContainsString:@"IQ1u"]) c = [sensors[k] doubleValue];
    }
    if (v > 1 && c > 0) return v * c;
    return 0;
}

// ---- 充电会话：插电开始采样（每 5 秒积分），拔电归档，JSON 持久化最多 60 条 ----
static NSString *chargeSessionsFilePath(void) {
    return @"/var/mobile/Library/Preferences/com.sbcpu.floating.charge-sessions.json";
}
static NSMutableArray *gChargeSessions = nil;
static NSMutableDictionary *gActiveSession = nil;
static BOOL gWasExternalCharging = NO;
static double gSessInputWh = 0, gSessBatteryWh = 0, gSessBatteryMah = 0;
static double gSessPeakInputW = 0, gSessPeakBattW = 0, gSessPeakTemp = -200;
static double gSessLastInputW = -1, gSessLastBattW = -1, gSessLastBattA = -1;
static NSTimeInterval gSessLastSampleTime = 0;
static NSTimeInterval gSessStartTime = 0;
static NSInteger gSessStartPercent = -1;
static BOOL gSessWireless = NO;
static NSInteger gSessThrottledSeconds = 0;

static void saveChargeSessionsToDisk(void) {
    @try {
        NSData *data = [NSJSONSerialization dataWithJSONObject:(gChargeSessions ?: @[]) options:0 error:nil];
        [data writeToFile:chargeSessionsFilePath() atomically:YES];
    } @catch (id e) {}
}

static void loadChargeSessionsFromDisk(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gChargeSessions = [NSMutableArray array];
        NSData *data = [NSData dataWithContentsOfFile:chargeSessionsFilePath()];
        if (!data) return;
        NSArray *arr = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([arr isKindOfClass:[NSArray class]]) {
            gChargeSessions = [NSMutableArray arrayWithArray:arr];
            if (gChargeSessions.count > 60) {
                [gChargeSessions removeObjectsInRange:NSMakeRange(60, gChargeSessions.count - 60)];
            }
        }
    });
}

static NSString *formatSessionDurationStr(NSTimeInterval secs) {
    if (secs < 60) return [NSString stringWithFormat:@"%ld秒", (long)secs];
    NSInteger m = (NSInteger)(secs / 60);
    if (m < 60) return [NSString stringWithFormat:@"%ld分钟", (long)m];
    return [NSString stringWithFormat:@"%ldh%02ldm", (long)(m / 60), (long)(m % 60)];
}

// 每秒调用：状态机（检测插拔）+ 梯形积分采样 + 拔电归档
static void chargeSessionTick(void) {
    loadChargeSessionsFromDisk();
    BOOL external = getExternalConnectedState();
    if (external && !gWasExternalCharging) {
        // 插电：开启新会话
        gActiveSession = [NSMutableDictionary dictionary];
        gSessInputWh = gSessBatteryWh = gSessBatteryMah = 0;
        gSessPeakInputW = gSessPeakBattW = 0;
        gSessPeakTemp = -200;
        gSessLastInputW = gSessLastBattW = gSessLastBattA = -1;
        gSessLastSampleTime = 0;
        gSessStartTime = [NSDate timeIntervalSinceReferenceDate];
        gSessStartPercent = (NSInteger)([UIDevice currentDevice].batteryLevel * 100);
        if (gSessStartPercent < 0) gSessStartPercent = 0;
        gSessWireless = getWirelessChargePower() > 0.5;
        gSessThrottledSeconds = 0;
    }
    if (external && gActiveSession) {
        double inputW = getChargerInputPower();
        NSDictionary *bat = getRealBatteryDetails();
        double battW = [bat[@"CalculatedWatts"] doubleValue];
        if (battW < 0) battW = 0;
        double battA = fabs([bat[@"Amperage"] doubleValue]) / 1000.0;
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        if (gSessLastSampleTime > 0) {
            double dt = now - gSessLastSampleTime;
            if (dt > 0 && dt <= 10) {
                double hours = dt / 3600.0;
                if (gSessLastInputW >= 0) gSessInputWh += (gSessLastInputW + inputW) / 2.0 * hours;
                if (gSessLastBattW >= 0) gSessBatteryWh += (gSessLastBattW + battW) / 2.0 * hours;
                if (gSessLastBattA >= 0) gSessBatteryMah += (gSessLastBattA + battA) / 2.0 * hours * 1000.0;
            }
        }
        gSessLastInputW = inputW;
        gSessLastBattW = battW;
        gSessLastBattA = battA;
        gSessLastSampleTime = now;
        if (inputW > gSessPeakInputW) gSessPeakInputW = inputW;
        if (battW > gSessPeakBattW) gSessPeakBattW = battW;
        double temp = getBatteryTemperatureInternal();
        if (temp > gSessPeakTemp) gSessPeakTemp = temp;
        if (NSProcessInfo.processInfo.thermalState == NSProcessInfoThermalStateSerious ||
            NSProcessInfo.processInfo.thermalState == NSProcessInfoThermalStateCritical) {
            gSessThrottledSeconds++;
        }
    }
    if (!external && gWasExternalCharging && gActiveSession) {
        // 拔电：归档
        NSInteger endPercent = (NSInteger)([UIDevice currentDevice].batteryLevel * 100);
        if (endPercent < 0) endPercent = 0;
        double duration = [NSDate timeIntervalSinceReferenceDate] - gSessStartTime;
        gActiveSession[@"start"] = @(gSessStartTime);
        gActiveSession[@"duration"] = @(duration);
        gActiveSession[@"startPercent"] = @(gSessStartPercent);
        gActiveSession[@"endPercent"] = @(endPercent);
        gActiveSession[@"inputWh"] = @(gSessInputWh);
        gActiveSession[@"batteryWh"] = @(gSessBatteryWh);
        gActiveSession[@"batteryMah"] = @(gSessBatteryMah);
        gActiveSession[@"peakInputW"] = @(gSessPeakInputW);
        gActiveSession[@"peakBattW"] = @(gSessPeakBattW);
        gActiveSession[@"peakTemp"] = (gSessPeakTemp > -100) ? @(gSessPeakTemp) : (id)[NSNull null];
        gActiveSession[@"wireless"] = @(gSessWireless);
        gActiveSession[@"throttledSeconds"] = @(gSessThrottledSeconds);
        [gChargeSessions insertObject:gActiveSession atIndex:0];
        if (gChargeSessions.count > 60) {
            [gChargeSessions removeObjectsInRange:NSMakeRange(60, gChargeSessions.count - 60)];
        }
        saveChargeSessionsToDisk();
        gActiveSession = nil;
    }
    gWasExternalCharging = external;
}

// 本次充入字符串（详情面板/浮窗）
static NSString *getCurrentChargeAmountString(void) {
    if (!gActiveSession && !gWasExternalCharging) return @"未在充电";
    double duration = [NSDate timeIntervalSinceReferenceDate] - gSessStartTime;
    if (duration < 5) return @"充电中...";
    NSMutableString *s = [NSMutableString string];
    if (gSessBatteryMah >= 1) [s appendFormat:@"%.0fmAh", gSessBatteryMah];
    if (gSessInputWh >= 0.001) {
        if (s.length) [s appendString:@" · "];
        [s appendFormat:@"输入%.1fWh", gSessInputWh];
    }
    if (gSessInputWh >= 0.001 && gSessBatteryWh >= 0.001) {
        double loss = MAX(gSessInputWh - gSessBatteryWh, 0);
        [s appendFormat:@" · 损耗%.1fWh", loss];
    }
    return s.length > 0 ? s : @"充电中...";
}

static void clearChargeSessions(void) {
    loadChargeSessionsFromDisk();
    [gChargeSessions removeAllObjects];
    saveChargeSessionsToDisk();
}

static void onChargeHistoryClearRequested(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    if ([[NSProcessInfo processInfo].processName isEqualToString:@"SpringBoard"]) {
        clearChargeSessions();
    }
}

// 本机时间格式化（充电历史用）
static NSString *formatSessionStartTime(NSTimeInterval secs) {
    NSDate *d = [NSDate dateWithTimeIntervalSinceReferenceDate:secs];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"MM-dd HH:mm";
    return [fmt stringFromDate:d];
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

// 当前频率 = IOReport P-State residency × AppleARMIODevice DVFS 表。
typedef struct IOReportSubscriptionRef *SBIOReportSubscription;
typedef CFMutableDictionaryRef (*SBIOReportCopyChannelsFn)(NSString *, NSString *, uint64_t, uint64_t, uint64_t);
typedef SBIOReportSubscription (*SBIOReportCreateSubscriptionFn)(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
typedef CFDictionaryRef (*SBIOReportCreateSamplesFn)(SBIOReportSubscription, CFMutableDictionaryRef, CFTypeRef);
typedef CFDictionaryRef (*SBIOReportCreateSamplesDeltaFn)(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
typedef int (*SBIOReportIterateFn)(CFDictionaryRef, int (^)(CFDictionaryRef));
typedef NSString *(*SBIOReportChannelNameFn)(CFDictionaryRef);
typedef NSString *(*SBIOReportGroupFn)(CFDictionaryRef);
typedef NSString *(*SBIOReportSubGroupFn)(CFDictionaryRef);
typedef int (*SBIOReportStateCountFn)(CFDictionaryRef);
typedef uint64_t (*SBIOReportStateResidencyFn)(CFDictionaryRef, int);
typedef NSString *(*SBIOReportStateNameFn)(CFDictionaryRef, int);

static struct {
    void *handle;
    SBIOReportCopyChannelsFn copyChannels;
    SBIOReportCreateSubscriptionFn createSubscription;
    SBIOReportCreateSamplesFn createSamples;
    SBIOReportCreateSamplesDeltaFn createDelta;
    SBIOReportIterateFn iterate;
    SBIOReportChannelNameFn channelName;
    SBIOReportGroupFn group;
    SBIOReportSubGroupFn subgroup;
    SBIOReportStateCountFn stateCount;
    SBIOReportStateNameFn stateName;
    SBIOReportStateResidencyFn stateResidency;
    CFMutableDictionaryRef subscribedChannels;
    NSArray *ecpuDVFS;
    NSArray *pcpuDVFS;
    SBIOReportSubscription subscription;
    CFTypeRef previousSample;
    BOOL ready;
} gIOReport = {0};

static NSArray *readDVFSTable(CFStringRef propertyKey) {
    io_iterator_t iterator = IO_OBJECT_NULL;
    CFMutableDictionaryRef matching = IOServiceMatching("AppleARMIODevice");
    if (!matching || IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) != KERN_SUCCESS) return @[];
    NSArray *result = @[];
    io_service_t service = IOIteratorNext(iterator);
    while (service) {
        CFTypeRef value = IORegistryEntryCreateCFProperty(service, propertyKey, kCFAllocatorDefault, 0);
        if (value && CFGetTypeID(value) == CFDataGetTypeID()) {
            CFDataRef data = (CFDataRef)value;
            CFIndex length = CFDataGetLength(data);
            const UInt8 *bytes = CFDataGetBytePtr(data);
            NSMutableArray *table = [NSMutableArray arrayWithObject:@0.0];
            for (CFIndex offset = 0; offset + 8 <= length; offset += 8) {
                uint32_t hz = 0;
                memcpy(&hz, bytes + offset, sizeof(hz));
                double mhz = (double)hz / 1000000.0;
                [table addObject:(mhz > 0.0 && mhz < 6000.0) ? @(mhz) : @0.0];
            }
            if (table.count > 1) result = [table copy];
        }
        if (value) CFRelease(value);
        IOObjectRelease(service);
        if (result.count > 1) break;
        service = IOIteratorNext(iterator);
    }
    IOObjectRelease(iterator);
    return result;
}

static void initIOReportFrequency(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gIOReport.handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY);
        if (!gIOReport.handle) return;
        gIOReport.copyChannels = (SBIOReportCopyChannelsFn)dlsym(gIOReport.handle, "IOReportCopyChannelsInGroup");
        gIOReport.createSubscription = (SBIOReportCreateSubscriptionFn)dlsym(gIOReport.handle, "IOReportCreateSubscription");
        gIOReport.createSamples = (SBIOReportCreateSamplesFn)dlsym(gIOReport.handle, "IOReportCreateSamples");
        gIOReport.createDelta = (SBIOReportCreateSamplesDeltaFn)dlsym(gIOReport.handle, "IOReportCreateSamplesDelta");
        gIOReport.iterate = (SBIOReportIterateFn)dlsym(gIOReport.handle, "IOReportIterate");
        gIOReport.channelName = (SBIOReportChannelNameFn)dlsym(gIOReport.handle, "IOReportChannelGetChannelName");
        gIOReport.group = (SBIOReportGroupFn)dlsym(gIOReport.handle, "IOReportChannelGetGroup");
        gIOReport.subgroup = (SBIOReportSubGroupFn)dlsym(gIOReport.handle, "IOReportChannelGetSubGroup");
        gIOReport.stateCount = (SBIOReportStateCountFn)dlsym(gIOReport.handle, "IOReportStateGetCount");
        gIOReport.stateName = (SBIOReportStateNameFn)dlsym(gIOReport.handle, "IOReportStateGetNameForIndex");
        gIOReport.stateResidency = (SBIOReportStateResidencyFn)dlsym(gIOReport.handle, "IOReportStateGetResidency");
        gIOReport.ready = gIOReport.copyChannels && gIOReport.createSubscription && gIOReport.createSamples &&
                          gIOReport.createDelta && gIOReport.iterate && gIOReport.channelName && gIOReport.group &&
                          gIOReport.subgroup && gIOReport.stateCount && gIOReport.stateName && gIOReport.stateResidency;
        gIOReport.ecpuDVFS = readDVFSTable(CFSTR("voltage-states1-sram"));
        gIOReport.pcpuDVFS = readDVFSTable(CFSTR("voltage-states5-sram"));
    });
}

static double readFrequencyFromIOReport(void) {
    initIOReportFrequency();
    if (!gIOReport.ready || (!gIOReport.ecpuDVFS.count && !gIOReport.pcpuDVFS.count)) return 0.0;
    if (!gIOReport.subscription) {
        CFMutableDictionaryRef channels = gIOReport.copyChannels(@"CPU Stats", nil, 0, 0, 0);
        if (!channels) return 0.0;
        gIOReport.subscription = gIOReport.createSubscription(NULL, channels, &gIOReport.subscribedChannels, 0, NULL);
        CFRelease(channels);
        if (!gIOReport.subscription) return 0.0;
    }
    CFDictionaryRef first = gIOReport.createSamples(gIOReport.subscription, gIOReport.subscribedChannels, NULL);
    if (!first) return 0.0;
    [NSThread sleepForTimeInterval:0.12];
    CFDictionaryRef last = gIOReport.createSamples(gIOReport.subscription, gIOReport.subscribedChannels, NULL);
    if (!last) { CFRelease(first); return 0.0; }
    CFDictionaryRef delta = gIOReport.createDelta(first, last, NULL);
    CFRelease(first); CFRelease(last);
    if (!delta) return 0.0;

    __block double pcpuSum = 0.0, pcpuWeight = 0.0, ecpuSum = 0.0, ecpuWeight = 0.0;
    gIOReport.iterate(delta, ^int(CFDictionaryRef channel) {
        NSString *group = gIOReport.group(channel);
        NSString *subgroup = gIOReport.subgroup(channel);
        if (![group isEqualToString:@"CPU Stats"]) return 0;
        if (![subgroup isEqualToString:@"CPU Complex Performance States"] &&
            ![subgroup isEqualToString:@"CPU Core Performance States"]) return 0;
        NSString *name = gIOReport.channelName(channel);
        NSArray *table = [name containsString:@"E"] ? gIOReport.ecpuDVFS : gIOReport.pcpuDVFS;
        if (!table.count) return 0;
        int count = MIN(gIOReport.stateCount(channel), (int)table.count);
        uint64_t active = 0;
        for (int i = 1; i < count; i++) {
            NSString *state = gIOReport.stateName(channel, i);
            if (![state containsString:@"P"] && ![state containsString:@"V"]) continue;
            uint64_t residency = gIOReport.stateResidency(channel, i);
            double mhz = [table[i] doubleValue];
            if (mhz <= 0.0) continue;
            active += residency;
            if ([name containsString:@"E"]) ecpuSum += mhz * residency;
            else pcpuSum += mhz * residency;
        }
        if ([name containsString:@"E"]) ecpuWeight += active;
        else pcpuWeight += active;
        return 0;
    });
    CFRelease(delta);
    if (pcpuWeight > 0.0) return pcpuSum / pcpuWeight;
    if (ecpuWeight > 0.0) return ecpuSum / ecpuWeight;
    return 0.0;
}

static double frequencyMHzFromCFValue(CFTypeRef value) {
    if (!value) return 0.0;
    double raw = 0.0;
    if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        if (!CFNumberGetValue((CFNumberRef)value, kCFNumberDoubleType, &raw)) return 0.0;
    } else if (CFGetTypeID(value) == CFDataGetTypeID()) {
        CFIndex length = CFDataGetLength((CFDataRef)value);
        if (length == 4) {
            uint32_t v = 0; CFDataGetBytes((CFDataRef)value, CFRangeMake(0, 4), (UInt8 *)&v); raw = v;
        } else if (length == 8) {
            uint64_t v = 0; CFDataGetBytes((CFDataRef)value, CFRangeMake(0, 8), (UInt8 *)&v); raw = (double)v;
        }
    }
    if (raw >= 100000000.0 && raw <= 10000000000.0) return raw / 1000000.0;
    if (raw >= 100000.0 && raw <= 10000000.0) return raw / 1000.0;
    if (raw >= 100.0 && raw <= 6000.0) return raw;
    return 0.0;
}

static __attribute__((unused)) double readFrequencyFromIORegistry(void) {
    // 全量枚举 IOService，并沿父链搜索当前频率属性；不读取 *_max 或设备标称值。
    const char *services[] = {"AppleARMPlatform", "ApplePMGR", "AppleARMIODevice", "AppleCLPC", "IOCPU", NULL};
    const CFStringRef keys[] = {
        CFSTR("current-frequency"), CFSTR("CurrentFrequency"),
        CFSTR("actual-frequency"), CFSTR("ActualFrequency"),
        CFSTR("cpu-frequency"), CFSTR("CPUFrequency"),
        CFSTR("frequency"), CFSTR("Frequency"),
        CFSTR("clock-frequency"), CFSTR("ClockFrequency"), NULL
    };
    for (int si = 0; services[si]; si++) {
        io_iterator_t iterator = IO_OBJECT_NULL;
        CFMutableDictionaryRef matching = IOServiceMatching(services[si]);
        if (!matching || IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) != KERN_SUCCESS) continue;
        io_service_t service = IOIteratorNext(iterator);
        while (service) {
            io_registry_entry_t node = service;
            for (int depth = 0; node && depth < 10; depth++) {
                for (int ki = 0; keys[ki]; ki++) {
                    CFTypeRef value = IORegistryEntryCreateCFProperty(node, keys[ki], kCFAllocatorDefault, 0);
                    double mhz = frequencyMHzFromCFValue(value);
                    if (value) CFRelease(value);
                    if (mhz > 100.0) {
                        if (node != service) IOObjectRelease(node);
                        IOObjectRelease(service); IOObjectRelease(iterator);
                        return mhz;
                    }
                }
                io_registry_entry_t parent = IO_OBJECT_NULL;
                if (IORegistryEntryGetParentEntry(node, kIOServicePlane, &parent) != KERN_SUCCESS) parent = IO_OBJECT_NULL;
                if (node != service) IOObjectRelease(node);
                node = parent;
            }
            if (node && node != service) IOObjectRelease(node);
            IOObjectRelease(service);
            service = IOIteratorNext(iterator);
        }
        IOObjectRelease(iterator);
    }
    return 0.0;
}

static double getRealCPUFrequency(double currentCpuUsage) {
    (void)currentCpuUsage;
    static double lastFrequencyMHz = 0.0;
    static BOOL started = NO;
    static dispatch_queue_t queue;
    static NSObject *lock;
    if (!started) {
        started = YES;
        queue = dispatch_queue_create("com.sbcpu.dvfs-frequency", DISPATCH_QUEUE_SERIAL);
        lock = [NSObject new];
        dispatch_async(queue, ^{
            for (;;) {
                double frequency = readFrequencyFromIOReport();
                if (frequency > 100.0) {
                    @synchronized (lock) { lastFrequencyMHz = frequency; }
                }
                [NSThread sleepForTimeInterval:0.25];
            }
        });
    }
    @synchronized (lock) { return lastFrequencyMHz; }
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
    return SBCPUTextOnlyTop(floatingTextOnlyMode, safeTop, sbcpuStatusBarDockEffective());
}

// 状态栏胶囊尺寸：接近灵动岛，独立于普通竖屏/横屏折叠尺寸。
static inline CGFloat statusBarDockCapsuleWidth(void) {
    NSInteger count = (statusDockShowCPU ? 1 : 0) + (statusDockShowFPS ? 1 : 0) +
                      (statusDockShowFrequency ? 1 : 0) + (statusDockShowCurrent ? 1 : 0) +
                      (statusDockShowTemperature ? 1 : 0) + (statusDockShowBattery ? 1 : 0) +
                      (statusDockShowSIM1 ? 1 : 0) + (statusDockShowSIM2 ? 1 : 0);
    CGFloat width = 34.0f + (CGFloat)count * 48.0f;
    CGFloat screenWidth = [UIScreen mainScreen].bounds.size.width;
    return MIN(MAX(width, 126.0f), MAX(126.0f, screenWidth - 24.0f));
}
static inline CGFloat statusBarDockCapsuleHeight(void) { return 38.0f; }

static void clampAndPositionFloatingView(CGPoint targetCenter, BOOL animate) {
    if (!floatingView || !floatingView.superview) return;
    if (floatingView.positionLocked) {
        floatingView.center = floatingView.lockedCenter; // safety-only correction after size/rotation changes
        return;
    }
    // Periodic layout must not cancel the user-selected undocked interval.
    if (sbcpuStatusBarDockEffective() && (floatingView.statusDockDragging || floatingView.statusDockReturnTimer.valid)) return;

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
        CGFloat targetW = sbcpuStatusBarDockEffective() ? statusBarDockCapsuleWidth() : 68.0f;
        CGFloat targetH = sbcpuStatusBarDockEffective() ? statusBarDockCapsuleHeight() : 28.0f;
        CGFloat targetHalfW = targetW / 2.0f;
        CGFloat targetHalfH = targetH / 2.0f;

        CGFloat colMinX = targetHalfW + 4.0f;
        CGFloat colMaxX = containerBounds.size.width - targetHalfW - 4.0f;
        CGFloat colMinY = targetHalfH + floatingTopSafeMargin(floatingView.superview);
        CGFloat colMaxY = containerBounds.size.height - targetHalfH - 10.0f;

        if (!floatingTextOnlyMode && sbcpuStatusBarDockEffective()) {
            targetCenter.x = containerBounds.size.width * 0.5f;
            targetCenter.y = colMinY;
        } else {
            BOOL isLeft = (targetCenter.x <= containerBounds.size.width / 2.0f);
            targetCenter.x = isLeft ? colMinX : colMaxX;
            targetCenter.y = MIN(MAX(targetCenter.y, colMinY), colMaxY);
        }
    } else if (!floatingTextOnlyMode && sbcpuStatusBarDockEffective()) {
        // 状态栏吸附：浮窗整体停在顶部安全区域内，横向位置仍可拖动。
        targetCenter.y = minY;
    } else if (!floatingTextOnlyMode && smartDockEnable) {
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

    if (!floatingTextOnlyMode && sbcpuStatusBarDockEffective()) {
        // 无论展开还是折叠，开启后都停在顶部安全区域。
        targetCenter.y = floatingView.isCollapsed
            ? (floatingView.bounds.size.height * 0.5f + floatingTopSafeMargin(floatingView.superview))
            : minY;
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

static void applyTextOnlyTextFilter(void) {
    if (!textOnlyLabel) return;
    // Always clear the obsolete compositor filter, including fixed/custom modes.
    textOnlyLabel.layer.compositingFilter = nil;
    if (!floatingTextOnlyMode) return;
    // SpringBoard's main-screen environment is authoritative, not foreground-app
    // traits or sampled pixels. Its own overlay window is the unspecified fallback.
    int style = SBCPUTextSystemStyle((int)UIScreen.mainScreen.traitCollection.userInterfaceStyle,
                                    (int)cpuWindow.traitCollection.userInterfaceStyle);
    if (floatingTextOnlyColor == 3) {
        textOnlyLabel.textColor = [UIColor colorWithRed:textOnlyCustomRGBA.red green:textOnlyCustomRGBA.green
                                                  blue:textOnlyCustomRGBA.blue alpha:textOnlyCustomRGBA.alpha];
    } else {
        textOnlyLabel.textColor = SBCPUTextUsesWhite((int)floatingTextOnlyColor, style) ? UIColor.whiteColor : UIColor.blackColor;
    }
}

static void applyTextOnlyMode(void) {
    if (!floatingView || !floatingTextOnlyMode) return;
    if (!textOnlyLabel || textOnlyLabel.superview != floatingView) {
        [textOnlyLabel removeFromSuperview];
        textOnlyLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        textOnlyLabel.numberOfLines = 1;
        textOnlyLabel.lineBreakMode = NSLineBreakByClipping;
        textOnlyLabel.adjustsFontSizeToFitWidth = YES;
        textOnlyLabel.baselineAdjustment = UIBaselineAdjustmentAlignCenters;
        textOnlyLabel.textAlignment = NSTextAlignmentCenter;
        textOnlyLabel.backgroundColor = UIColor.clearColor;
        textOnlyLabel.userInteractionEnabled = NO;
        [floatingView addSubview:textOnlyLabel];
    }
    // Keep original data labels alive, hide their decorative presentation only.
    for (UIView *view in floatingView.subviews) view.hidden = (view != textOnlyLabel);
    textOnlyLabel.hidden = NO;
    floatingView.backgroundColor = UIColor.clearColor;
    floatingView.layer.shadowOpacity = 0;
    floatingView.layer.borderWidth = 0;
    floatingView.alpha = 1;
    floatingView.isCollapsed = NO;
    SBCPUTextOnlyFields fields = {textOnlyShowCPU, textOnlyShowFrequency, textOnlyShowFPS,
        textOnlyShowBattery, textOnlyShowTemperature, textOnlyShowCurrent, textOnlyShowSIM1, textOnlyShowSIM2};
    NSString *netCurrent = SBCPUTextOnlyCurrentText(textOnlyBatteryCurrent,
        textOnlyCurrentUptime, [NSProcessInfo processInfo].systemUptime);
    textOnlyLabel.text = SBCPUTextOnlyRow(fields, floatingView.cpuValueLabel.text,
        floatingView.cpuFreqLabel.text, floatingView.fpsValueLabel.text, floatingView.batteryValueLabel.text,
        floatingView.tempValueLabel.text, netCurrent, textOnlySignals);
    textOnlyLabel.hidden = (textOnlyLabel.text.length == 0);
    textOnlyLabel.font = [UIFont monospacedSystemFontOfSize:floatingTextOnlyFontSize weight:UIFontWeightMedium];
    CGRect container = floatingView.superview.bounds;
    UIInterfaceOrientation orientation = getEffectiveFloatingOrientation();
    BOOL rotated = UIInterfaceOrientationIsLandscape(orientation);
    CGFloat available = SBCPUTextOnlyAvailableWidth(container.size.width, container.size.height, rotated);
    CGFloat naturalWidth = ceil([textOnlyLabel.text sizeWithAttributes:@{NSFontAttributeName:textOnlyLabel.font}].width);
    textOnlyLabel.minimumScaleFactor = SBCPUTextOnlyMinimumScale(naturalWidth, available);
    // Single physical row; retain every selected value even on narrow screens.
    CGFloat rowWidth = textOnlyLabel.hidden ? 1 : MAX(1, MIN(available, naturalWidth + 2));
    CGFloat rowHeight = textOnlyLabel.hidden ? 1 : ceil(textOnlyLabel.font.lineHeight);
    floatingView.bounds = CGRectMake(0, 0, rowWidth, rowHeight);
    textOnlyLabel.frame = floatingView.bounds;
    applyTextOnlyTextFilter();
}

static void handleTextOnlyModeTransition(BOOL wasEnabled) {
    if (!floatingView || wasEnabled == floatingTextOnlyMode) return;
    if (floatingTextOnlyMode) {
        textOnlySnapshotValid = YES;
        textOnlySnapshotCollapsed = floatingView.isCollapsed || sbcpuStatusBarDockEffective();
        textOnlySnapshotCenter = keyboardMoved ? CGPointMake(CGRectGetMidX(keyboardBeforeFrame), CGRectGetMidY(keyboardBeforeFrame)) : floatingView.center;
        keyboardMoved = NO;
        textOnlyDragging = NO;
        textOnlySignals = (textOnlyShowSIM1 || textOnlyShowSIM2) ? readAllSimSignals() : @[];
        textOnlyShadowOpacity = floatingView.layer.shadowOpacity;
        textOnlyBorderWidth = floatingView.layer.borderWidth;
        textOnlyHiddenSnapshot = [NSMapTable weakToStrongObjectsMapTable];
        for (UIView *view in floatingView.subviews) [textOnlyHiddenSnapshot setObject:@(view.hidden) forKey:view];
        [floatingView.statusDockReturnTimer invalidate];
        floatingView.statusDockReturnTimer = nil;
        floatingView.statusDockDragging = NO;
        [floatingView.inactivityTimer invalidate];
        floatingView.inactivityTimer = nil;
        [floatingView.layer removeAllAnimations];
        floatingView.layoutTransitionAnimating = NO;
        floatingView.isCollapsed = NO;
        applyTextOnlyMode();
    } else {
        textOnlyLabel.layer.compositingFilter = nil;
        [textOnlyLabel removeFromSuperview];
        textOnlyLabel = nil;
        textOnlySignals = nil;
        for (UIView *view in floatingView.subviews) {
            NSNumber *hidden = [textOnlyHiddenSnapshot objectForKey:view];
            if (hidden) view.hidden = hidden.boolValue;
        }
        textOnlyHiddenSnapshot = nil;
        floatingView.layer.shadowOpacity = textOnlyShadowOpacity;
        floatingView.layer.borderWidth = textOnlyBorderWidth;
        floatingView.isCollapsed = NO;
        [floatingView applyLiquidGlassStyle];
        updateFloatingSize();
        if (textOnlySnapshotValid) floatingView.center = textOnlySnapshotCenter;
        if ((textOnlySnapshotValid && textOnlySnapshotCollapsed) || sbcpuStatusBarDockEffective())
            [floatingView collapseToEdgeAnimated:NO];
        clampAndPositionFloatingView(floatingView.center, NO);
        [floatingView resetInactivityTimer];
        applyFloatingAlpha();
        textOnlySnapshotValid = NO;
    }
}

static void updateFloatingSize(void) {
    if (!floatingView) return;
    // 展开/收起动画自己管理 bounds/transform；每秒刷新不能在中途抢回布局。
    if (floatingView.layoutTransitionAnimating) return;

    BOOL charging = isChargingInternal();
    // CH0I 智能停充会让 AppleSmartBattery.IsCharging 变成 NO。
    // 但物理充电器仍在，浮窗不应因此瞬间缩掉“电量/状态”区域。
    BOOL layoutCharging = charging || gSmartChargeHoldDisplay;
    UIInterfaceOrientation orientation = getEffectiveFloatingOrientation();

    floatingView.transform = CGAffineTransformIdentity;

    [floatingView updateLayoutWithShowCpuFreq:showCpuFrequency
                                       showFps:showFps
                            showBatteryPercent:showBatteryPercent
                               showBatteryTemp:showBatteryTemperature
                            showBatteryCurrent:showBatteryCurrent
                                    isCharging:layoutCharging];

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

    CGAffineTransform finalTransform = CGAffineTransformConcat(CGAffineTransformMakeScale(floatingTextOnlyMode ? 1 : floatingScale, floatingTextOnlyMode ? 1 : floatingScale), CGAffineTransformMakeRotation(rotationAngle));
    floatingView.transform = finalTransform;
    if (floatingTextOnlyMode && !textOnlyDragging) {
        CGRect bounds = floatingView.superview.bounds;
        CGFloat halfW = floatingView.frame.size.width * 0.5;
        CGFloat halfH = floatingView.frame.size.height * 0.5;
        CGFloat anchorX = SBCPUTextOnlyAnchorX((int)floatingTextOnlyPreset, bounds.size.width, halfW);
        floatingView.center = CGPointMake(anchorX + floatingTextOnlyX, halfH + 2 + floatingTextOnlyY);
    }
    clampAndPositionFloatingView(floatingView.center, NO);
}

static void createCPUWindow(void) {
    if (cpuWindow) return;

    UIWindowScene *scene = getWindowScene();
    if (!scene) return;

    cpuWindow = [[SBCPUWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    cpuWindow.windowScene = scene;
    // 主浮窗必须始终位于普通 App 窗口之上。

    cpuWindow.windowLevel = UIWindowLevelAlert + 100.0;
    cpuWindow.backgroundColor = UIColor.clearColor;
    cpuWindow.opaque = NO;
    cpuWindow.rootViewController = [[SBCPURootViewController alloc] init];
    cpuWindow.rootViewController.view.backgroundColor = UIColor.clearColor;
    cpuWindow.hidden = !isEnabled;

    CGRect initFrame = CGRectMake(20, 160, 240, 60);
    NSString *savedFrame = [[NSUserDefaults standardUserDefaults] stringForKey:@"SBCPU.LastFrame"];
    if (rememberPositionEnable && savedFrame) {
        CGRect parsed = CGRectFromString(savedFrame);
        if (!CGRectIsEmpty(parsed)) initFrame = parsed;
    }

    floatingView = [[SBCPUFloatingView alloc] initWithFrame:initFrame];
    [cpuWindow.rootViewController.view addSubview:floatingView];

    // Dedicated SpringBoard defaults, like LastFrame; independent of rememberPositionEnable.
    NSUserDefaults *positionDefaults = [NSUserDefaults standardUserDefaults];
    NSString *lockedPoint = [positionDefaults stringForKey:@"SBCPU.LockedCenter"];
    if ([positionDefaults boolForKey:@"SBCPU.PositionLocked"] && lockedPoint.length) {
        CGPoint point = CGPointFromString(lockedPoint);
        if (isfinite(point.x) && isfinite(point.y)) {
            floatingView.lockedCenter = point;
            floatingView.positionLocked = YES;
            floatingView.center = point;
        }
    }

    if (floatingTextOnlyMode) {
        handleTextOnlyModeTransition(NO);
        textOnlySnapshotCollapsed = statusBarDockEnable;
    }

    applyFloatingAlpha();
    updateFloatingSize();
    if (sbcpuStatusBarDockEffective() && floatingView && !floatingView.isCollapsed) {
        [floatingView collapseToEdgeAnimated:NO];
    }
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

static void updateCPU(void) {
    if (!isEnabled || gCPUUpdatePending) return;
    gCPUUpdatePending = YES;

    if (!cpuWindow || !floatingView) {
        createCPUWindow();
    }
    if (!floatingView) {
        gCPUUpdatePending = NO;
        return;
    }
    double cpu = getSpringBoardCPUUsage();
    double cpuFreq = getRealCPUFrequency(cpu);
    double fps = [SBCPUFPSHelper sharedInstance].currentFPS;

    checkHighCPU(cpu);
    // V4.22：智能停充已从 updateCPU 移除——充电控制完全由 SBCPUChargeDaemon
    // (Charge Engine, 事件驱动) 负责，不依赖浮窗是否存在。此处只同步显示状态。

    dispatch_async(dispatch_get_main_queue(), ^{
        if (!floatingView) {
            gCPUUpdatePending = NO;
            return;
        }

        [UIDevice currentDevice].batteryMonitoringEnabled = YES;
        NSInteger battery = (NSInteger)([UIDevice currentDevice].batteryLevel * 100);
        if (battery < 0) battery = 100;

        double temp = getBatteryTemperatureInternal();
        double current = getBatteryCurrentInternal();
        BOOL charging = isChargingInternal();

        if ((chargeBoostEnable || forceFastChargeEnable) && charging) {
            applyExperimentalChargeLimit100(YES);
        } else if (!chargeBoostEnable && !forceFastChargeEnable && chargeLimit100Applied) {
            applyExperimentalChargeLimit100(NO);
        }
        BOOL chargingStateChanged = (charging != previousChargingState);
        if (charging && !previousChargingState) {
            if (floatingView.isCollapsed && !floatingView.isShowingNotification) {
                [floatingView expandFromEdgeAnimated:YES];
            }
            [floatingView triggerPlugAnimation];
        }
        previousChargingState = charging;

        if (autoExpandLandscape) {
            UIInterfaceOrientation orientation = getEffectiveFloatingOrientation();
            BOOL isLandscape = (orientation == UIInterfaceOrientationLandscapeLeft || orientation == UIInterfaceOrientationLandscapeRight);

            if (isLandscape && !wasLandscape && !floatingView.isCollapsed && !floatingView.isShowingNotification) {
                // 横屏（游戏）自动缩小为迷你胶囊（CPU/FPS/电量/温度），替代原自动展开大浮窗
                [floatingView collapseToEdgeAnimated:YES];
            } else if (!isLandscape && wasLandscape && !floatingView.isShowingNotification) {
                // 退出横屏：若处于迷你折叠态，恢复竖屏折叠布局
                if (floatingView.isCollapsed) {
                    [floatingView syncCollapsedLayoutForOrientation];
                }
            }
            wasLandscape = isLandscape;
        }

        NSDictionary *chargeInfo = getRealBatteryDetails();
        // Same registry sample as charge-power display; cache before updateData
        // builds the text row. Missing data invalidates the previous sample.
        if (floatingTextOnlyMode) {
            textOnlyBatteryCurrent = textOnlyShowCurrent ? chargeInfo[@"SBCPUTextOnlyCurrentMA"] : nil;
            textOnlyCurrentUptime = [NSProcessInfo processInfo].systemUptime;
        }
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
            floatingView.statusLabel.text = [NSString stringWithFormat:@"🔋 快充辅助（安全模式） · %.1fW", chargeWatts];
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

        if (chargingStateChanged) updateFloatingSize();
        gCPUUpdatePending = NO;
    });
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
    CFTimeInterval _sampleElapsed;
    double _smoothedFPS;
}

+ (instancetype)sharedInstance {
    static SBCPUFPSHelper *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SBCPUFPSHelper alloc] init];
    });
    return instance;
}



- (void)startMonitoring {
    if (_displayLink) return;
    _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    [_displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)stopMonitoring {
    if (_displayLink) {
        [_displayLink invalidate];
        _displayLink = nil;
    }
    _lastTimestamp = 0;
    _frameCount = 0;
    _sampleElapsed = 0;
    _smoothedFPS = 0;
    _currentFPS = 0.0;
}


- (void)tick:(CADisplayLink *)link {
    CFTimeInterval timestamp = link.timestamp;
    if (_lastTimestamp == 0 || timestamp <= _lastTimestamp) {
        _lastTimestamp = timestamp;
        _frameCount = 0;
        _sampleElapsed = 0;
        return;
    }
    CFTimeInterval interval = timestamp - _lastTimestamp;
    _lastTimestamp = timestamp;
    // 后台切换/主线程卡顿会产生很大的时间洞，不能把它算进屏幕刷新率。
    if (interval <= 0.0 || interval > 0.25) {
        _frameCount = 0;
        _sampleElapsed = 0;
        return;
    }
    _frameCount++;
    _sampleElapsed += interval;
    // 约四分之一秒采样一次：降低显示延迟，同时保留足够的帧数抗抖动。
    if (_sampleElapsed >= 0.25) {
        double measured = (double)_frameCount / _sampleElapsed;
        if (measured >= 1.0 && measured <= 240.0) {
            // 轻度平滑，避免 60/120Hz 之间因单次抖动跳变；不再使用 1 秒滞后窗口。
            _smoothedFPS = (_smoothedFPS > 0.0) ? (_smoothedFPS * 0.35 + measured * 0.65) : measured;
            self.currentFPS = _smoothedFPS;
        }
        _frameCount = 0;
        _sampleElapsed = 0;
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
// V4.35：Native Liquid Glass 只负责“表面”，不参与浮窗尺寸计算。
// hostView 始终就是 SBCPUFloatingView 本身；尺寸由浮窗布局单独决定。
- (void)refreshNativeLiquidGlass {
    if (floatingTextOnlyMode) { _nativeLiquidGlassView.hidden = YES; return; }
    if (!_nativeLiquidGlassView || !_usingNativeLiquidGlass) return;
    CGRect b = self.bounds;
    if (CGRectIsEmpty(b)) {
        _nativeLiquidGlassView.hidden = YES;
        return;
    }
    _nativeLiquidGlassView.frame = b;
    CGFloat r = MIN(floatingCornerRadius, CGRectGetHeight(b) * 0.5);
    _nativeLiquidGlassView.layer.cornerRadius = r;
    _nativeLiquidGlassView.layer.cornerCurve = kCACornerCurveContinuous;
    _nativeLiquidGlassView.layer.masksToBounds = YES;
    if ([_nativeLiquidGlassView isKindOfClass:[LGLiveBackdropView class]]) {
        [(LGLiveBackdropView *)_nativeLiquidGlassView applyFilters];
    }
}


- (void)layoutSubviews {
    [super layoutSubviews];
    if (floatingTextOnlyMode) return;
    if (_nativeLiquidGlassView && _usingNativeLiquidGlass) {
        CGRect b = self.bounds;
        _nativeLiquidGlassView.frame = b;
        CGFloat r = MIN(floatingCornerRadius, CGRectGetHeight(b) * 0.5);
        _nativeLiquidGlassView.layer.cornerRadius = r;
        _nativeLiquidGlassView.layer.cornerCurve = kCACornerCurveContinuous;
        _nativeLiquidGlassView.layer.masksToBounds = YES;
        if ([_nativeLiquidGlassView isKindOfClass:[LGLiveBackdropView class]] && !CGRectIsEmpty(b)) {
            [(LGLiveBackdropView *)_nativeLiquidGlassView applyFilters];
        }
    }
}


- (void)applyLiquidGlassStyle {
    if (floatingTextOnlyMode) { applyTextOnlyMode(); return; }
    BOOL enabled = liquidGlassEnabled;

    // V4.34：CCLiquidGlassView 直接就是浮窗背景，不再叠加在旧毛玻璃之上。
    if (_nativeLiquidGlassView && _usingNativeLiquidGlass) {
        _nativeLiquidGlassView.hidden = !enabled;
        _nativeLiquidGlassView.alpha = 1.0;
        if (enabled && [_nativeLiquidGlassView isKindOfClass:[LGLiveBackdropView class]]) {
            [(LGLiveBackdropView *)_nativeLiquidGlassView applyFilters];
        }
    }

    // Native Glass 不可用时，保留旧 UIVisualEffectView 作为安全 fallback；
    // Native Glass 可用时，关闭开关则回退到这个普通背景。
    if (_blurView) {
        // 关闭液态玻璃 = 回退到旧版泛白毛玻璃，而不是透明背景。
        _blurView.effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialLight];
        _blurView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.18];
        _blurView.hidden = (_usingNativeLiquidGlass && enabled);
        _blurView.frame = self.bounds;
        _blurView.layer.cornerRadius = MIN(floatingCornerRadius, MAX(0.0, self.bounds.size.height * 0.5));
        _blurView.layer.cornerCurve = kCACornerCurveContinuous;
        _blurView.layer.masksToBounds = YES;
    }

    UIView *surface = _glassSurfaceView ?: (UIView *)_blurView;
    if (surface && (!_usingNativeLiquidGlass || !enabled)) {
        // 仅旧版 UIBlurEffect fallback 使用自有圆角裁剪。
        surface.layer.masksToBounds = YES;
        CGFloat r = floatingCornerRadius;
        if (surface.bounds.size.height > 0.0) r = MIN(r, surface.bounds.size.height / 2.0);
        surface.layer.cornerRadius = r;
    }

    UIView *content = _glassContentView ?: _glassContentView;
    if (enabled) {
        LGApplyShadowToLabelsInView(content);
    } else {
        LGRemoveLabelShadowInView(content);
    }

    // V4.34：旧 CABackdrop/specular/tint 层不再参与渲染，避免双层磨砂。
    _glassBackdropLayer.hidden = YES;
    _glassSheenLayer.hidden = YES;
    _glassBoostLayer.hidden = YES;
    _glassEdgeLayer.hidden = YES;
    if (_glassTintLayer) _glassTintLayer.hidden = YES;

    [self applyAdaptiveTextColors];
}

// 液态玻璃：实时采样浮窗下方背景亮度，文字自动反色（亮背景→黑字，暗背景→白字）
- (void)applyAdaptiveTextColors {
    if (floatingTextOnlyMode) {
        // Text-only color follows system appearance or a fixed color, never sampled.
        applyTextOnlyMode();
        updateFloatingSize();
        return;
    }
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
    // 状态栏胶囊独立采用背景采样反色，不受液态玻璃开关影响。
    if (sbcpuStatusBarDockEffective() && _miniDockInfoLabel) {
        CGFloat dockLum = [self sampleBackgroundLuminance];
        BOOL dockLightBackground = dockLum > 0.5f;
        UIColor *dockColor = dockLightBackground ? [UIColor blackColor] : [UIColor whiteColor];
        _miniDockInfoLabel.textColor = dockColor;
        _miniDockInfoLabel.layer.shadowColor = (dockLightBackground ? [UIColor whiteColor] : [UIColor blackColor]).CGColor;
        _miniDockInfoLabel.layer.shadowOpacity = 0.45f;
        _miniDockInfoLabel.layer.shadowRadius = 1.5f;
        _miniDockInfoLabel.layer.shadowOffset = CGSizeZero;
    }

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
    _miniFpsLabel.textColor = monoColor;   // 横屏迷你胶囊四项参与反色
    _miniBattLabel.textColor = monoColor;
    _miniTempLabel.textColor = monoColor;
    _timeLabel.textColor = monoColor; // 时间显示也参与反色
    // 充电状态标签（智能停充/快充/充电增强）：跟随背景反色，白底黑字可读
    if (_statusLabel) _statusLabel.textColor = monoColor;
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
    if (floatingTextOnlyMode) {
        applyTextOnlyTextFilter(); // immediate, independent of liquid-glass and refresh ticks
        return;
    }
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

        self.doubleTapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleDoubleTap:)];
        self.doubleTapGesture.numberOfTapsRequired = 2;
        self.doubleTapGesture.delegate = self;
        [self addGestureRecognizer:self.doubleTapGesture];
        [self.singleTapGesture requireGestureRecognizerToFail:self.doubleTapGesture];


        self.longPressGesture = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
        self.longPressGesture.minimumPressDuration = 0.6;
        self.longPressGesture.delegate = self;
        [self addGestureRecognizer:self.longPressGesture];

        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.28f;
        self.layer.shadowOffset = CGSizeMake(0, 6);
        self.layer.shadowRadius = 18.0f;

        // V4.36：SBCPU 直接使用 ceshi-main 的 CABackdropLayer + CAFilter + Metal renderer。
        // 不再依赖 CCLiquidGlassView；SBCPUFloatingView 自身就是 host surface。
        UIBlurEffect *blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialLight];
        _blurView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
        _blurView.userInteractionEnabled = NO;

        _nativeLiquidGlassView = nil;
        _usingNativeLiquidGlass = NO;
        _glassSurfaceView = nil;

        // 始终把旧版毛玻璃作为备用表面放在最底层。
        // 开启液态玻璃时隐藏它；关闭液态玻璃时直接显示它，恢复以前的泛白毛玻璃观感。
        _blurView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.18];
        _blurView.layer.masksToBounds = YES;
        [self insertSubview:_blurView atIndex:0];

        @try {
            LGLiveBackdropView *glass = [[LGLiveBackdropView alloc]
                initWithFrame:CGRectZero
                    groupName:@"dylv.liquidglass.sbcpufloating.instance"
                   filterType:@"dylv.liquidglass.sbcpufloating"];
            if (glass) {
                glass.userInteractionEnabled = NO;
                glass.backgroundColor = UIColor.clearColor;
                _nativeLiquidGlassView = glass;
                _usingNativeLiquidGlass = YES;
                _glassSurfaceView = glass;
                [self insertSubview:glass atIndex:1];
                NSLog(@"[SBCPUFloating] V4.36 Metal Liquid Glass renderer installed");
            }
        } @catch (NSException *e) {
            _nativeLiquidGlassView = nil;
            _usingNativeLiquidGlass = NO;
            NSLog(@"[SBCPUFloating] V4.36 renderer init failed: %@", e);
        }

        if (!_usingNativeLiquidGlass) {
            _glassSurfaceView = _blurView;
        }

        // 内容与背景完全分离；这样收起/展开时不会留下独立的玻璃框。
        _glassContentView = [[UIView alloc] initWithFrame:self.bounds];
        _glassContentView.userInteractionEnabled = NO;
        [self addSubview:_glassContentView];

        _blurView.hidden = (_usingNativeLiquidGlass && liquidGlassEnabled);
        _blurView.frame = self.bounds;
        _nativeLiquidGlassView.hidden = !(_usingNativeLiquidGlass && liquidGlassEnabled);

        _marqueeLayer = [CAShapeLayer layer];
        _marqueeLayer.fillColor = [UIColor clearColor].CGColor;
        _marqueeLayer.strokeColor = [UIColor colorWithRed:0.2f green:0.85f blue:0.4f alpha:0.6f].CGColor;
        _marqueeLayer.lineWidth = 2.0f;
        _marqueeLayer.lineDashPattern = nil;
        _marqueeLayer.hidden = YES;
        _marqueeLayer.zPosition = 1001.0f;
        [_glassSurfaceView.layer addSublayer:_marqueeLayer];
        _marqueeFlowLayerA = [CAShapeLayer layer];
        _marqueeFlowLayerB = [CAShapeLayer layer];
        for (CAShapeLayer *flow in @[_marqueeFlowLayerA, _marqueeFlowLayerB]) {
            flow.fillColor = UIColor.clearColor.CGColor;
            flow.lineWidth = 2.5f;
            flow.lineDashPattern = @[@42, @260];
            flow.hidden = YES;
            flow.zPosition = 1002.0f;
            flow.shadowColor = UIColor.whiteColor.CGColor;
            flow.shadowOpacity = 0.75f;
            flow.shadowRadius = 5.0f;
            [_glassSurfaceView.layer addSublayer:flow];
        }
        _marqueeFlowLayerA.strokeColor = [UIColor colorWithRed:0.25f green:0.9f blue:1.0f alpha:0.95f].CGColor;
        _marqueeFlowLayerB.strokeColor = [UIColor colorWithRed:0.72f green:0.4f blue:1.0f alpha:0.95f].CGColor;

        // V4.35：原生 CCLiquidGlassView 已经是唯一玻璃表面。
        // 不再创建额外的 sheen / boost / edge 玻璃层，避免普通磨砂叠加。
        _glassSheenLayer = nil;
        _glassSheenMask = nil;
        _glassBoostLayer = nil;
        _glassBoostMask = nil;
        _glassEdgeLayer = nil;

        UIView *content = _glassContentView;
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

        _timeLabel = [[UILabel alloc] init];
        _timeLabel.text = @"00:00:00";
        _timeLabel.textColor = [UIColor darkGrayColor];
        _timeLabel.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightSemibold];
        _timeLabel.textAlignment = NSTextAlignmentCenter;
        _timeLabel.adjustsFontSizeToFitWidth = YES;
        _timeLabel.minimumScaleFactor = 0.75f;
        [_performanceContainer addSubview:_timeLabel];

        // SIM 卡信号行：浮窗最底部，实时显示运营商/制式/信号
        _signalLabel = [[UILabel alloc] init];
        _signalLabel.text = @"📶 信号检测中";
        _signalLabel.textColor = [UIColor whiteColor]; // 深色浮窗上白色更清晰（V4.18.6）
        _signalLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
        _signalLabel.textAlignment = NSTextAlignmentCenter;
        _signalLabel.adjustsFontSizeToFitWidth = YES;
        _signalLabel.minimumScaleFactor = 0.6f;
        [_performanceContainer addSubview:_signalLabel];

        // 超级快充启动动画：直接使用现有浮窗本体，不创建独立 UIWindow。
        // 这样插入充电器时只是把原浮窗临时变成一个紧凑的启动卡片，完成后恢复原样。
        _startupContainer = [[UIView alloc] init];
        _startupContainer.hidden = YES;
        _startupContainer.alpha = 0.0;
        _startupContainer.userInteractionEnabled = NO;
        [_glassContentView addSubview:_startupContainer];

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
        _statusDot.hidden = YES; // Expanded initial state; folded layout restores its indicator.
        [_collapsedContainerView addSubview:_statusDot];

        _miniCpuLabel = [[UILabel alloc] initWithFrame:CGRectMake(22, 5, 45, 18)];
        _miniCpuLabel.textColor = [UIColor blackColor];
        _miniCpuLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
        _miniCpuLabel.textAlignment = NSTextAlignmentLeft;
        [_collapsedContainerView addSubview:_miniCpuLabel];

        // 横屏迷你胶囊：FPS / 电量 / 温度（默认隐藏，进入横屏折叠态时显示）
        _miniFpsLabel = [[UILabel alloc] initWithFrame:CGRectMake(84, 5, 44, 18)];
        _miniFpsLabel.textColor = [UIColor blackColor];
        _miniFpsLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
        _miniFpsLabel.textAlignment = NSTextAlignmentLeft;
        _miniFpsLabel.hidden = YES;
        [_collapsedContainerView addSubview:_miniFpsLabel];

        _miniBattLabel = [[UILabel alloc] initWithFrame:CGRectMake(130, 5, 42, 18)];
        _miniBattLabel.textColor = [UIColor blackColor];
        _miniBattLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
        _miniBattLabel.textAlignment = NSTextAlignmentLeft;
        _miniBattLabel.hidden = YES;
        [_collapsedContainerView addSubview:_miniBattLabel];

        _miniTempLabel = [[UILabel alloc] initWithFrame:CGRectMake(174, 5, 52, 18)];
        _miniTempLabel.textColor = [UIColor blackColor];
        _miniTempLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
        _miniTempLabel.textAlignment = NSTextAlignmentLeft;
        _miniTempLabel.hidden = YES;
        [_collapsedContainerView addSubview:_miniTempLabel];

        _miniDockInfoLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _miniDockInfoLabel.textColor = [UIColor blackColor];
        _miniDockInfoLabel.font = [UIFont systemFontOfSize:11.0f weight:UIFontWeightBold];
        _miniDockInfoLabel.textAlignment = NSTextAlignmentCenter;
        _miniDockInfoLabel.adjustsFontSizeToFitWidth = YES;
        _miniDockInfoLabel.minimumScaleFactor = 0.55f;
        _miniDockInfoLabel.hidden = YES;
        [_collapsedContainerView addSubview:_miniDockInfoLabel];

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

        // 关闭持续截图采样；仅在初始化、布局变化和系统外观变化时更新文字颜色。
        _adaptiveTimer = nil;

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

// Central gate covers normal/text-only layout, fold/unfold, orientation and notification moves.
// Keep the anchor unchanged; only constrain the rendered center when geometry would hide it.
- (void)setCenter:(CGPoint)center {
    if (self.positionLocked) {
        center = self.lockedCenter;
        if (self.superview) {
            CGRect bounds = self.superview.bounds;
            CGRect frame = self.frame;
            center.x = CGRectGetMinX(bounds) + SBCPULockedCoordinate(center.x - CGRectGetMinX(bounds), bounds.size.width, frame.size.width / 2);
            center.y = CGRectGetMinY(bounds) + SBCPULockedCoordinate(center.y - CGRectGetMinY(bounds), bounds.size.height, frame.size.height / 2);
        }
    }
    [super setCenter:center];
}

- (void)handleDoubleTap:(UITapGestureRecognizer *)tap {
    if (tap.state != UIGestureRecognizerStateEnded) return;
    if (!self.positionLocked) {
        CALayer *presentation = (CALayer *)self.layer.presentationLayer;
        CGPoint anchor = presentation ? presentation.position : self.center;
        [self.layer removeAllAnimations];
        self.layoutTransitionAnimating = NO;
        self.lockedCenter = anchor;
        self.positionLocked = YES;
        self.center = anchor;
        [self.statusDockReturnTimer invalidate];
        self.statusDockReturnTimer = nil;
        self.statusDockDragging = NO;
        textOnlyDragging = NO;
        keyboardMoved = NO; // Never restore a stale pre-lock keyboard frame.
    } else {
        self.positionLocked = NO;
        if (sbcpuStatusBarDockEffective() && self.isCollapsed) [self scheduleStatusDockReturn];
    }
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:NSStringFromCGPoint(self.lockedCenter) forKey:@"SBCPU.LockedCenter"];
    [defaults setBool:self.positionLocked forKey:@"SBCPU.PositionLocked"];
    [defaults synchronize];
    [self resetInactivityTimer];
    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [feedback prepare];
    [feedback impactOccurred];
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (self.positionLocked && [gestureRecognizer isKindOfClass:[UIPanGestureRecognizer class]]) return NO;
    return YES;
}

- (void)handleSingleTap:(UITapGestureRecognizer *)tap {
    if (tap.state == UIGestureRecognizerStateEnded) {
        // V4.35.3：单击只保留轻微反馈；双击有独立反馈且不会再进入这里。
        UIImpactFeedbackGenerator *generator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [generator prepare];
        [generator impactOccurred];
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
    if (self.positionLocked) return;
    [self resetInactivityTimer];

    if (pan.state == UIGestureRecognizerStateBegan) {
        [self.statusDockReturnTimer invalidate];
        self.statusDockReturnTimer = nil;
        self.statusDockDragging = sbcpuStatusBarDockEffective();
        textOnlyDragging = floatingTextOnlyMode;
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
        if (floatingTextOnlyMode) {
            textOnlyDragging = NO;
            CGPoint translation = CGPointMake(self.center.x - self.lastPoint.x, self.center.y - self.lastPoint.y);
            floatingTextOnlyX = MAX(-1000, MIN(1000, floatingTextOnlyX + translation.x));
            floatingTextOnlyY = MAX(-1000, MIN(1000, floatingTextOnlyY + translation.y));
            setFloatPref(CFSTR("floatingTextOnlyX"), floatingTextOnlyX);
            setFloatPref(CFSTR("floatingTextOnlyY"), floatingTextOnlyY);
            CFPreferencesAppSynchronize(kPrefAppID);
            updateFloatingSize();
        } else if (rememberPositionEnable) {
            [[NSUserDefaults standardUserDefaults] setObject:NSStringFromCGRect(self.frame) forKey:@"SBCPU.LastFrame"];
            [[NSUserDefaults standardUserDefaults] synchronize];
        }
        self.statusDockDragging = NO;
        if (sbcpuStatusBarDockEffective() && self.isCollapsed) {
            // 拖开后按用户设置的延迟平滑吸回。
            [self scheduleStatusDockReturn];
        } else {
            clampAndPositionFloatingView(self.center, YES);
        }
        [self resetInactivityTimer];
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    // V4.35.3：浮窗的 Pan / Tap / LongPress 不再全部同时识别，避免拖动或长按
    // 与点击动作串联触发。单击与双击仍由 requireGestureRecognizerToFail: 协调。
    (void)gestureRecognizer;
    (void)otherGestureRecognizer;
    return NO;
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
    [_glassSurfaceView.layer addAnimation:animation forKey:@"plugBounce"];

    CABasicAnimation *glowAnim = [CABasicAnimation animationWithKeyPath:@"borderColor"];
    glowAnim.fromValue = (id)[UIColor colorWithRed:0.2f green:0.95f blue:0.5f alpha:1.0f].CGColor;
    glowAnim.toValue = (id)[UIColor colorWithWhite:1.0f alpha:0.60f].CGColor;
    glowAnim.duration = 0.7;
    [_glassSurfaceView.layer addAnimation:glowAnim forKey:@"borderGlow"];
}

- (void)updateLayoutWithShowCpuFreq:(BOOL)showFreq
                            showFps:(BOOL)showFps
                 showBatteryPercent:(BOOL)showBattery
                    showBatteryTemp:(BOOL)showTemp
                 showBatteryCurrent:(BOOL)showCurrent
                         isCharging:(BOOL)isCharging {

    if (floatingTextOnlyMode) { applyTextOnlyMode(); return; }
    if (self.isCollapsed && !self.isShowingNotification) return;
    if (!self.isCollapsed) _statusDot.hidden = YES;

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
        // V4.41：充电会话增量不放在顶部电量后面；统一放到下方
        // “智能停充待触发 · 81%→93%”这一行的目标百分比后面。
        // V4.42：顶部电量必须完整显示“XX%”。之前 batW=48 时，电量标签只有 30pt，
        // 在当前描边/字体配置下会被截成“82...”或“97...”。增量已移到下方状态行，
        // 因此这里给百分比独立留出足够宽度，并让外层自动扩宽，避免任何截断。
        CGFloat batW = 60.0f;
        _batteryIconLabel.frame = CGRectMake(currentX, padY + 10, 18, 18);
        _batteryValueLabel.frame = CGRectMake(currentX + 18, padY + 10, 42.0f, 18);
        _batterySubLabel.hidden = YES;
        _batterySubLabel.frame = CGRectZero;
        currentX += batW + 3.0f;

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

    // SIM 卡信号行（竖屏横屏都显示，可设置关闭）
    if (showSignalStrength) {
        _signalLabel.hidden = NO;
        currentY += 2.0f;
        _signalLabel.frame = CGRectMake(12.0f, currentY, finalW - 24.0f, 14.0f);
        currentY += 14.0f;
    } else {
        _signalLabel.hidden = YES;
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

    _glassSurfaceView.frame = CGRectMake(0, 0, finalW, currentY);
    if (_blurView) _blurView.frame = _glassSurfaceView.bounds;
    _glassContentView.frame = _glassSurfaceView.bounds;
    [self refreshNativeLiquidGlass];

    CGFloat cornerRad = floatingCornerRadius;
    if (cornerRad > currentY / 2.0f) cornerRad = currentY / 2.0f;

    _glassSurfaceView.layer.cornerRadius = cornerRad;
    if (_blurView) {
        _blurView.layer.cornerRadius = cornerRad;
        _blurView.layer.cornerCurve = kCACornerCurveContinuous;
        _blurView.layer.masksToBounds = YES;
    }
    if (_nativeLiquidGlassView && _usingNativeLiquidGlass) {
        // V4.35.2: CCLiquidGlassView is the actual floating surface, so it
        // must clip its rectangular layer to the same rounded shape.
        // Previously we deliberately left masksToBounds disabled, which made
        // the native surface render as a square panel even though the shadow
        // path and marquee were rounded.
        _nativeLiquidGlassView.layer.cornerRadius = cornerRad;
        _nativeLiquidGlassView.layer.cornerCurve = kCACornerCurveContinuous;
        _nativeLiquidGlassView.layer.masksToBounds = YES;
    }
    self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, finalW, currentY) cornerRadius:cornerRad].CGPath;

    CGPathRef marqueePath = [UIBezierPath bezierPathWithRoundedRect:_glassSurfaceView.bounds cornerRadius:cornerRad].CGPath;
    _marqueeLayer.frame = _glassSurfaceView.bounds;
    _marqueeLayer.path = marqueePath;
    _marqueeFlowLayerA.frame = _glassSurfaceView.bounds;
    _marqueeFlowLayerA.path = marqueePath;
    _marqueeFlowLayerB.frame = _glassSurfaceView.bounds;
    _marqueeFlowLayerB.path = marqueePath;

    // 液态玻璃 specular 高光层与边缘光跟随布局
    if (_glassBackdropLayer) {
        _glassBackdropLayer.frame = _glassSurfaceView.bounds;
        _glassBackdropLayer.cornerRadius = cornerRad;
    }
    if (_glassTintLayer) {
        _glassTintLayer.frame = _glassSurfaceView.bounds;
        _glassTintLayer.cornerRadius = cornerRad;
    }
    _glassSheenLayer.frame = _glassSurfaceView.bounds;
    _glassSheenMask.frame = _glassSurfaceView.bounds;
    _glassSheenMask.cornerRadius = cornerRad;
    _glassBoostLayer.frame = _glassSurfaceView.bounds;
    _glassBoostMask.frame = _glassSurfaceView.bounds;
    _glassBoostMask.cornerRadius = cornerRad;
    _glassEdgeLayer.frame = _glassSurfaceView.bounds;
    _glassEdgeLayer.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(_glassSurfaceView.bounds, 0.5f, 0.5f) cornerRadius:cornerRad].CGPath;

    [_marqueeLayer removeAllAnimations];
    [_marqueeFlowLayerA removeAllAnimations];
    [_marqueeFlowLayerB removeAllAnimations];
    _marqueeLayer.hidden = YES;
    _marqueeFlowLayerA.hidden = YES;
    _marqueeFlowLayerB.hidden = YES;
    if (isCharging) {
        if (chargeMarqueeStyle == 0) {
            // B：整条边框柔和呼吸，不再使用旧虚线跑马灯。
            _marqueeLayer.hidden = NO;
            _marqueeLayer.strokeColor = [UIColor colorWithRed:0.35f green:0.95f blue:0.55f alpha:0.85f].CGColor;
            CABasicAnimation *breath = [CABasicAnimation animationWithKeyPath:@"opacity"];
            breath.fromValue = @0.28; breath.toValue = @1.0; breath.duration = 1.8;
            breath.autoreverses = YES; breath.repeatCount = HUGE_VALF;
            [_marqueeLayer addAnimation:breath forKey:@"chargingBreath"];
        } else {
            // C：两条彩色光段反向沿边框移动。
            _marqueeFlowLayerA.hidden = NO; _marqueeFlowLayerB.hidden = NO;
            CABasicAnimation *forward = [CABasicAnimation animationWithKeyPath:@"lineDashPhase"];
            forward.fromValue = @0; forward.toValue = @(-300); forward.duration = 2.2; forward.repeatCount = HUGE_VALF;
            CABasicAnimation *reverse = [forward copy]; reverse.fromValue = @(-300); reverse.toValue = @0;
            [_marqueeFlowLayerA addAnimation:forward forKey:@"chargingFlowForward"];
            [_marqueeFlowLayerB addAnimation:reverse forKey:@"chargingFlowReverse"];
        }
    }

    self.bounds = CGRectMake(0, 0, finalW, currentY);
    self.performanceContainer.frame = self.bounds;
}

- (void)scheduleStatusDockReturn {
    if (floatingTextOnlyMode || self.positionLocked) return;
    [self.statusDockReturnTimer invalidate];
    self.statusDockReturnTimer = [NSTimer scheduledTimerWithTimeInterval:(NSTimeInterval)statusDockReturnDelay
        target:self selector:@selector(returnToStatusDock) userInfo:nil repeats:NO];
}

- (void)returnToStatusDock {
    [self.statusDockReturnTimer invalidate];
    self.statusDockReturnTimer = nil;
    if (!sbcpuStatusBarDockEffective() || !self.isCollapsed || self.isShowingNotification ||
        !self.superview || fastChargeStartupAnimating) return;
    // clampAndPositionFloatingView restores the top safe-area dock position;
    // its spring animation provides a smooth, non-jarring return.
    clampAndPositionFloatingView(self.center, YES);
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

    if (!floatingTextOnlyMode && autoCollapseEnable && !_isCollapsed && !settingsShowing && !detailShowing && !self.isShowingNotification) {
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
    if (floatingTextOnlyMode) return;
    if (_isCollapsed || self.isShowingNotification) return;
    _isCollapsed = YES;

    UIView *parent = self.superview;
    CGRect containerBounds = parent ? parent.bounds : [UIScreen mainScreen].bounds;

    // 横屏（游戏）折叠：默认迷你胶囊四段 CPU/FPS/电量/温度；开启单段开关后收成竖屏式单段（仅 CPU，不碍眼）
    BOOL isLandscapeNow = ([UIScreen mainScreen].bounds.size.width > [UIScreen mainScreen].bounds.size.height);
    CGFloat targetW = sbcpuStatusBarDockEffective() ? statusBarDockCapsuleWidth() : (isLandscapeNow ? (compactLandscapeCapsule ? 68.0f : 230.0f) : 68.0f);
    CGFloat targetH = sbcpuStatusBarDockEffective() ? statusBarDockCapsuleHeight() : (isLandscapeNow ? (compactLandscapeCapsule ? 28.0f : 30.0f) : 28.0f);
    CGFloat targetHalfW = targetW / 2.0f;
    CGFloat targetHalfH = targetH / 2.0f;

    BOOL isLeft = (self.center.x <= containerBounds.size.width / 2.0f);
    CGFloat targetX = sbcpuStatusBarDockEffective() ? (containerBounds.size.width * 0.5f) : (isLeft ? (targetHalfW + 4.0f) : (containerBounds.size.width - targetHalfW - 4.0f));
    CGFloat minY = targetHalfH + floatingTopSafeMargin(parent);
    CGFloat maxY = containerBounds.size.height - targetHalfH - 10.0f;
    CGFloat targetY = sbcpuStatusBarDockEffective() ? minY : MIN(MAX(self.center.y, minY), maxY);

    CGPoint targetCenter = CGPointMake(targetX, targetY);

    // 锁住周期性刷新，避免收起动画中 updateFloatingSize 抢改尺寸。
    self.layoutTransitionAnimating = YES;

    self.performanceContainer.hidden = NO;
    self.performanceContainer.alpha = 1.0;
    self.collapsedContainerView.hidden = NO;

    // 折叠动画使用独立的圆角变量，避免 block 捕获未声明的 cornerRad。
    CGFloat collapseCornerRad = MIN(floatingCornerRadius, targetH * 0.5f);

    void (^animationsBlock)(void) = ^{
        for (UIView *v in self.performanceContainer.subviews) {
            if (v != self.collapsedContainerView) v.alpha = 0.0;
        }
        self.horizontalDiv.alpha = 0.0;
        self.notificationContainer.alpha = 0.0;

        self.collapsedContainerView.alpha = 1.0;
        self.collapsedContainerView.frame = CGRectMake(0, 0, targetW, targetH);

        self.glassSurfaceView.frame = CGRectMake(0, 0, targetW, targetH);
        if (self->_blurView) {
            self->_blurView.frame = self.glassSurfaceView.bounds;
            self->_blurView.layer.cornerRadius = collapseCornerRad;
        }
        self.glassContentView.frame = self.glassSurfaceView.bounds;

        // 状态栏胶囊：使用可选信息条，宽度随选中项目自动扩展。
        if (sbcpuStatusBarDockEffective()) {
            _miniDockInfoLabel.hidden = NO;
            _miniDockInfoLabel.frame = CGRectMake(8, 4, targetW - 16, targetH - 8);
            _miniCpuLabel.hidden = YES;
            _miniFpsLabel.hidden = YES;
            _miniBattLabel.hidden = YES;
            _miniTempLabel.hidden = YES;
            _statusDot.hidden = YES;
        // 横屏迷你胶囊：默认 CPU / FPS / 电量 / 温度 四段；开启单段开关则仅 CPU 单段
        } else if (isLandscapeNow) {
            _miniDockInfoLabel.hidden = YES;
            _miniCpuLabel.hidden = NO;
            _miniCpuLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
            _miniCpuLabel.frame = CGRectMake(24, 5, 56, 18);
            if (!compactLandscapeCapsule) {
                _miniFpsLabel.hidden = NO;
                _miniFpsLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
                _miniFpsLabel.frame = CGRectMake(84, 5, 44, 18);
                _miniBattLabel.hidden = NO;
                _miniBattLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
                _miniBattLabel.frame = CGRectMake(130, 5, 42, 18);
                _miniTempLabel.hidden = NO;
                _miniTempLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
                _miniTempLabel.frame = CGRectMake(174, 5, 52, 18);
                _statusDot.hidden = YES;   // 横屏四段胶囊不显示状态圆点
            } else {
                // 单段：仅 CPU，字体与竖屏一致，居中于胶囊
                _miniCpuLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
                _miniCpuLabel.frame = CGRectMake(22, 5, 45, 18);
                _miniFpsLabel.hidden = YES;
                _miniBattLabel.hidden = YES;
                _miniTempLabel.hidden = YES;
                _statusDot.hidden = NO;
            }
        } else {
            _miniCpuLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
            _miniCpuLabel.frame = CGRectMake(22, 5, 45, 18);
            _miniFpsLabel.hidden = YES;
            _miniBattLabel.hidden = YES;
            _miniTempLabel.hidden = YES;
            _statusDot.hidden = NO;
        }

        CGFloat cornerRad = floatingCornerRadius;
        if (cornerRad > targetH / 2.0f) cornerRad = targetH / 2.0f;

        self.glassSurfaceView.layer.cornerRadius = cornerRad;
        self.bounds = CGRectMake(0, 0, targetW, targetH);
        self.glassContentView.frame = self.glassSurfaceView.bounds;
        [self refreshNativeLiquidGlass];
        self.center = targetCenter;

        if (!self.badgeLabel.hidden) {
            CGFloat badgeW = 20.0f;
            CGFloat targetBadgeX = isLeft ? (targetW - badgeW/2.0f - 4.0f) : (-badgeW/2.0f + 4.0f);
            self.badgeLabel.frame = CGRectMake(targetBadgeX, -6.0f, badgeW, 14.0f);
        }

        self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, targetW, targetH) cornerRadius:cornerRad].CGPath;
        CGPathRef marqueePath = [UIBezierPath bezierPathWithRoundedRect:self.glassSurfaceView.bounds cornerRadius:cornerRad].CGPath;
        self.marqueeLayer.frame = self.glassSurfaceView.bounds;
        self.marqueeLayer.path = marqueePath;
        self.marqueeFlowLayerA.frame = self.glassSurfaceView.bounds;
        self.marqueeFlowLayerA.path = marqueePath;
        self.marqueeFlowLayerB.frame = self.glassSurfaceView.bounds;
        self.marqueeFlowLayerB.path = marqueePath;

        // 液态玻璃 specular 高光层与边缘光跟随折叠尺寸
        if (self.glassBackdropLayer) {
            self.glassBackdropLayer.frame = self.glassSurfaceView.bounds;
            self.glassBackdropLayer.cornerRadius = cornerRad;
        }
        if (self.glassTintLayer) {
            self.glassTintLayer.frame = self.glassSurfaceView.bounds;
            self.glassTintLayer.cornerRadius = cornerRad;
        }
        self.glassSheenLayer.frame = self.glassSurfaceView.bounds;
        self.glassSheenMask.frame = self.glassSurfaceView.bounds;
        self.glassSheenMask.cornerRadius = cornerRad;
        self.glassBoostLayer.frame = self.glassSurfaceView.bounds;
        self.glassBoostMask.frame = self.glassSurfaceView.bounds;
        self.glassBoostMask.cornerRadius = cornerRad;
        self.glassEdgeLayer.frame = self.glassSurfaceView.bounds;
        self.glassEdgeLayer.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(self.glassSurfaceView.bounds, 0.5f, 0.5f) cornerRadius:cornerRad].CGPath;
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
        self.layoutTransitionAnimating = NO;
        updateFloatingSize();
    };

    if (animated) {
        // 折叠动画期间不要人为显示 notificationContainer，否则消息到达时会和折叠动画竞争。
        self.collapsedContainerView.hidden = NO;
        self.collapsedContainerView.alpha = 0.0;
        self.notificationContainer.hidden = YES;
        self.notificationContainer.alpha = 0.0;
        self.horizontalDiv.hidden = YES;
        self.horizontalDiv.alpha = 0.0;

        // V4.35：收起同样取消 overshoot，避免玻璃框先弹大再缩回。
        [UIView animateWithDuration:0.26
                              delay:0
                            options:UIViewAnimationOptionAllowUserInteraction |
                                    UIViewAnimationOptionBeginFromCurrentState |
                                    UIViewAnimationOptionCurveEaseInOut
                         animations:animationsBlock
                         completion:completionBlock];
    } else {
        animationsBlock();
        completionBlock(YES);
    }
}

// 旋转后已折叠状态的尺寸/布局自适应（无动画）：横屏=迷你四段，竖屏=单段
- (void)syncCollapsedLayoutForOrientation {
    if (!self.isCollapsed || self.isShowingNotification) return;
    BOOL isLandscapeNow = ([UIScreen mainScreen].bounds.size.width > [UIScreen mainScreen].bounds.size.height);
    CGFloat targetW = sbcpuStatusBarDockEffective() ? statusBarDockCapsuleWidth() : (isLandscapeNow ? (compactLandscapeCapsule ? 68.0f : 230.0f) : 68.0f);
    CGFloat targetH = sbcpuStatusBarDockEffective() ? statusBarDockCapsuleHeight() : (isLandscapeNow ? (compactLandscapeCapsule ? 28.0f : 30.0f) : 28.0f);
    UIView *parent = self.superview;
    CGRect containerBounds = parent ? parent.bounds : [UIScreen mainScreen].bounds;
    CGFloat halfW = targetW / 2.0f;
    CGFloat halfH = targetH / 2.0f;
    BOOL isLeft = (self.center.x <= containerBounds.size.width / 2.0f);
    CGFloat targetX = sbcpuStatusBarDockEffective() ? (containerBounds.size.width * 0.5f) : (isLeft ? (halfW + 4.0f) : (containerBounds.size.width - halfW - 4.0f));
    CGFloat minY = halfH + floatingTopSafeMargin(parent);
    CGFloat maxY = containerBounds.size.height - halfH - 10.0f;
    CGFloat targetY = sbcpuStatusBarDockEffective() ? minY : MIN(MAX(self.center.y, minY), maxY);

    self.collapsedContainerView.frame = CGRectMake(0, 0, targetW, targetH);
    self.glassSurfaceView.frame = CGRectMake(0, 0, targetW, targetH);
    self.glassContentView.frame = self.glassSurfaceView.bounds;
    [self refreshNativeLiquidGlass];
    CGFloat cornerRad = floatingCornerRadius;
    if (cornerRad > targetH / 2.0f) cornerRad = targetH / 2.0f;
    self.glassSurfaceView.layer.cornerRadius = cornerRad;
    self.bounds = CGRectMake(0, 0, targetW, targetH);
    if (!sbcpuStatusBarDockEffective() || (!self.statusDockDragging && !self.statusDockReturnTimer.valid))
        self.center = CGPointMake(targetX, targetY);

    if (sbcpuStatusBarDockEffective()) {
        _miniDockInfoLabel.hidden = NO;
        _miniDockInfoLabel.frame = CGRectMake(8, 4, targetW - 16, targetH - 8);
        _miniCpuLabel.hidden = YES;
        _miniFpsLabel.hidden = YES;
        _miniBattLabel.hidden = YES;
        _miniTempLabel.hidden = YES;
        _statusDot.hidden = YES;
        } else if (isLandscapeNow) {
            _miniDockInfoLabel.hidden = YES;
            _miniCpuLabel.hidden = NO;
            if (!compactLandscapeCapsule) {
            _miniCpuLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
            _miniCpuLabel.frame = CGRectMake(24, 5, 56, 18);
            _miniFpsLabel.hidden = NO;
            _miniFpsLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
            _miniFpsLabel.frame = CGRectMake(84, 5, 44, 18);
            _miniBattLabel.hidden = NO;
            _miniBattLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
            _miniBattLabel.frame = CGRectMake(130, 5, 42, 18);
            _miniTempLabel.hidden = NO;
            _miniTempLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
            _miniTempLabel.frame = CGRectMake(174, 5, 52, 18);
            _statusDot.hidden = YES;
        } else {
            _miniCpuLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
            _miniCpuLabel.frame = CGRectMake(22, 5, 45, 18);
            _miniFpsLabel.hidden = YES;
            _miniBattLabel.hidden = YES;
            _miniTempLabel.hidden = YES;
            _statusDot.hidden = NO;
        }
    } else {
        _miniDockInfoLabel.hidden = YES;
        _miniCpuLabel.hidden = NO;
        _miniCpuLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
        _miniCpuLabel.frame = CGRectMake(22, 5, 45, 18);
        _miniFpsLabel.hidden = YES;
        _miniBattLabel.hidden = YES;
        _miniTempLabel.hidden = YES;
        _statusDot.hidden = NO;
    }
}

- (void)expandFromEdgeAnimated:(BOOL)animated {
    if (!_isCollapsed || self.isShowingNotification) {
        [self resetInactivityTimer];
        return;
    }
    _isCollapsed = NO;
    _statusDot.hidden = YES;
    self.collapsedContainerView.hidden = NO;
    self.collapsedContainerView.alpha = 0.0;
    self.notificationContainer.hidden = YES;
    self.notificationContainer.alpha = 0.0;

    // ★ 保存折叠尺寸：展开动画需从胶囊平滑放大到完整面板（否则 bounds 瞬间跳变 = “消失再出现”）
    CGRect collapsedBounds = self.bounds;
    CGFloat collapsedCornerRad = self.glassSurfaceView.layer.cornerRadius;

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

    // ★ 动画开始前把容器恢复为折叠尺寸：展开动画从胶囊平滑放大到完整面板
    {
        CGFloat capW = collapsedBounds.size.width;
        CGFloat capH = collapsedBounds.size.height;
        self.bounds = collapsedBounds;
        self.glassSurfaceView.frame = CGRectMake(0, 0, capW, capH);
        if (self->_blurView) {
            self->_blurView.frame = self.glassSurfaceView.bounds;
            self->_blurView.layer.cornerRadius = MIN(collapsedCornerRad, capH * 0.5f);
        }
        self.glassContentView.frame = self.glassSurfaceView.bounds;
        [self refreshNativeLiquidGlass];
        self.glassSurfaceView.layer.cornerRadius = collapsedCornerRad;
        self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, capW, capH) cornerRadius:collapsedCornerRad].CGPath;
        self.marqueeLayer.frame = self.glassSurfaceView.bounds;
        self.marqueeLayer.path = [UIBezierPath bezierPathWithRoundedRect:self.glassSurfaceView.bounds cornerRadius:collapsedCornerRad].CGPath;
        if (self.glassBackdropLayer) {
            self.glassBackdropLayer.frame = self.glassSurfaceView.bounds;
            self.glassBackdropLayer.cornerRadius = collapsedCornerRad;
        }
        if (self.glassTintLayer) {
            self.glassTintLayer.frame = self.glassSurfaceView.bounds;
            self.glassTintLayer.cornerRadius = collapsedCornerRad;
        }
        self.glassSheenLayer.frame = self.glassSurfaceView.bounds;
        self.glassSheenMask.frame = self.glassSurfaceView.bounds;
        self.glassSheenMask.cornerRadius = collapsedCornerRad;
        self.glassBoostLayer.frame = self.glassSurfaceView.bounds;
        self.glassBoostMask.frame = self.glassSurfaceView.bounds;
        self.glassBoostMask.cornerRadius = collapsedCornerRad;
        self.glassEdgeLayer.frame = self.glassSurfaceView.bounds;
        self.glassEdgeLayer.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(self.glassSurfaceView.bounds, 0.5f, 0.5f) cornerRadius:collapsedCornerRad].CGPath;
    }

    CGFloat expandedCornerRad = floatingCornerRadius;
    if (expandedCornerRad > expandedH / 2.0f) expandedCornerRad = expandedH / 2.0f;

    // 锁住 1 秒刷新，避免动画中 updateFloatingSize 抢改 bounds/transform。
    self.layoutTransitionAnimating = YES;

    void (^animationsBlock)(void) = ^{
        // ★ 尺寸过渡：胶囊 → 完整面板（与收起动画对称，视觉上平滑“膨胀”展开）
        self.bounds = CGRectMake(0, 0, expandedW, expandedH);
        self.glassSurfaceView.frame = CGRectMake(0, 0, expandedW, expandedH);
        if (self->_blurView) {
            self->_blurView.frame = self.glassSurfaceView.bounds;
            self->_blurView.layer.cornerRadius = expandedCornerRad;
        }
        self.glassContentView.frame = self.glassSurfaceView.bounds;
        // Native Glass frame 由 layoutSubviews 同步；不要在尺寸动画块里重复 updateForHostView。
        self.glassSurfaceView.layer.cornerRadius = expandedCornerRad;
        self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, expandedW, expandedH) cornerRadius:expandedCornerRad].CGPath;
        CGPathRef marqueePath = [UIBezierPath bezierPathWithRoundedRect:self.glassSurfaceView.bounds cornerRadius:expandedCornerRad].CGPath;
        self.marqueeLayer.frame = self.glassSurfaceView.bounds;
        self.marqueeLayer.path = marqueePath;
        self.marqueeFlowLayerA.frame = self.glassSurfaceView.bounds;
        self.marqueeFlowLayerA.path = marqueePath;
        self.marqueeFlowLayerB.frame = self.glassSurfaceView.bounds;
        self.marqueeFlowLayerB.path = marqueePath;
        if (self.glassBackdropLayer) {
            self.glassBackdropLayer.frame = self.glassSurfaceView.bounds;
            self.glassBackdropLayer.cornerRadius = expandedCornerRad;
        }
        if (self.glassTintLayer) {
            self.glassTintLayer.frame = self.glassSurfaceView.bounds;
            self.glassTintLayer.cornerRadius = expandedCornerRad;
        }
        self.glassSheenLayer.frame = self.glassSurfaceView.bounds;
        self.glassSheenMask.frame = self.glassSurfaceView.bounds;
        self.glassSheenMask.cornerRadius = expandedCornerRad;
        self.glassBoostLayer.frame = self.glassSurfaceView.bounds;
        self.glassBoostMask.frame = self.glassSurfaceView.bounds;
        self.glassBoostMask.cornerRadius = expandedCornerRad;
        self.glassEdgeLayer.frame = self.glassSurfaceView.bounds;
        self.glassEdgeLayer.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(self.glassSurfaceView.bounds, 0.5f, 0.5f) cornerRadius:expandedCornerRad].CGPath;

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
        self.layoutTransitionAnimating = NO;
        // 动画结束后做一次无动画最终同步，确保当前充电/显示项与最终尺寸一致。
        updateFloatingSize();
        [self resetInactivityTimer];
    };

    if (animated) {
        // V4.35：不使用弹簧动画。弹簧会产生明显 overshoot，正是“打开后又大一圈”的来源。
        [UIView animateWithDuration:0.28
                              delay:0
                            options:UIViewAnimationOptionAllowUserInteraction |
                                    UIViewAnimationOptionBeginFromCurrentState |
                                    UIViewAnimationOptionCurveEaseOut
                         animations:animationsBlock
                         completion:completionBlock];
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

    _cpuFreqLabel.text = (cpuFreq > 100.0)
        ? [NSString stringWithFormat:@"%.0f MHz", cpuFreq]
        : @"-- MHz";
    _fpsValueLabel.text = [NSString stringWithFormat:@"%.0f", fps];
    // V4.41：顶部电量只显示百分比；充电会话增量放到下方智能停充状态行。
    _batteryValueLabel.adjustsFontSizeToFitWidth = NO;
    _batteryValueLabel.font = [UIFont monospacedDigitSystemFontOfSize:14.0 weight:UIFontWeightBold];
    double chargeDeltaMah = 0.0;
    if (isCharging && gWasExternalCharging && gActiveSession) {
        double duration = [NSDate timeIntervalSinceReferenceDate] - gSessStartTime;
        if (duration >= 5.0 && gSessBatteryMah >= 1.0) chargeDeltaMah = gSessBatteryMah;
    }
    _batteryValueLabel.text = [NSString stringWithFormat:@"%ld%%", (long)battery];
    _batterySubLabel.text = @"";
    _batterySubLabel.hidden = YES;
    _tempValueLabel.text = (temp > 0) ? [NSString stringWithFormat:@"%.1f°C", temp] : @"--°C";
    // 智能停充 = CH0I 已验证阻断外部供电；此时 AppleSmartBattery 的
    // Amperage 仍可能是设备负载电流，不应把它显示成“充电电流”。
    double displayCurrent = gSmartChargeHoldDisplay ? 0.0 : current;
    _currentValueLabel.text = [NSString stringWithFormat:@"%.0f mA", displayCurrent];

    // Reuse the existing refresh tick. Pure-text signals ignore ordinary flags
    // and never parse the long carrier/status label.
    if (floatingTextOnlyMode) {
        textOnlySignals = (textOnlyShowSIM1 || textOnlyShowSIM2) ? readAllSimSignals() : @[];
    } else if (showSignalStrength && !fastChargeStartupAnimating) {
        _signalLabel.text = getSignalInfoString();
    }

    if (!fastChargeStartupAnimating) {
        if (smartChargeEnable || blockChargingEnable || blockPowerEnable) {
            // V4.22：从 daemon 读真实引擎状态（节流 3s，避免每秒 socket）
            static double gLastStatusFetch = 0;
            static uint8_t gCachedEngineState = 0;
            static uint8_t gCachedChargeBlocked = 0;
            static uint8_t gCachedDaemonOK = 0;
            static uint8_t gCachedSmcAvailable = 1;
            static uint8_t gCachedVersion = 0;
            double now = [NSDate timeIntervalSinceReferenceDate];
            if (now - gLastStatusFetch > 3.0) {
                sb_status_t st;
                if (sbSMCGetStatus(&st)) {
                    gCachedEngineState = st.engineState;
                    gCachedChargeBlocked = st.chargeBlocked;
                    // V4.30 智能停充实际使用 CH0I，所以不能只看 chargeBlocked。
                    gSmartChargeHoldDisplay = (smartChargeEnable && st.powerBlocked);
                    gCachedDaemonOK = 1;
                    gCachedSmcAvailable = st.smcAvailable;
                    gCachedVersion = st.version;
                    smartChargeStopped = (st.chargeBlocked != 0 || st.powerBlocked != 0);
                } else {
                    gCachedDaemonOK = 0;
                    gSmartChargeHoldDisplay = NO;
                }
                gLastStatusFetch = now;
            }
            NSInteger scPercent = getBatteryPercentForSmartCharge();
            if (!gCachedDaemonOK) {
                _statusLabel.text = [NSString stringWithFormat:@"⚠️ 充电守护进程未运行 · %ld%%", (long)scPercent];
                _statusLabel.textColor = [UIColor systemRedColor];
            } else if (gCachedVersion != 0 && gCachedVersion < SB_DAEMON_VERSION) {
                _statusLabel.text = [NSString stringWithFormat:@"⚠️ 守护进程是旧版(v%d)，请注销/重启", (int)gCachedVersion];
                _statusLabel.textColor = [UIColor systemRedColor];
            } else if (!gCachedSmcAvailable || gCachedEngineState == 6) {
                // Error：daemon 在跑但 AppleSMC 打不开（通常未以 root 被 launchd 托管）
                _statusLabel.text = @"❌ AppleSMC 不可用，请重启手机";
                _statusLabel.textColor = [UIColor systemRedColor];
            } else if (gCachedEngineState == 2 || gCachedChargeBlocked) {
                // SBCPUChargeStateBlocked：手动停充/断供 或 智能停充已触发
                _statusLabel.text = [NSString stringWithFormat:@"🛑 停充中 · %ld%% (上限%ld)", (long)scPercent, (long)smartChargeUpperLimit];
                _statusLabel.textColor = [UIColor systemOrangeColor];
            } else if (gCachedEngineState == 3) {
                // OBCControlled：系统充电管理接管，未强制覆盖
                _statusLabel.text = @"⚠️ 系统充电管理(OBC)接管中";
                _statusLabel.textColor = [UIColor systemOrangeColor];
            } else if (gCachedEngineState == 5) {
                // Unsupported：无线充电暂不支持限制
                _statusLabel.text = @"⚠️ 无线充电暂不支持限制";
                _statusLabel.textColor = [UIColor systemYellowColor];
            } else if (isCharging) {
                if (chargeDeltaMah >= 1.0) {
                    _statusLabel.text = [NSString stringWithFormat:@"🔋 智能停充待触发 · %ld%%→%ld%% +%.0fmAh", (long)scPercent, (long)smartChargeUpperLimit, chargeDeltaMah];
                } else {
                    _statusLabel.text = [NSString stringWithFormat:@"🔋 智能停充待触发 · %ld%%→%ld%%", (long)scPercent, (long)smartChargeUpperLimit];
                }
                _statusLabel.textColor = [UIColor systemBlueColor];
            } else {
                _statusLabel.text = [NSString stringWithFormat:@"🔋 智能停充已启用 · %ld%%", (long)scPercent];
                _statusLabel.textColor = [UIColor systemGrayColor];
            }
        } else if (forceFastChargeEnable && isCharging) {
            NSDictionary *chargeInfo = getRealBatteryDetails();
            double watts = [chargeInfo[@"CalculatedWatts"] doubleValue];
            _statusLabel.text = [NSString stringWithFormat:@"🔋 快充辅助（安全模式） · %.1fW", MAX(0.0, watts)];
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
        _miniCpuLabel.text = [NSString stringWithFormat:@"%.0fmA", displayCurrent];
    } else if (collapsedDisplayMode == 4) {
        _miniCpuLabel.text = [NSString stringWithFormat:@"%ld%%", (long)MAX(0, MIN(100, battery))];
    }

    // 横屏迷你胶囊：旋转后自适应布局 + 实时刷新（默认四段 CPU/FPS/电量/温度；单段模式仅 CPU）
    BOOL isLandscapeNow = ([UIScreen mainScreen].bounds.size.width > [UIScreen mainScreen].bounds.size.height);
    if (self.isCollapsed) {
        [self syncCollapsedLayoutForOrientation];
        if (sbcpuStatusBarDockEffective()) {
            NSMutableArray *dockItems = [NSMutableArray array];
            if (statusDockShowCPU) [dockItems addObject:[NSString stringWithFormat:@"CPU %.0f%%", cpu]];
            if (statusDockShowFPS) [dockItems addObject:[NSString stringWithFormat:@"FPS %.0f", fps]];
            if (statusDockShowFrequency) [dockItems addObject:[NSString stringWithFormat:@"频 %.1fG", cpuFreq / 1000.0]];
            if (statusDockShowCurrent) [dockItems addObject:[NSString stringWithFormat:@"%.0fmA", displayCurrent]];
            if (statusDockShowTemperature) [dockItems addObject:(temp > 0 ? [NSString stringWithFormat:@"%.1f°", temp] : @"温 --")];
            if (statusDockShowBattery) [dockItems addObject:[NSString stringWithFormat:@"电 %ld%%", (long)MAX(0, MIN(100, battery))]];
            if (statusDockShowSIM1 || statusDockShowSIM2) {
                NSArray *sims = readAllSimSignals();
                if (statusDockShowSIM1) {
                    NSDictionary *s = sims.count > 0 ? sims[0] : nil;
                    NSString *dbm = [s[@"dbm"] description];
                    [dockItems addObject:[NSString stringWithFormat:@"S1 %@ dBm", dbm.length ? dbm : @"--"]];
                }
                if (statusDockShowSIM2) {
                    NSDictionary *s = sims.count > 1 ? sims[1] : nil;
                    NSString *dbm = [s[@"dbm"] description];
                    [dockItems addObject:[NSString stringWithFormat:@"S2 %@ dBm", dbm.length ? dbm : @"--"]];
                }
            }
            _miniDockInfoLabel.text = dockItems.count ? [dockItems componentsJoinedByString:@"  "] : @"状态栏胶囊";
            _miniDockInfoLabel.hidden = NO;
        } else if (isLandscapeNow && !compactLandscapeCapsule) {
            _miniCpuLabel.text = [NSString stringWithFormat:@"%.0f%%", cpu];
            _miniFpsLabel.text = [NSString stringWithFormat:@"%.0fF", fps];
            _miniBattLabel.text = [NSString stringWithFormat:@"%ld%%", (long)MAX(0, MIN(100, battery))];
            _miniTempLabel.text = (temp > 0) ? [NSString stringWithFormat:@"%.0f°", temp] : @"--°";
        }
    }

    if (YES) {
        UIColor *statusColor = [UIColor darkGrayColor];
        if (isCharging) {
            if (forceFastChargeEnable) statusColor = [UIColor systemRedColor];
            else statusColor = chargeBoostEnable ? [UIColor systemBlueColor] : [UIColor colorWithRed:0.0f green:0.8f blue:0.4f alpha:1.0f];
        } else if (cpu >= 80.0 || temp >= 42.0) statusColor = [UIColor systemRedColor];
        else if (temp >= 38.0) statusColor = [UIColor systemOrangeColor];
        _statusDot.backgroundColor = statusColor;
        // Refresh must agree with collapsed layout: top status text has no dot.
        // Keep the ordinary folded dot and all capsule dimensions/positions unchanged.
        BOOL dotLandscape = ([UIScreen mainScreen].bounds.size.width > [UIScreen mainScreen].bounds.size.height);
        _statusDot.hidden = SBCPUStatusDotHidden(self.isCollapsed, sbcpuStatusBarDockEffective(), dotLandscape);
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

// ============================================================
// 蜂窝网络详情页（可滚动，按 SIM 卡分组 + 设备基带信息）
// ============================================================
@interface SBCPUCellularDetailController : UITableViewController
@property (nonatomic, strong) NSMutableArray *sections;
@property (nonatomic, strong) NSTimer *cellRefreshTimer;
@end

@implementation SBCPUCellularDetailController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _sections = [NSMutableArray array];
        self.title = @"蜂窝网络详情";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.tableView.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(closeCellular)];
    [self rebuildCellularData];
}

- (void)closeCellular {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self rebuildCellularData];
    _cellRefreshTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 target:self
                                                       selector:@selector(rebuildCellularData) userInfo:nil repeats:YES];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [_cellRefreshTimer invalidate];
    _cellRefreshTimer = nil;
}

- (void)rebuildCellularData {
    @try {
        NSMutableArray *secs = [NSMutableArray array];
        NSArray *sims = readAllSimSignals();
        NSArray *equip = readMobileEquipmentInfo();

        for (NSDictionary *s in sims) {
            NSInteger slot = [s[@"slot"] integerValue];
            NSDictionary *cell = cellInfoForSlot(slot);
            NSString *name = s[@"carrier"] ?: [NSString stringWithFormat:@"SIM%ld", (long)slot];
            NSMutableArray *rows = [NSMutableArray array];
            void (^add)(NSString *, NSString *) = ^(NSString *k, NSString *v) {
                if (v && v.length > 0) [rows addObject:@{@"k": k, @"v": v}];
            };

            // —— 网络状态 ——
            NSString *mode = s[@"tech"] ?: @"无服务";
            if ([s[@"tech"] isEqual:@"5G"]) {
                mode = [s[@"sa"] boolValue] ? @"5G SA 独立组网"
                     : (([s[@"nsa"] boolValue] || [s[@"nr"] boolValue]) ? @"5G NSA 非独立组网" : @"5G");
            }
            add(@"网络制式", mode);
            add(@"运营商", name);
            add(@"网络注册", [s[@"attached"] boolValue] ? @"已注册" : @"未注册/无服务");
            add(@"默认数据卡", [s[@"dataSim"] boolValue] ? @"是" : @"否");
            add(@"漫游状态", [s[@"roaming"] boolValue] ? @"漫游中" : @"归属网络");

            // —— 信号质量 ——
            NSInteger bars = [s[@"bars"] integerValue];
            add(@"信号格数", bars >= 0 ? [NSString stringWithFormat:@"%ld/4", (long)bars] : @"--");
            if (s[@"dbm"]) add(@"RSRP/RSSI 强度", [NSString stringWithFormat:@"%@ dBm", s[@"dbm"]]);
            if (s[@"rsrq"]) add(@"RSRQ 质量", [NSString stringWithFormat:@"%@ dB", s[@"rsrq"]]);
            if (s[@"snr"]) add(@"SNR 信噪比", [NSString stringWithFormat:@"%@ dB", s[@"snr"]]);

            // —— 基站无线参数（copyCellInfo 异步缓存，可能稍后才出现）——
            NSString *band = bandStringForSlot(slot, s[@"tech"]);
            add(@"频段", band);
            if (cell[@"bandwidth"]) add(@"载波带宽(PRB)", [cell[@"bandwidth"] stringValue]);
            if (cell[@"nrarfcn"]) add(@"5G 频点 NR-ARFCN", [cell[@"nrarfcn"] stringValue]);
            if (cell[@"uarfcn"]) add(@"频点 UARFCN", [cell[@"uarfcn"] stringValue]);
            if (cell[@"pci"]) add(@"物理小区号 PCI", [cell[@"pci"] stringValue]);
            if (cell[@"cellid"]) add(@"小区 ID", [cell[@"cellid"] stringValue]);
            if (cell[@"tac"]) add(@"跟踪区码 TAC", [cell[@"tac"] stringValue]);
            if (cell[@"scs"]) add(@"子载波间隔", [NSString stringWithFormat:@"%@ kHz", [cell[@"scs"] stringValue]]);
            if (cell[@"mcc"] && cell[@"mnc"])
                add(@"MCC/MNC", [NSString stringWithFormat:@"%@/%@", [cell[@"mcc"] stringValue], [cell[@"mnc"] stringValue]]);

            // —— 卡硬件信息（按卡槽对应）——
            if (slot - 1 >= 0 && slot - 1 < (NSInteger)equip.count) {
                NSDictionary *e = equip[slot - 1];
                add(@"ICCID", e[@"iccid"]);
                add(@"IMEI", e[@"imei"]);
            }

            NSString *title = [NSString stringWithFormat:@"SIM %ld · %@%@", (long)slot, name,
                               [s[@"dataSim"] boolValue] ? @" · 默认数据卡" : @""];
            [secs addObject:@{@"title": title, @"rows": rows}];
        }

        // —— 设备基带信息 ——
        NSMutableArray *drows = [NSMutableArray array];
        [drows addObject:@{@"k": @"卡槽数量", @"v": [NSString stringWithFormat:@"%lu", (unsigned long)sims.count]}];
        NSInteger idx = 1;
        for (NSDictionary *e in equip) {
            if (e[@"imei"]) [drows addObject:@{@"k": [NSString stringWithFormat:@"IMEI %ld", (long)idx], @"v": e[@"imei"]}];
            if (e[@"meid"]) [drows addObject:@{@"k": @"MEID", @"v": e[@"meid"]}];
            if (e[@"eid"]) [drows addObject:@{@"k": @"EID (eSIM)", @"v": e[@"eid"]}];
            idx++;
        }
        if (drows.count > 1) [secs addObject:@{@"title": @"设备基带信息", @"rows": drows}];

        // 网络工具入口
        [secs addObject:@{@"title": @"网络工具",
                          @"rows": @[@{@"k": @"设置网络频段 (Beta)", @"v": @"锁定 5G/4G/3G/2G 频段"}]}];

        self.sections = secs;
        [self.tableView reloadData];
    } @catch (NSException *e) {}
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return self.sections.count; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    return [self.sections[section][@"rows"] count];
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    return self.sections[section][@"title"];
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"SBCell"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"SBCell"];
    NSDictionary *row = self.sections[ip.section][@"rows"][ip.row];
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.textLabel.text = row[@"k"];
    cell.detailTextLabel.text = row[@"v"];
    cell.textLabel.font = [UIFont systemFontOfSize:14];
    cell.detailTextLabel.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightMedium];
    cell.textLabel.textColor = [UIColor secondaryLabelColor];
    cell.detailTextLabel.textColor = [UIColor labelColor];
    cell.detailTextLabel.adjustsFontSizeToFitWidth = YES;
    cell.detailTextLabel.minimumScaleFactor = 0.6;
    cell.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];

    // 网络工具入口行
    if ([self.sections[ip.section][@"title"] isEqual:@"网络工具"]) {
        cell.textLabel.textColor = [UIColor labelColor];
        cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (![self.sections[ip.section][@"title"] isEqual:@"网络工具"]) return;
    @try {
        Class cls = NSClassFromString(@"SBCPUBandSelectController");
        if (!cls) return;
        UIViewController *vc = [[cls alloc] init];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        nav.modalPresentationStyle = UIModalPresentationPageSheet;
        [self presentViewController:nav animated:YES completion:nil];
    } @catch (NSException *e) {}
}

@end

#pragma mark - 网络频段锁定（Beta）

// RAT 分组（判定顺序与参考源码一致；返回值同时是 UI 排序：NR0 LTE1 WCDMA2 TD3 CDMA4 GSM5）
static NSInteger bandRatGroup(NSString *key) {
    NSString *k = key.uppercaseString;
    if ([k containsString:@"LTE"]) return 1;
    if ([k containsString:@"NR"]) return 0;
    if ([k containsString:@"GSM"]) return 5;
    if ([k containsString:@"UTRAN"]) return 2;
    if ([k containsString:@"TDSCDMA"]) return 3;
    if ([k containsString:@"CDMA"]) return 4;
    return 6;
}
static NSString *bandRatDisplayName(NSInteger g) {
    switch (g) {
        case 0: return @"5G (NR)";
        case 1: return @"4G (LTE)";
        case 2: return @"3G (UMTS/WCDMA)";
        case 3: return @"3G (TD-SCDMA)";
        case 4: return @"3G (CDMA)";
        case 5: return @"2G (GSM)";
        default: return @"其它";
    }
}
static NSString *bandItemDisplayName(NSInteger g, NSInteger v) {
    switch (g) {
        case 0: return [NSString stringWithFormat:@"n%ld", (long)v];
        case 1: return [NSString stringWithFormat:@"B%ld", (long)v];
        case 3: return [NSString stringWithFormat:@"TD %ld", (long)v];
        case 4: return [NSString stringWithFormat:@"BC%ld", (long)v];
        default: return [NSString stringWithFormat:@"%ld", (long)v];
    }
}

@interface SBCPUBandSelectController : UITableViewController
@property (nonatomic, assign) NSInteger currentSlot;
@property (nonatomic, assign) NSInteger slotCount;
@property (nonatomic, strong) id originalBandInfo;
@property (nonatomic, strong) NSMutableArray<NSString *> *ratKeys;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *supportedMap;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableSet<NSNumber *> *> *activeMap;
@property (nonatomic, copy) NSString *loadError;
@property (nonatomic, strong) UISegmentedControl *slotSeg;
@end

@implementation SBCPUBandSelectController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _currentSlot = 1;
        _ratKeys = [NSMutableArray array];
        _supportedMap = [NSMutableDictionary dictionary];
        _activeMap = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"网络频段锁定";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.tableView.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(closeBand)];

    _slotCount = (NSInteger)readAllSimSignals().count;
    if (_slotCount < 1) _slotCount = 1;
    NSMutableArray *items = [NSMutableArray array];
    for (NSInteger i = 1; i <= _slotCount; i++) [items addObject:[NSString stringWithFormat:@"卡%ld", (long)i]];
    _slotSeg = [[UISegmentedControl alloc] initWithItems:items];
    _slotSeg.selectedSegmentIndex = 0;
    [_slotSeg addTarget:self action:@selector(slotChanged:) forControlEvents:UIControlEventValueChanged];
    _slotSeg.frame = CGRectMake(0, 0, 150, 32);
    self.navigationItem.titleView = _slotSeg;

    [self loadSlotData];
}

- (void)closeBand { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)slotChanged:(UISegmentedControl *)seg {
    _currentSlot = seg.selectedSegmentIndex + 1;
    [self loadSlotData];
}

- (void)loadSlotData {
    _loadError = nil;
    [_ratKeys removeAllObjects];
    [_supportedMap removeAllObjects];
    [_activeMap removeAllObjects];
    _originalBandInfo = nil;

    NSError *err = nil;
    id info = readBandInfoForSlot(_currentSlot, &err);
    if (!info) {
        _loadError = err.localizedDescription ?: @"读取频段失败（可能无基带控制权限）";
        [self showErrorEmpty];
        [self.tableView reloadData];
        return;
    }
    _originalBandInfo = info;

    NSDictionary *supported = [info valueForKey:@"fSupportedBands"];
    NSDictionary *active = [info valueForKey:@"fActiveBands"];

    // 仅展示设备支持、且属于已知制式的 RAT
    NSMutableArray *keys = [NSMutableArray array];
    if ([supported isKindOfClass:[NSDictionary class]]) {
        for (NSString *key in supported.allKeys) {
            NSArray *vals = supported[key];
            if (![vals isKindOfClass:[NSArray class]] || vals.count == 0) continue;
            if (bandRatGroup(key) >= 6) continue; // 未知制式不展示，保存时原样保留
            [keys addObject:key];
        }
    }
    [keys sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSInteger ga = bandRatGroup(a), gb = bandRatGroup(b);
        if (ga != gb) return ga < gb ? NSOrderedAscending : NSOrderedDescending;
        return [a compare:b];
    }];
    [_ratKeys setArray:keys];

    for (NSString *key in keys) {
        NSArray *raw = supported[key];
        NSMutableArray<NSNumber *> *nums = [NSMutableArray array];
        for (id v in raw) if ([v isKindOfClass:[NSNumber class]]) [nums addObject:v];
        [nums sortUsingSelector:@selector(compare:)];
        _supportedMap[key] = nums;

        NSMutableSet<NSNumber *> *sel = [NSMutableSet set];
        NSArray *act = [active isKindOfClass:[NSDictionary class]] ? active[key] : nil;
        if ([act isKindOfClass:[NSArray class]]) {
            for (id v in act) if ([v isKindOfClass:[NSNumber class]]) [sel addObject:v];
        }
        _activeMap[key] = sel;
    }
    self.tableView.backgroundView = nil;
    [self.tableView reloadData];
}

- (void)showErrorEmpty {
    UILabel *lab = [[UILabel alloc] initWithFrame:CGRectMake(24, 120, self.view.bounds.size.width - 48, 200)];
    lab.numberOfLines = 0;
    lab.textAlignment = NSTextAlignmentCenter;
    lab.font = [UIFont systemFontOfSize:15];
    lab.textColor = [UIColor secondaryLabelColor];
    lab.text = [NSString stringWithFormat:@"无法读取/设置网络频段\n\n%@\n\n若提示权限错误，说明当前注入环境缺少\nCommCenter 基带控制授权（SPI）。", _loadError ?: @""];
    self.tableView.backgroundView = lab;
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return _loadError ? 0 : _ratKeys.count + 1; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    if (section < (NSInteger)_ratKeys.count) return 1;
    return 2; // 保存 / 恢复默认
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    if (section < (NSInteger)_ratKeys.count) return bandRatDisplayName(bandRatGroup(_ratKeys[section]));
    return nil;
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section < (NSInteger)_ratKeys.count) {
        NSArray *bands = _supportedMap[_ratKeys[ip.section]];
        NSInteger cols = 4;
        NSInteger rows = (bands.count + cols - 1) / cols;
        return rows * 46.0 + 14;
    }
    return 50;
}

- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)section {
    if (section >= (NSInteger)_ratKeys.count) return nil;
    UIView *hv = [[UIView alloc] initWithFrame:CGRectMake(0, 0, tv.bounds.size.width, 36)];
    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(16, 6, 200, 24)];
    t.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    t.textColor = [UIColor secondaryLabelColor];
    t.text = bandRatDisplayName(bandRatGroup(_ratKeys[section]));
    [hv addSubview:t];
    UIButton *all = [UIButton buttonWithType:UIButtonTypeSystem];
    all.frame = CGRectMake(tv.bounds.size.width - 150, 6, 60, 24);
    [all setTitle:@"全选" forState:UIControlStateNormal];
    all.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    all.tag = section;
    [all addTarget:self action:@selector(selectAllBands:) forControlEvents:UIControlEventTouchUpInside];
    [hv addSubview:all];
    UIButton *none = [UIButton buttonWithType:UIButtonTypeSystem];
    none.frame = CGRectMake(tv.bounds.size.width - 86, 6, 70, 24);
    [none setTitle:@"全不选" forState:UIControlStateNormal];
    none.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    none.tag = section;
    [none addTarget:self action:@selector(selectNoBands:) forControlEvents:UIControlEventTouchUpInside];
    [hv addSubview:none];
    return hv;
}

- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)section {
    return (section < (NSInteger)_ratKeys.count) ? 38 : 18;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section < (NSInteger)_ratKeys.count) {
        UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"bandgrid"];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"bandgrid"];
        for (UIView *v in cell.contentView.subviews.copy) [v removeFromSuperview];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];

        NSString *key = _ratKeys[ip.section];
        NSInteger g = bandRatGroup(key);
        NSArray<NSNumber *> *bands = _supportedMap[key];
        NSSet<NSNumber *> *sel = _activeMap[key];
        NSInteger cols = 4;
        CGFloat w = cell.contentView.bounds.size.width;
        if (w < 10) w = tv.bounds.size.width - 32;
        CGFloat colW = w / cols;
        NSInteger idx = 0;
        for (NSNumber *b in bands) {
            NSInteger r = idx / cols, c = idx % cols;
            UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
            btn.frame = CGRectMake(c * colW, 7 + r * 46, colW, 40);
            btn.tag = ip.section * 10000 + b.integerValue;
            BOOL on = [sel containsObject:b];
            [btn setTitle:bandItemDisplayName(g, b.integerValue) forState:UIControlStateNormal];
            [btn setImage:[UIImage systemImageNamed:on ? @"checkmark.circle.fill" : @"circle"] forState:UIControlStateNormal];
            btn.tintColor = on ? [UIColor systemBlueColor] : [UIColor tertiaryLabelColor];
            [btn setTitleColor:on ? [UIColor labelColor] : [UIColor secondaryLabelColor] forState:UIControlStateNormal];
            btn.titleLabel.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:on ? UIFontWeightSemibold : UIFontWeightRegular];
            btn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
            btn.semanticContentAttribute = UISemanticContentAttributeForceLeftToRight;
            [btn addTarget:self action:@selector(toggleBand:) forControlEvents:UIControlEventTouchUpInside];
            [cell.contentView addSubview:btn];
            idx++;
        }
        return cell;
    }

    // 操作区
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"bandaction"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"bandaction"];
    cell.textLabel.textAlignment = NSTextAlignmentCenter;
    if (ip.row == 0) {
        cell.textLabel.text = @"保存并应用频段锁定";
        cell.textLabel.textColor = [UIColor systemBlueColor];
    } else {
        cell.textLabel.text = @"恢复默认（启用全部支持频段）";
        cell.textLabel.textColor = [UIColor systemRedColor];
    }
    cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    cell.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == (NSInteger)_ratKeys.count) {
        if (ip.row == 0) [self saveBands];
        else [self confirmRestore];
    }
}

#pragma mark - 勾选

- (void)toggleBand:(UIButton *)btn {
    NSInteger section = btn.tag / 10000;
    NSInteger band = btn.tag % 10000;
    if (section >= (NSInteger)_ratKeys.count) return;
    NSString *key = _ratKeys[section];
    NSMutableSet *set = _activeMap[key];
    NSNumber *b = @(band);
    if ([set containsObject:b]) [set removeObject:b]; else [set addObject:b];
    BOOL on = [set containsObject:b];
    [btn setImage:[UIImage systemImageNamed:on ? @"checkmark.circle.fill" : @"circle"] forState:UIControlStateNormal];
    btn.tintColor = on ? [UIColor systemBlueColor] : [UIColor tertiaryLabelColor];
    [btn setTitleColor:on ? [UIColor labelColor] : [UIColor secondaryLabelColor] forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:on ? UIFontWeightSemibold : UIFontWeightRegular];
}

- (void)selectAllBands:(UIButton *)btn {
    NSString *key = _ratKeys[btn.tag];
    [_activeMap[key] addObjectsFromArray:_supportedMap[key]];
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:btn.tag] withRowAnimation:UITableViewRowAnimationNone];
}
- (void)selectNoBands:(UIButton *)btn {
    NSString *key = _ratKeys[btn.tag];
    [_activeMap[key] removeAllObjects];
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:btn.tag] withRowAnimation:UITableViewRowAnimationNone];
}

#pragma mark - 下发

- (void)saveBands {
    if (!_originalBandInfo) { [self alertTitle:@"无法保存" msg:@"频段数据未加载"]; return; }
    @try {
        NSMutableDictionary *updated = nil;
        id origActive = [_originalBandInfo valueForKey:@"fActiveBands"];
        if ([origActive respondsToSelector:@selector(mutableCopy)]) {
            updated = [origActive mutableCopy];
        }
        if (!updated) updated = [NSMutableDictionary dictionary];
        // 仅覆盖设备支持的 RAT；其它/未知制式原样保留，避免误删
        for (NSString *key in _supportedMap.allKeys) {
            NSSet *sel = _activeMap[key];
            NSMutableArray *vals = [NSMutableArray arrayWithArray:sel.allObjects];
            [vals sortUsingSelector:@selector(compare:)];
            updated[key] = vals;
        }
        [_originalBandInfo setValue:updated forKey:@"fActiveBands"];
        NSError *err = nil;
        BOOL ok = writeActiveBandInfoForSlot(_currentSlot, _originalBandInfo, &err);
        if (ok) {
            [self alertTitle:@"已应用" msg:@"频段锁定已下发到基带。若信号异常可点“恢复默认”。"];
            [self performSelector:@selector(loadSlotData) withObject:nil afterDelay:0.6];
        } else {
            [self alertTitle:@"下发失败" msg:[NSString stringWithFormat:@"%@（错误码 %ld）",
                err.localizedDescription ?: @"基带拒绝了该设置", (long)err.code]];
        }
    } @catch (NSException *e) {
        [self alertTitle:@"异常" msg:e.reason ?: e.name];
    }
}

- (void)confirmRestore {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"恢复默认频段"
        message:@"将启用本机支持的全部频段（解除锁定），确定？" preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"恢复" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *_) {
        [self restoreDefault];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)restoreDefault {
    if (!_originalBandInfo) { [self alertTitle:@"无法恢复" msg:@"频段数据未加载"]; return; }
    @try {
        id supported = [_originalBandInfo valueForKey:@"fSupportedBands"];
        NSMutableDictionary *copy = [supported respondsToSelector:@selector(mutableCopy)] ? [supported mutableCopy] : nil;
        [_originalBandInfo setValue:(copy ?: supported) forKey:@"fActiveBands"];
        NSError *err = nil;
        BOOL ok = writeActiveBandInfoForSlot(_currentSlot, _originalBandInfo, &err);
        if (ok) {
            [self alertTitle:@"已恢复" msg:@"已启用全部支持频段。"];
            [self performSelector:@selector(loadSlotData) withObject:nil afterDelay:0.6];
        } else {
            [self alertTitle:@"恢复失败" msg:[NSString stringWithFormat:@"%@（错误码 %ld）",
                err.localizedDescription ?: @"基带拒绝", (long)err.code]];
        }
    } @catch (NSException *e) {
        [self alertTitle:@"异常" msg:e.reason ?: e.name];
    }
}

- (void)alertTitle:(NSString *)title msg:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

@end

#pragma mark - 系统与电池详细状态面板

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
    CGFloat panelH = MIN(screenH - margin * 4, 436.0);

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

    // 蜂窝网络详情入口
    UIButton *cellBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    cellBtn.frame = CGRectMake(panelW - 100, 9, 58, 28);
    [cellBtn setTitle:@"蜂窝详情" forState:UIControlStateNormal];
    cellBtn.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    [cellBtn setTitleColor:[UIColor colorWithRed:0.0 green:0.45 blue:0.9 alpha:1.0] forState:UIControlStateNormal];
    cellBtn.backgroundColor = [UIColor colorWithRed:0.0 green:0.45 blue:0.9 alpha:0.10];
    cellBtn.layer.cornerRadius = 13.0;
    cellBtn.layer.masksToBounds = YES;
    [cellBtn addTarget:self action:@selector(openCellularDetail) forControlEvents:UIControlEventTouchUpInside];
    [contentView addSubview:cellBtn];

    UIView *line = [[UIView alloc] initWithFrame:CGRectMake(0, 40, panelW, 0.5)];
    line.backgroundColor = [UIColor colorWithWhite:0 alpha:0.1];
    [contentView addSubview:line];

    CGFloat colW = (panelW - 20) / 2.0;
    CGFloat startY = 46.0;
    CGFloat rowH = 22.0;

    NSArray *leftKeys = @[
        @"电池健康程度", @"电池循环次数", @"电池预计充满", @"电池充电类型",
        @"电池充电功率", @"充电器输入功率", @"本次充入", @"无线充电功率",
        @"充电器信息", @"停充状态",
        @"电池当前电流", @"电池当前电压", @"电池当前温度",
        @"电池当前电量", @"电池设计容量", @"电池实际容量", @"电池当前容量"
    ];

    NSArray *rightKeys = @[
        @"设备名称", @"软件版本", @"网络信息", @"内网地址",
        @"实时网速", @"系统总 CPU", @"CPU主频 / FPS", @"内存可用",
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
    UILabel *dataNote = [[UILabel alloc] initWithFrame:CGRectMake(10 + colW, startY + rightKeys.count * rowH + 5, colW - 12, 52)];
    dataNote.text = @"内存可用含可回收页，为系统级估算；MiB/GiB 按 1024 换算。电池厂商为硬件上报，不能据此验证零售品牌或是否原装；充满时间仅供参考。";
    dataNote.font = [UIFont systemFontOfSize:8.5];
    dataNote.textColor = [UIColor darkGrayColor];
    dataNote.numberOfLines = 0;
    [contentView addSubview:dataNote];
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
    valLbl.minimumScaleFactor = 0.4;
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

// 打开蜂窝网络详情页（基站/信号/网络状态/基带设备信息）
- (void)openCellularDetail {
    @try {
        SBCPUCellularDetailController *vc = [[SBCPUCellularDetailController alloc] init];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        nav.modalPresentationStyle = UIModalPresentationPageSheet;
        nav.modalTransitionStyle = UIModalTransitionStyleCoverVertical;
        [self presentViewController:nav animated:YES completion:nil];
    } @catch (NSException *e) {}
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

    // The registry reports a manufacturer, not an authenticated retail brand.
    // Missing fields must not be silently presented as an original Apple battery.
    NSString *mfg = SBCPUBatteryManufacturer(batInfo[@"Manufacturer"]);
    NSNumber *reportedFull = SBCPUBatteryNumber(batInfo[@"MaxCapacity"]);
    NSString *healthText = reportedFull.doubleValue > 100.0 ? [NSString stringWithFormat:@"%.0f%%", health] : @"健康度未知";
    _labelsDict[@"电池健康程度"].text = [NSString stringWithFormat:@"%@ · %@", healthText, mfg];

    NSInteger cycles = [batInfo[@"CycleCount"] integerValue];
    _labelsDict[@"电池循环次数"].text = [NSString stringWithFormat:@"%ld次", (long)cycles];

    BOOL charging = isChargingInternal();
    _labelsDict[@"电池预计充满"].text = SBCPUBatteryETAText(batInfo[@"SBCPUEtaSnapshot"],
        batInfo[@"SBCPUEtaHistory"] ?: @[], [NSProcessInfo processInfo].systemUptime);

    NSNumber *ratedWatts = batInfo[@"Watts"];
    NSString *chargerTypeStr = batInfo[@"ChargerType"] ?: @"PD 快充";
    if ([ratedWatts isKindOfClass:[NSNumber class]] && [ratedWatts doubleValue] > 0) {
        chargerTypeStr = [NSString stringWithFormat:@"%@ · %ldW", chargerTypeStr, (long)[ratedWatts integerValue]];
    }
    _labelsDict[@"电池充电类型"].text = charging ? chargerTypeStr : @"未充电";

    double watts = [batInfo[@"CalculatedWatts"] doubleValue];
    if (watts < 0.1) watts = 0.0;
    _labelsDict[@"电池充电功率"].text = charging ? [NSString stringWithFormat:@"%.1fW%@", watts, (chargeBoostEnable || forceFastChargeEnable) ? @" · 增强" : @""] : @"0W";

    // 充电器输入功率（USB 口 V×A，HID 传感器）—— 充电器实际输出，比电池侧功率高 15~25%
    double inputW = getChargerInputPower();
    if (inputW > 0.1) {
        NSString *boostTag = (chargeBoostEnable || forceFastChargeEnable) ? @" · 增强" : @"";
        NSString *utilTag = @"";
        double util = getChargerUtilisationPercent();
        if (util >= 0) utilTag = [NSString stringWithFormat:@" · 利用率%.0f%%", util];
        NSString *effTag = @"";
        if (watts > 0.5 && inputW > 0.5) {
            double eff = MIN(watts / inputW * 100.0, 100.0);
            effTag = [NSString stringWithFormat:@" · 转换%.0f%%", eff];
        }
        _labelsDict[@"充电器输入功率"].text = [NSString stringWithFormat:@"%.1fW%@%@%@", inputW, boostTag, utilTag, effTag];
    } else {
        _labelsDict[@"充电器输入功率"].text = charging ? @"读取中..." : @"未充电";
    }

    // 充电器信息：名称 · 额定功率 · PD 档位
    NSString *adapterInfo = getAdapterInfoString();
    _labelsDict[@"充电器信息"].text = adapterInfo;

    // 本次充入（充电会话积分）
    _labelsDict[@"本次充入"].text = getCurrentChargeAmountString();

    // 无线充电功率（MagSafe 线圈 V×A）
    double wirelessW = getWirelessChargePower();
    _labelsDict[@"无线充电功率"].text = wirelessW > 0.5 ?
        [NSString stringWithFormat:@"%.1fW", wirelessW] : (charging ? @"未使用" : @"未充电");

    // 停充状态：实测验证（外部连接+未充电+电流<0.3A → 已停充/保持）
    BOOL holding = isChargingOnHold();
    if (smartChargeEnable) {
        if (smartChargeStopped || holding) {
            _labelsDict[@"停充状态"].text = @"✅ 已停充 · 实测电流≈0";
        } else {
            _labelsDict[@"停充状态"].text = [NSString stringWithFormat:@"待触发 · %ld%%", (long)batPercent];
        }
    } else {
        _labelsDict[@"停充状态"].text = holding ? @"系统优化充电保持中" : @"未启用";
    }

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

    _labelsDict[@"内存可用"].text = @"读取失败";
    uint64_t kernelTotalBytes = 0;
    size_t kernelTotalSize = sizeof(kernelTotalBytes);
    if (sysctlbyname("hw.memsize", &kernelTotalBytes, &kernelTotalSize, NULL, 0) != 0 || kernelTotalSize != sizeof(kernelTotalBytes))
        kernelTotalBytes = 0;
    uint64_t physicalTotalBytes = [NSProcessInfo processInfo].physicalMemory;
    mach_port_t hostPort = mach_host_self();
    vm_size_t pageSize = 0;
    vm_statistics64_data_t vmStat;
    memset(&vmStat, 0, sizeof(vmStat));
    mach_msg_type_number_t hostSize = HOST_VM_INFO64_COUNT;
    kern_return_t statisticsResult = KERN_FAILURE;
    if (host_page_size(hostPort, &pageSize) == KERN_SUCCESS && pageSize > 0)
        statisticsResult = host_statistics64(hostPort, HOST_VM_INFO64, (host_info64_t)&vmStat, &hostSize);
    if (hostPort != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), hostPort);
    SBCPUMemoryPageCounters counters = {0, 0, 0, 0};
    SBCPUMemoryMetrics metrics;
    if (statisticsResult == KERN_SUCCESS) {
        counters.free_count = vmStat.free_count;
        counters.inactive_count = vmStat.inactive_count;
        counters.speculative_count = vmStat.speculative_count;
        counters.purgeable_count = vmStat.purgeable_count;
    }
    if (statisticsResult == KERN_SUCCESS &&
        SBCPUMemoryMetricsCompute(&counters, pageSize, kernelTotalBytes, physicalTotalBytes, &metrics)) {
        // XNU free_count already contains speculative pages. Inactive is reclaimable,
        // not guaranteed immediately allocatable; no invented 6 GB on read failure.
        _labelsDict[@"内存可用"].text = [NSString stringWithFormat:@"%.0f MiB / %.2f GiB",
            metrics.available_bytes / (1024.0 * 1024.0), metrics.total_bytes / (1024.0 * 1024.0 * 1024.0)];
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

// 🔍 插件冲突检测：点击插件显示详情
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section != 12) return;
    if (indexPath.row == 0) return;
    if (gInstalledPlugins.count == 0) return;
    // 计算插件索引，越界时自动回退
    NSInteger pluginIndex = indexPath.row - 1 - gPluginConflictCount;
    if (pluginIndex < 0 || pluginIndex >= (NSInteger)gInstalledPlugins.count) {
        pluginIndex = indexPath.row - 1; // 回退：假设没有冲突警告
    }
    if (pluginIndex < 0 || pluginIndex >= (NSInteger)gInstalledPlugins.count) return;

    NSDictionary *plugin = gInstalledPlugins[pluginIndex];
    NSString *name = plugin[@"name"] ?: @"未知";
    NSString *category = plugin[@"category"] ?: @"其他";
    NSArray *injected = plugin[@"injectedBundles"] ?: @[];

    NSString *message;
    if (injected.count > 0) {
        NSMutableString *bundleStr = [NSMutableString string];
        for (NSInteger i = 0; i < MIN(injected.count, 10); i++) {
            [bundleStr appendFormat:@"\n• %@", injected[i]];
        }
        if (injected.count > 10) {
            [bundleStr appendFormat:@"\n... 等%ld个进程", (long)injected.count];
        }
        message = [NSString stringWithFormat:@"分类：%@\n注入进程：%ld 个%@", category, (long)injected.count, bundleStr];
    } else {
        message = [NSString stringWithFormat:@"分类：%@\n注入进程：无（全局注入或未配置Filter）", category];
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:name message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    // 直接用 self present，最简单可靠
    [self presentViewController:alert animated:YES completion:nil];
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
    // 全屏设置页需要接收整页触摸，不能继续使用旧版卡片透传逻辑。
    if (settingsShowing) {
        return [super hitTest:point withEvent:event];
    }
    if (detailShowing || self.rootViewController.presentedViewController) {
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
- (void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.tableView.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.tableView.separatorColor = [UIColor colorWithWhite:0.85 alpha:1.0];
}

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
- (void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.tableView.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.tableView.separatorColor = [UIColor colorWithWhite:0.85 alpha:1.0];
}

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
// 100% 完整保留的设置中心
// ==============================================

// ========== 方案A 极简液态玻璃设置中心：主题 helper ==========
static UIColor *sbcpuThemeColor(NSInteger section) {
    // 6 色柔和顺序渐变（紫/蓝/青/绿/粉/橙）
    NSArray *cols = @[
        [UIColor colorWithRed:0.65 green:0.55 blue:1.0 alpha:1.0],   // 柔紫
        [UIColor colorWithRed:0.45 green:0.62 blue:1.0 alpha:1.0],   // 柔蓝
        [UIColor colorWithRed:0.40 green:0.80 blue:0.90 alpha:1.0],  // 水青
        [UIColor colorWithRed:0.40 green:0.80 blue:0.65 alpha:1.0],  // 薄荷绿
        [UIColor colorWithRed:0.95 green:0.62 blue:0.80 alpha:1.0],  // 樱花粉
        [UIColor colorWithRed:0.98 green:0.72 blue:0.40 alpha:1.0],  // 蜜橙
    ];
    return cols[((section % 6) + 6) % 6];
}

static UIImage *sbcpuIconForTitle(NSString *title, NSInteger section) {
    if (![title isKindOfClass:[NSString class]] || title.length == 0) return nil;
    NSString *sym = nil;
    NSDictionary *rules = @{
        @"cpu.fill": @[@"cpu", @"频率", @"核心", @"占用"],
        @"gauge.fill": @[@"fps", @"帧率", @"gauge", @"网速", @"网络", @"高刷"],
        @"thermometer.sun.fill": @[@"温度", @"温控", @"过热", @"高温", @"发热"],
        @"bolt.fill": @[@"充电", @"快充", @"电流", @"电压", @"功率", @"涓流"],
        @"battery.100percent": @[@"电池", @"电量", @"停充", @"满血"],
        @"shield.lefthalf.filled": @[@"屏蔽", @"部件", @"维修", @"健康"],
        @"checkmark.shield.fill": @[@"插件", @"冲突", @"检测", @"扫描", @"耗电"],
        @"droplet.fill": @[@"液态玻璃", @"液态"],
        @"eye.fill": @[@"显示", @"悬浮窗", @"浮窗", @"透明"],
        @"arrow.up.and.down": @[@"折叠", @"展开", @"伸缩", @"横屏", @"缩进", @"吸附"],
        @"slider.horizontal.3": @[@"透明度", @"缩放", @"大小", @"圆角", @"字号", @"字体", @"位置"],
        @"keyboard.fill": @[@"键盘", @"输入"],
        @"dock.rectangle": @[@"dock", @"停靠"],
        @"hand.tap.fill": @[@"单击", @"双击", @"长按", @"拖动", @"手势", @"智能选项"],
        @"mappin.and.ellipse": @[@"记忆", @"记住"],
        @"bell.fill": @[@"通知", @"提醒"],
        @"memorychip.fill": @[@"内存"],
        @"gearshape.fill": @[@"设置", @"模式", @"运行", @"状态", @"保护", @"恢复", @"警告", @"启动", @"功耗", @"性能"],
    };
    NSString *low = [title lowercaseString];
    for (NSString *s in rules) {
        for (NSString *kw in rules[s]) {
            if ([low rangeOfString:kw options:NSCaseInsensitiveSearch].location != NSNotFound) { sym = s; break; }
        }
        if (sym) break;
    }
    if (!sym) sym = @"circle.fill";
    CGFloat size = 30.0;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(size, size)];
    UIImage *img = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        UIColor *base = sbcpuThemeColor(section);
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, size, size) cornerRadius:8.0];
        CGContextSaveGState(ctx.CGContext);
        [path addClip];
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        UIColor *light = [base colorWithAlphaComponent:0.55];
        NSArray *colors = @[(id)base.CGColor, (id)light.CGColor];
        CGGradientRef grad = CGGradientCreateWithColors(cs, (CFArrayRef)colors, NULL);
        CGContextDrawLinearGradient(ctx.CGContext, grad, CGPointMake(0, 0), CGPointMake(size, size), 0);
        CGGradientRelease(grad);
        CGColorSpaceRelease(cs);
        CGContextRestoreGState(ctx.CGContext);
        UIImage *symImg = [UIImage systemImageNamed:sym];
        if (symImg) {
            symImg = [symImg imageWithTintColor:[UIColor whiteColor] renderingMode:UIImageRenderingModeAlwaysTemplate];
            [symImg drawInRect:CGRectMake(6, 6, 18, 18)];
        }
    }];
    return img;
}

static void applySettingsTheme(UITableViewCell *cell, NSIndexPath *indexPath) {
    if (!cell || !indexPath) return;

    // ============================================================
    // V4.11 — 浅色原生设置中心
    // 白底分组、黑字清晰、iOS 系统蓝/绿强调，不透明、不碍眼。
    // ============================================================
    cell.backgroundColor = UIColor.whiteColor;
    cell.contentView.backgroundColor = UIColor.whiteColor;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;

    // 清理旧版液态玻璃层（升级残留，防止叠层/误渲染）
    UIView *glass = [cell.contentView viewWithTag:9899];
    if (glass) [glass removeFromSuperview];
    UIView *highlight = [cell.contentView viewWithTag:9900];
    if (highlight) [highlight removeFromSuperview];

    // 主标题：系统黑
    cell.textLabel.textColor = UIColor.blackColor;
    cell.textLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightRegular];
    cell.textLabel.numberOfLines = 2;

    // 副标题/右侧数值：黑色（浅色模式清晰可读）
    if (cell.detailTextLabel) {
        cell.detailTextLabel.textColor = [UIColor colorWithWhite:0.15 alpha:1.0];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightRegular];
        cell.detailTextLabel.numberOfLines = 2;
    }

    // 开关：iOS 标准绿
    if ([cell.accessoryView isKindOfClass:[UISwitch class]]) {
        UISwitch *sw = (UISwitch *)cell.accessoryView;
        sw.onTintColor = [UIColor systemGreenColor];
        sw.tintColor = nil;
        sw.backgroundColor = UIColor.clearColor;
        sw.layer.cornerRadius = 0.0f;
    }

    // 滑块：iOS 标准蓝
    for (UIView *sub in cell.contentView.subviews) {
        if ([sub isKindOfClass:[UISlider class]]) {
            UISlider *slider = (UISlider *)sub;
            slider.minimumTrackTintColor = [UIColor systemBlueColor];
            slider.maximumTrackTintColor = [UIColor colorWithWhite:0.85 alpha:1.0];
            if (@available(iOS 15.0, *)) {
                slider.thumbTintColor = UIColor.whiteColor;
            }
        }
    }

    // SF Symbols 图标：保留 sbcpuIconForTitle 的彩色圆角图标（不染色）
    if (!cell.imageView.image) {
        UIImage *icon = sbcpuIconForTitle(cell.textLabel.text, indexPath.section);
        if (icon) {
            cell.imageView.image = icon;
        }
    }

    // 选中态：原生浅灰
    UIView *selected = [[UIView alloc] initWithFrame:CGRectZero];
    selected.backgroundColor = [UIColor colorWithWhite:0.90 alpha:1.0];
    cell.selectedBackgroundView = selected;
}

@implementation SBCPUSettingsController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"灵动监测";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                     target:self
                                                     action:@selector(closeSettings)];

    // V4.18.2 — 分组折叠：默认全部收起（分组显示为一行行入口，点击展开）
    self.collapsedSections = [NSMutableSet set];
    @try {
        NSArray *saved = [[NSUserDefaults standardUserDefaults] objectForKey:@"sbfl_settings_collapsed_v2"];
        if ([saved isKindOfClass:[NSArray class]] && saved.count > 0) {
            // 有历史折叠记录：尊重用户上次展开/收起的选择
            for (id num in saved) {
                [self.collapsedSections addObject:num];
            }
        } else {
            // 首次：默认全部收起（0~12 有内容的分组），打开即清爽的分组列表
            for (NSInteger i = 0; i <= 12; i++) {
                if (i == 10 || i == 11) continue;
                [self.collapsedSections addObject:@(i)];
            }
        }
    } @catch (NSException *e) {}

    // ============================================================
    // V4.11 — 浅色原生设置中心
    // 系统 InsetGrouped 默认样式：浅灰分组背景 + 白色圆角卡片 + 黑字
    // ============================================================
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.tableView.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.showsVerticalScrollIndicator = NO;
    self.tableView.clipsToBounds = NO;

    // 更舒服的上下留白，避免第一组/最后一组贴边。
    self.tableView.contentInset = UIEdgeInsetsMake(8.0, 0.0, 24.0, 0.0);
    self.tableView.scrollIndicatorInsets = UIEdgeInsetsMake(8.0, 0.0, 24.0, 0.0);

    // 清理旧版液态玻璃层（升级残留，防止深色渐变/毛玻璃残留）
    if (self.glassBackdrop) {
        [self.glassBackdrop removeFromSuperlayer];
        self.glassBackdrop = nil;
    }
    if (self.glassGradient) {
        [self.glassGradient removeFromSuperlayer];
        self.glassGradient = nil;
    }

    if (@available(iOS 13.0, *)) {
        UINavigationBarAppearance *app = [UINavigationBarAppearance new];
        [app configureWithDefaultBackground];
        app.backgroundColor = UIColor.whiteColor;
        app.titleTextAttributes = @{
            NSForegroundColorAttributeName: UIColor.blackColor,
            NSFontAttributeName: [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold]
        };
        self.navigationController.navigationBar.standardAppearance = app;
        self.navigationController.navigationBar.scrollEdgeAppearance = app;
        self.navigationController.navigationBar.compactAppearance = app;
        self.navigationController.navigationBar.tintColor = UIColor.systemBlueColor;
    }

    // 完成按钮：系统蓝
    self.navigationItem.rightBarButtonItem.tintColor = UIColor.systemBlueColor;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // backdrop / 渐变层跟随卡片最终尺寸（viewDidLoad 时 bounds 尚未定型）
    if (self.glassBackdrop) self.glassBackdrop.frame = self.view.bounds;
    if (self.glassGradient) self.glassGradient.frame = self.view.bounds;
}





- (void)closeSettings {
    settingsShowing = NO;
    if (cpuWindow) [cpuWindow setNeedsLayout];
    if (floatingView) [floatingView resetInactivityTimer];
    [self dismissViewControllerAnimated:YES completion:nil];
}

// 全屏设置页不拦截内容点击；保留代理接口兼容旧版调用。
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    return NO;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 13;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    // V4.18.1 — 折叠的分组不显示任何行（标题栏仍在，可点击展开）
    if (self.collapsedSections && [self.collapsedSections containsObject:@(section)]) return 0;
    if (section == 0) return 6;
    if (section == 1) return 5; // 自动控制与防护：自动注销/CPU触发值/持续时间/锁屏清理后台/锁屏清理白名单
    if (section == 2) return 5;
    if (section == 3) return 7; // 通知管理
    if (section == 4) return 3;
    if (section == 5) return 0;
    if (section == 6) return 0; // 保留旧分组编号，避免其他页面索引迁移
    if (section == 7) return 6; // 充电增强：充电增强/满血快充/屏蔽维修/充电历史/阻止充电/阻止外部供电
    if (section == 8) return 20; // 位置与显示 + 状态栏胶囊内容
    if (section == 9) return 0; // 智能停充已统一到系统插件“充电限制”
    if (section == 10) return 0; // 📖 功能说明已移除
    if (section == 11) return 0; // 保留旧分组编号
    if (section == 12) {
        // 🔍 插件冲突检测：1状态卡片 + 冲突数 + 分类标题数 + 插件数
        if (!gPluginScanDone) return 1;
        NSInteger categoryHeaderCount = gPluginCategories.count;
        return 1 + gPluginConflictCount + categoryHeaderCount + gPluginTotalCount;
    }
    return 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) return @"📱 智能缩进与侧边吸附";
    if (section == 1) return @"⚡ 自动控制与防护";
    if (section == 2) return @"🔲 悬浮窗外观";
    if (section == 3) return @"💬 消息与通知管理";
    if (section == 4) return @"🧠 智能选项";
    if (section == 5) return @"";
    if (section == 6) return @"";
    if (section == 7) return @"🔌 充电增强";
    if (section == 8) return @"📍 位置与显示";
    if (section == 9) return @""; // 充电智能设置已移至系统插件“充电限制”
    if (section == 10) return @"";
    if (section == 11) return @"";
    if (section == 12) return @"🔍 插件冲突检测";
    return @"";
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    (void)tableView;
    // 隐藏真正没有内容的说明区，其他分组标题保持呼吸感。
    if (section == 5 || section == 6 || section == 9 || section == 10 || section == 11) return 0.01;
    // V4.18.2 — 分组入口行样式：卡片高度 48
    if (section == 0) return 54.0;
    return 48.0;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    (void)tableView;

    NSString *title = [self tableView:tableView titleForHeaderInSection:section];
    if (!title.length) return nil;

    // V4.18.2 — 分组入口：白色圆角卡片行（图标 + 标题 + 右侧箭头），点击展开/收起
    UIView *header = [[UIView alloc] initWithFrame:CGRectZero];
    header.backgroundColor = UIColor.clearColor;

    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.backgroundColor = UIColor.whiteColor;
    card.layer.cornerRadius = 12.0f;
    card.layer.masksToBounds = YES;
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:card];

    // 点击手势
    header.tag = 9000 + section;
    header.userInteractionEnabled = YES;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleSection:)];
    tap.numberOfTapsRequired = 1;
    [header addGestureRecognizer:tap];

    // 左侧彩色图标
    UIImageView *iconView = nil;
    UIImage *icon = sbcpuIconForTitle(title, section);
    if (icon) {
        iconView = [[UIImageView alloc] initWithImage:icon];
        iconView.translatesAutoresizingMaskIntoConstraints = NO;
        [card addSubview:iconView];
    }

    // 标题
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.text = stripLeadingEmoji(title);
    label.textColor = [UIColor colorWithWhite:0.12 alpha:1.0];
    label.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium];
    label.numberOfLines = 1;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:label];

    // 右侧箭头：收起 ▶ / 展开 ▾
    BOOL collapsed = [self.collapsedSections containsObject:@(section)];
    UILabel *arrow = [[UILabel alloc] initWithFrame:CGRectZero];
    arrow.text = collapsed ? @"▶" : @"▾";
    arrow.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightSemibold];
    arrow.textColor = [UIColor systemGrayColor];
    arrow.textAlignment = NSTextAlignmentRight;
    arrow.translatesAutoresizingMaskIntoConstraints = NO;
    arrow.tag = 9100;
    [card addSubview:arrow];

    [NSLayoutConstraint activateConstraints:@[
        [card.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16.0],
        [card.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-16.0],
        [card.topAnchor constraintEqualToAnchor:header.topAnchor constant:2.0],
        [card.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-6.0],

        [arrow.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16.0],
        [arrow.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [arrow.widthAnchor constraintEqualToConstant:22.0],

        [label.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [label.trailingAnchor constraintEqualToAnchor:arrow.leadingAnchor constant:-8.0]
    ]];
    if (iconView) {
        // V4.18.3 — 修复：label 只保留一个 leading 约束（图标右侧），避免与图标重叠
        [NSLayoutConstraint activateConstraints:@[
            [iconView.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16.0],
            [iconView.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
            [iconView.widthAnchor constraintEqualToConstant:26.0],
            [iconView.heightAnchor constraintEqualToConstant:26.0],
            [label.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:12.0]
        ]];
    } else {
        [NSLayoutConstraint activateConstraints:@[
            [label.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16.0]
        ]];
    }

    return header;
}

// V4.18.2 — 分组入口行：去掉标题开头的 emoji（"📱 " → ""），让行内只保留文字+图标
static NSString *stripLeadingEmoji(NSString *s) {
    if (![s isKindOfClass:[NSString class]] || s.length == 0) return s;
    NSRange r = [s rangeOfString:@" "];
    if (r.location != NSNotFound && r.location < 4) {
        return [s substringFromIndex:r.location + 1];
    }
    return s;
}

// V4.18.1 — 点击分组标题：展开/收起，带动画并记忆状态
- (void)toggleSection:(UITapGestureRecognizer *)gr {
    if (!gr.view) return;
    NSInteger section = gr.view.tag - 9000;
    NSNumber *key = @(section);
    BOOL willCollapse = ![self.collapsedSections containsObject:key];
    if (willCollapse) {
        [self.collapsedSections addObject:key];
    } else {
        [self.collapsedSections removeObject:key];
    }

    // 更新箭头
    UILabel *arrow = [gr.view viewWithTag:9100];
    arrow.text = willCollapse ? @"▶" : @"▾";

    // 动画收起/展开行
    [self.tableView beginUpdates];
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:section]
                  withRowAnimation:UITableViewRowAnimationAutomatic];
    [self.tableView endUpdates];

    // 记忆折叠状态（跨打开保持）
    @try {
        NSArray *allKeys = [self.collapsedSections.allObjects sortedArrayUsingSelector:@selector(compare:)];
        [[NSUserDefaults standardUserDefaults] setObject:allKeys forKey:@"sbfl_settings_collapsed_v2"];
    } @catch (NSException *e) {}
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];

    if (indexPath.section == 9) {
        // 清理 cell 复用残留
        for (UIView *v in [cell.contentView.subviews copy]) {
            if (v.tag >= 900) [v removeFromSuperview];
        }
        [cell layoutIfNeeded];
        CGFloat cw = self.tableView.bounds.size.width - 32.0;

        if (indexPath.row == 0) {
            // 开关（主标题+说明全部自绘固定位置，避免系统 textLabel 垂直居中与说明重叠）
            cell.textLabel.hidden = YES;
            cell.detailTextLabel.hidden = YES;
            UILabel *titleLbl = [[UILabel alloc] initWithFrame:CGRectMake(16, 10, 180, 24)];
            titleLbl.text = @"智能停充";
            titleLbl.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
            titleLbl.textColor = UIColor.blackColor;
            titleLbl.tag = 981;
            [cell.contentView addSubview:titleLbl];
            UILabel *descLbl = [[UILabel alloc] initWithFrame:CGRectMake(16, 38, cw - 125, 38)];
            descLbl.text = @"充到上限自动停充，降到下限自动恢复";
            descLbl.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
            descLbl.textColor = [UIColor colorWithWhite:0.15 alpha:1.0];
            descLbl.numberOfLines = 2;
            descLbl.tag = 980;
            [cell.contentView addSubview:descLbl];
            UISwitch *sw = [UISwitch new];
            sw.on = smartChargeEnable;
            [sw addTarget:self action:@selector(changeSmartChargeEnable:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (indexPath.row == 1) {
            // 预设模式：三个卡片按钮（标题自绘固定位置，避免系统 textLabel 与按钮重叠）
            cell.textLabel.hidden = YES;
            cell.detailTextLabel.hidden = YES;
            UILabel *titleLbl = [[UILabel alloc] initWithFrame:CGRectMake(16, 10, 180, 24)];
            titleLbl.text = @"预设模式";
            titleLbl.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
            titleLbl.textColor = UIColor.blackColor;
            titleLbl.tag = 982;
            [cell.contentView addSubview:titleLbl];
            NSArray *titles = @[@"🛡 日常", @"✈ 出行", @"💚 保养"];
            NSArray *subs = @[@"80%", @"100%", @"60%"];
            CGFloat btnW = (cw - 48) / 3.0;
            for (int i = 0; i < 3; i++) {
                UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
                btn.frame = CGRectMake(16 + i * (btnW + 8), 40, btnW, 40);
                btn.tag = 900 + i;
                btn.userInteractionEnabled = YES;
                btn.exclusiveTouch = YES;
                btn.layer.cornerRadius = 14;
                btn.clipsToBounds = YES;
                BOOL selected = (smartChargeMode == i);
                UIColor *bgColor = selected ? [UIColor systemBlueColor] :
                    [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *t) {
                        return t.userInterfaceStyle == UIUserInterfaceStyleDark ?
                            [UIColor colorWithWhite:0.18 alpha:1.0] : [UIColor colorWithWhite:0.93 alpha:1.0];
                    }];
                btn.backgroundColor = bgColor;
                // 主标题（图标+文字）
                UILabel *t1 = [[UILabel alloc] initWithFrame:CGRectMake(0, 6, btnW, 18)];
                t1.text = titles[i];
                t1.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
                t1.textColor = selected ? [UIColor whiteColor] : [UIColor labelColor];
                t1.textAlignment = NSTextAlignmentCenter;
                t1.tag = 910 + i;
                [btn addSubview:t1];
                // 副标题（百分比）
                UILabel *t2 = [[UILabel alloc] initWithFrame:CGRectMake(0, 22, btnW, 14)];
                t2.text = subs[i];
                t2.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightMedium];
                t2.textColor = selected ? [UIColor colorWithWhite:0.9 alpha:1.0] : [UIColor secondaryLabelColor];
                t2.textAlignment = NSTextAlignmentCenter;
                t2.tag = 920 + i;
                [btn addSubview:t2];
                [btn addTarget:self action:@selector(changeSmartChargeMode:) forControlEvents:UIControlEventTouchUpInside];
                [cell.contentView addSubview:btn];
            }
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (indexPath.row == 2) {
            // 充电区间可视化
            cell.textLabel.hidden = YES;
            cell.detailTextLabel.hidden = YES;
            CGFloat px = 20, pw = cw - 40;
            // 标题行
            UILabel *titleLbl = [[UILabel alloc] initWithFrame:CGRectMake(px, 10, pw, 20)];
            titleLbl.text = @"🔋 充电区间";
            titleLbl.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
            titleLbl.textColor = [UIColor labelColor];
            titleLbl.tag = 900;
            [cell.contentView addSubview:titleLbl];
            // 数值行（左下限，右上限）
            UILabel *lowVal = [[UILabel alloc] initWithFrame:CGRectMake(px, 34, 80, 20)];
            lowVal.text = [NSString stringWithFormat:@"%ld%%", (long)smartChargeLowerLimit];
            lowVal.font = [UIFont monospacedDigitSystemFontOfSize:16 weight:UIFontWeightBold];
            lowVal.textColor = [UIColor systemOrangeColor];
            lowVal.tag = 901;
            [cell.contentView addSubview:lowVal];
            UILabel *arrowLbl = [[UILabel alloc] initWithFrame:CGRectMake(px + 80, 34, pw - 160, 20)];
            arrowLbl.text = @"← 循环区间 →";
            arrowLbl.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
            arrowLbl.textColor = [UIColor colorWithWhite:0.15 alpha:1.0]; // 黑色，白底清晰可读
            arrowLbl.textAlignment = NSTextAlignmentCenter;
            arrowLbl.tag = 902;
            [cell.contentView addSubview:arrowLbl];
            UILabel *highVal = [[UILabel alloc] initWithFrame:CGRectMake(px + pw - 80, 34, 80, 20)];
            highVal.text = [NSString stringWithFormat:@"%ld%%", (long)smartChargeUpperLimit];
            highVal.font = [UIFont monospacedDigitSystemFontOfSize:16 weight:UIFontWeightBold];
            highVal.textColor = [UIColor systemGreenColor];
            highVal.textAlignment = NSTextAlignmentRight;
            highVal.tag = 903;
            [cell.contentView addSubview:highVal];
            // 进度条
            CGFloat by = 62, bh = 14;
            UIView *bgBar = [[UIView alloc] initWithFrame:CGRectMake(px, by, pw, bh)];
            bgBar.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *t) {
                return t.userInterfaceStyle == UIUserInterfaceStyleDark ?
                    [UIColor colorWithWhite:0.22 alpha:1.0] : [UIColor colorWithWhite:0.88 alpha:1.0];
            }];
            bgBar.layer.cornerRadius = bh / 2;
            bgBar.tag = 904;
            [cell.contentView addSubview:bgBar];
            // 高亮区间
            CGFloat rs = px + (smartChargeLowerLimit / 100.0) * pw;
            CGFloat re = px + (smartChargeUpperLimit / 100.0) * pw;
            UIView *rangeBar = [[UIView alloc] initWithFrame:CGRectMake(rs, by, MAX(bh, re - rs), bh)];
            rangeBar.backgroundColor = [UIColor systemGreenColor];
            rangeBar.layer.cornerRadius = bh / 2;
            rangeBar.tag = 905;
            [cell.contentView addSubview:rangeBar];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (indexPath.row == 3) {
            // 停充上限滑块（标题自绘，固定位置保证可见）
            cell.textLabel.hidden = YES;
            cell.detailTextLabel.hidden = YES;
            UILabel *titleLbl = [[UILabel alloc] initWithFrame:CGRectMake(16, 8, 140, 28)];
            titleLbl.text = @"停充上限";
            titleLbl.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
            titleLbl.textColor = [UIColor colorWithWhite:0.15 alpha:1.0];
            titleLbl.tag = 985;
            [cell.contentView addSubview:titleLbl];
            // 右侧数值
            UILabel *valLbl = [[UILabel alloc] initWithFrame:CGRectMake(cw - 80, 8, 65, 28)];
            valLbl.text = [NSString stringWithFormat:@"%ld%%", (long)smartChargeUpperLimit];
            valLbl.font = [UIFont monospacedDigitSystemFontOfSize:17 weight:UIFontWeightBold];
            valLbl.textColor = [UIColor systemGreenColor];
            valLbl.textAlignment = NSTextAlignmentRight;
            valLbl.tag = 930;
            [cell.contentView addSubview:valLbl];
            UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(16, 40, cw - 32, 30)];
            slider.minimumValue = 50;
            slider.maximumValue = 100;
            slider.value = smartChargeUpperLimit;
            // 实时跟手：拖动时不重载整个设置表。
            slider.continuous = YES;
            slider.minimumTrackTintColor = [UIColor systemGreenColor];
            slider.tag = 931;
            [slider addTarget:self action:@selector(changeSmartChargeUpper:) forControlEvents:UIControlEventValueChanged];
            [slider addTarget:self action:@selector(commitSmartChargeUpper:) forControlEvents:(UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel)];
            [cell.contentView addSubview:slider];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (indexPath.row == 5) {
            cell.textLabel.hidden = YES;
            cell.detailTextLabel.hidden = YES;
            UILabel *titleLbl = [[UILabel alloc] initWithFrame:CGRectMake(16, 10, cw - 90, 24)];
            titleLbl.text = @"智能温度停充";
            titleLbl.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
            titleLbl.textColor = [UIColor labelColor];
            [cell.contentView addSubview:titleLbl];
            UILabel *desc = [[UILabel alloc] initWithFrame:CGRectMake(16, 38, cw - 100, 28)];
            desc.text = @"高于上限阻止充电（CH0C），低于下限自动恢复";
            desc.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightRegular];
            desc.textColor = [UIColor secondaryLabelColor];
            desc.numberOfLines = 2;
            [cell.contentView addSubview:desc];
            UISwitch *sw = [UISwitch new];
            sw.on = smartThermalChargeEnable;
            [sw addTarget:self action:@selector(changeSmartThermalEnable:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (indexPath.row == 6) {
            cell.textLabel.hidden = YES;
            cell.detailTextLabel.hidden = YES;
            UILabel *titleLbl = [[UILabel alloc] initWithFrame:CGRectMake(16, 8, 150, 26)];
            titleLbl.text = @"温度上限";
            titleLbl.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
            titleLbl.textColor = [UIColor labelColor];
            [cell.contentView addSubview:titleLbl];
            UILabel *value = [[UILabel alloc] initWithFrame:CGRectMake(cw - 85, 8, 70, 26)];
            value.text = [NSString stringWithFormat:@"%ld°C", (long)smartThermalUpperC];
            value.textAlignment = NSTextAlignmentRight;
            value.font = [UIFont monospacedDigitSystemFontOfSize:17 weight:UIFontWeightBold];
            value.textColor = [UIColor systemRedColor];
            value.tag = 951;
            [cell.contentView addSubview:value];
            UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(16, 40, cw - 32, 30)];
            slider.minimumValue = 35; slider.maximumValue = 55; slider.value = smartThermalUpperC; slider.tag = 952;
            slider.minimumTrackTintColor = [UIColor systemRedColor];
            [slider addTarget:self action:@selector(changeSmartThermalUpper:) forControlEvents:UIControlEventValueChanged];
            [slider addTarget:self action:@selector(commitSmartThermal:) forControlEvents:UIControlEventTouchUpInside|UIControlEventTouchUpOutside|UIControlEventTouchCancel];
            [cell.contentView addSubview:slider];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (indexPath.row == 7) {
            cell.textLabel.hidden = YES;
            cell.detailTextLabel.hidden = YES;
            UILabel *titleLbl = [[UILabel alloc] initWithFrame:CGRectMake(16, 8, 150, 26)];
            titleLbl.text = @"温度下限";
            titleLbl.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
            titleLbl.textColor = [UIColor labelColor];
            [cell.contentView addSubview:titleLbl];
            UILabel *value = [[UILabel alloc] initWithFrame:CGRectMake(cw - 85, 8, 70, 26)];
            value.text = [NSString stringWithFormat:@"%ld°C", (long)smartThermalLowerC];
            value.textAlignment = NSTextAlignmentRight;
            value.font = [UIFont monospacedDigitSystemFontOfSize:17 weight:UIFontWeightBold];
            value.textColor = [UIColor systemBlueColor];
            value.tag = 953;
            [cell.contentView addSubview:value];
            UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(16, 40, cw - 32, 30)];
            slider.minimumValue = 30; slider.maximumValue = 50; slider.value = smartThermalLowerC; slider.tag = 954;
            slider.minimumTrackTintColor = [UIColor systemBlueColor];
            [slider addTarget:self action:@selector(changeSmartThermalLower:) forControlEvents:UIControlEventValueChanged];
            [slider addTarget:self action:@selector(commitSmartThermal:) forControlEvents:UIControlEventTouchUpInside|UIControlEventTouchUpOutside|UIControlEventTouchCancel];
            [cell.contentView addSubview:slider];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (indexPath.row == 4) {
            // 回充下限滑块（标题自绘，固定位置保证可见）
            cell.textLabel.hidden = YES;
            cell.detailTextLabel.hidden = YES;
            UILabel *titleLbl = [[UILabel alloc] initWithFrame:CGRectMake(16, 8, 140, 28)];
            titleLbl.text = @"回充下限";
            titleLbl.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
            titleLbl.textColor = [UIColor colorWithWhite:0.15 alpha:1.0];
            titleLbl.tag = 986;
            [cell.contentView addSubview:titleLbl];
            UILabel *valLbl = [[UILabel alloc] initWithFrame:CGRectMake(cw - 80, 8, 65, 28)];
            valLbl.text = [NSString stringWithFormat:@"%ld%%", (long)smartChargeLowerLimit];
            valLbl.font = [UIFont monospacedDigitSystemFontOfSize:17 weight:UIFontWeightBold];
            valLbl.textColor = [UIColor systemOrangeColor];
            valLbl.textAlignment = NSTextAlignmentRight;
            valLbl.tag = 940;
            [cell.contentView addSubview:valLbl];
            UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(16, 40, cw - 32, 30)];
            slider.minimumValue = 40;
            slider.maximumValue = 90;
            slider.value = smartChargeLowerLimit;
            // 实时跟手：拖动时不重载整个设置表。
            slider.continuous = YES;
            slider.minimumTrackTintColor = [UIColor systemOrangeColor];
            slider.tag = 941;
            [slider addTarget:self action:@selector(changeSmartChargeLower:) forControlEvents:UIControlEventValueChanged];
            [slider addTarget:self action:@selector(commitSmartChargeLower:) forControlEvents:(UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel)];
            [cell.contentView addSubview:slider];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
    }

    // 🔍 插件冲突检测
    if (indexPath.section == 12) {
        // 统一内容宽度口径（不依赖 cell 布局时机，不同机型一致）
        CGFloat cw = self.tableView.bounds.size.width - 32.0;
        // 状态卡片(row 0)不可点击，其他全部可点击
        if (indexPath.row == 0) {
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else {
            cell.selectionStyle = UITableViewCellSelectionStyleGray;
        }
        cell.textLabel.hidden = YES;
        cell.detailTextLabel.hidden = YES;
        cell.accessoryType = UITableViewCellAccessoryNone;

        if (indexPath.row == 0) {
            // 🎨 卡片式状态卡片
            cell.backgroundColor = [UIColor clearColor];
            // 卡片背景
            UIView *card = [[UIView alloc] initWithFrame:CGRectMake(12, 8, cw - 24, 100)];
            card.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *t) {
                return t.userInterfaceStyle == UIUserInterfaceStyleDark ?
                    [UIColor colorWithRed:0.1 green:0.15 blue:0.25 alpha:1.0] :
                    [UIColor colorWithRed:0.85 green:0.92 blue:1.0 alpha:1.0];
            }];
            card.layer.cornerRadius = 16;
            [cell.contentView addSubview:card];
            // 左侧图标
            UILabel *iconLbl = [[UILabel alloc] initWithFrame:CGRectMake(20, 18, 40, 40)];
            iconLbl.text = @"📋";
            iconLbl.font = [UIFont systemFontOfSize:28];
            iconLbl.textAlignment = NSTextAlignmentCenter;
            [card addSubview:iconLbl];
            // 标题
            UILabel *titleLbl = [[UILabel alloc] initWithFrame:CGRectMake(68, 16, card.bounds.size.width - 150, 24)];
            if (gPluginScanDone) {
                titleLbl.text = [NSString stringWithFormat:@"已扫描 %ld 个插件", (long)gPluginTotalCount];
            } else {
                titleLbl.text = @"插件冲突检测";
            }
            titleLbl.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
            titleLbl.textColor = [UIColor labelColor];
            [card addSubview:titleLbl];
            // 描述
            UILabel *descLbl = [[UILabel alloc] initWithFrame:CGRectMake(68, 42, card.bounds.size.width - 150, 20)];
            if (!gPluginScanDone) {
                descLbl.text = @"点击右上角按钮开始扫描";
                descLbl.textColor = [UIColor secondaryLabelColor];
            } else if (gPluginConflictCount > 0) {
                descLbl.text = [NSString stringWithFormat:@"发现 %ld 个潜在冲突 ⚠️", (long)gPluginConflictCount];
                descLbl.textColor = [UIColor systemOrangeColor];
            } else {
                descLbl.text = @"未发现冲突 ✅";
                descLbl.textColor = [UIColor systemGreenColor];
            }
            descLbl.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
            [card addSubview:descLbl];
            // 扫描按钮
            UIButton *scanBtn = [UIButton buttonWithType:UIButtonTypeSystem];
            scanBtn.frame = CGRectMake(card.bounds.size.width - 76, 24, 60, 32);
            [scanBtn setTitle:gPluginScanDone ? @"扫描" : @"开始" forState:UIControlStateNormal];
            scanBtn.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
            scanBtn.backgroundColor = [UIColor whiteColor];
            [scanBtn setTitleColor:[UIColor systemBlueColor] forState:UIControlStateNormal];
            scanBtn.layer.cornerRadius = 16;
            scanBtn.layer.borderWidth = 1;
            scanBtn.layer.borderColor = [UIColor systemBlueColor].CGColor;
            [scanBtn addTarget:self action:@selector(scanPluginsTapped:) forControlEvents:UIControlEventTouchUpInside];
            [card addSubview:scanBtn];
            // 进度条
            UIView *progressBg = [[UIView alloc] initWithFrame:CGRectMake(20, 72, card.bounds.size.width - 40, 6)];
            progressBg.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.3];
            progressBg.layer.cornerRadius = 3;
            [card addSubview:progressBg];
            CGFloat progress = gPluginScanDone ? 1.0 : 0.0;
            UIView *progressFg = [[UIView alloc] initWithFrame:CGRectMake(20, 72, (card.bounds.size.width - 40) * progress, 6)];
            progressFg.backgroundColor = [UIColor systemBlueColor];
            progressFg.layer.cornerRadius = 3;
            [card addSubview:progressFg];
        } else if (indexPath.row <= gPluginConflictCount) {
            // 🎨 卡片式冲突警告
            cell.backgroundColor = [UIColor clearColor];
            NSInteger conflictIdx = indexPath.row - 1;
            if (conflictIdx < (NSInteger)gPluginConflicts.count) {
                NSDictionary *conflict = gPluginConflicts[conflictIdx];
                NSInteger severity = [conflict[@"severity"] integerValue];
                UIColor *cardColor, *iconColor;
                if (severity == 0) {
                    cardColor = [UIColor colorWithRed:0.95 green:0.25 blue:0.25 alpha:1.0];
                    iconColor = [UIColor colorWithRed:1.0 green:0.9 blue:0.9 alpha:1.0];
                } else if (severity == 1) {
                    cardColor = [UIColor colorWithRed:0.95 green:0.55 blue:0.15 alpha:1.0];
                    iconColor = [UIColor colorWithRed:1.0 green:0.95 blue:0.85 alpha:1.0];
                } else {
                    cardColor = [UIColor colorWithRed:0.95 green:0.8 blue:0.2 alpha:1.0];
                    iconColor = [UIColor colorWithRed:1.0 green:1.0 blue:0.85 alpha:1.0];
                }
                // 卡片背景
                UIView *card = [[UIView alloc] initWithFrame:CGRectMake(12, 6, cw - 24, 76)];
                card.backgroundColor = cardColor;
                card.layer.cornerRadius = 14;
                [cell.contentView addSubview:card];
                // 左侧图标背景
                UIView *iconBg = [[UIView alloc] initWithFrame:CGRectMake(14, 14, 44, 44)];
                iconBg.backgroundColor = iconColor;
                iconBg.layer.cornerRadius = 22;
                [card addSubview:iconBg];
                // 图标
                UILabel *iconLbl = [[UILabel alloc] initWithFrame:CGRectMake(14, 14, 44, 44)];
                iconLbl.text = @"⚠️";
                iconLbl.font = [UIFont systemFontOfSize:22];
                iconLbl.textAlignment = NSTextAlignmentCenter;
                [card addSubview:iconLbl];
                // 标题
                UILabel *tLbl = [[UILabel alloc] initWithFrame:CGRectMake(68, 12, card.bounds.size.width - 140, 22)];
                tLbl.text = conflict[@"title"];
                tLbl.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
                tLbl.textColor = [UIColor whiteColor];
                [card addSubview:tLbl];
                // 描述
                UILabel *dLbl = [[UILabel alloc] initWithFrame:CGRectMake(68, 36, card.bounds.size.width - 140, 34)];
                dLbl.text = conflict[@"desc"];
                dLbl.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
                dLbl.textColor = [UIColor colorWithWhite:1.0 alpha:0.9];
                dLbl.numberOfLines = 2;
                [card addSubview:dLbl];
                // 详情按钮
                UIButton *detailBtn = [UIButton buttonWithType:UIButtonTypeSystem];
                detailBtn.frame = CGRectMake(card.bounds.size.width - 68, 22, 52, 30);
                [detailBtn setTitle:@"详情" forState:UIControlStateNormal];
                detailBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
                detailBtn.backgroundColor = [UIColor whiteColor];
                [detailBtn setTitleColor:cardColor forState:UIControlStateNormal];
                detailBtn.layer.cornerRadius = 15;
                [card addSubview:detailBtn];
            }
        } else {
            // 🎨 卡片式分类标题 + 插件列表
            cell.backgroundColor = [UIColor clearColor];
            NSInteger listStartRow = 1 + gPluginConflictCount;
            NSInteger relativeRow = indexPath.row - listStartRow;
            NSInteger currentRow = 0;
            // 分类颜色数组
            NSArray *catColors = @[
                [UIColor systemBlueColor], [UIColor systemGreenColor], [UIColor systemOrangeColor],
                [UIColor systemPurpleColor], [UIColor systemPinkColor], [UIColor systemTealColor],
                [UIColor systemIndigoColor], [UIColor systemBrownColor], [UIColor systemRedColor],
                [UIColor colorWithRed:0.0 green:0.8 blue:1.0 alpha:1.0],
                [UIColor colorWithRed:0.0 green:0.8 blue:0.6 alpha:1.0],
                [UIColor systemYellowColor]
            ];
            for (NSInteger catIdx = 0; catIdx < (NSInteger)gPluginCategories.count; catIdx++) {
                NSDictionary *catInfo = gPluginCategories[catIdx];
                NSInteger catCount = [catInfo[@"count"] integerValue];
                NSInteger catStart = [catInfo[@"startIndex"] integerValue];
                UIColor *catColor = catColors[catIdx % catColors.count];
                // 分类标题行
                if (relativeRow == currentRow) {
                    cell.selectionStyle = UITableViewCellSelectionStyleNone;
                    // 左侧彩色图标
                    UIView *iconBg = [[UIView alloc] initWithFrame:CGRectMake(20, 8, 36, 36)];
                    iconBg.backgroundColor = catColor;
                    iconBg.layer.cornerRadius = 10;
                    [cell.contentView addSubview:iconBg];
                    UILabel *iconLbl = [[UILabel alloc] initWithFrame:CGRectMake(20, 8, 36, 36)];
                    iconLbl.text = @"📁";
                    iconLbl.font = [UIFont systemFontOfSize:18];
                    iconLbl.textAlignment = NSTextAlignmentCenter;
                    [cell.contentView addSubview:iconLbl];
                    // 分类名称
                    UILabel *nameLbl = [[UILabel alloc] initWithFrame:CGRectMake(66, 6, cw - 120, 22)];
                    nameLbl.text = [NSString stringWithFormat:@"%@（%ld个）", catInfo[@"name"], (long)catCount];
                    nameLbl.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
                    nameLbl.textColor = [UIColor labelColor];
                    [cell.contentView addSubview:nameLbl];
                    // 描述
                    UILabel *descLbl = [[UILabel alloc] initWithFrame:CGRectMake(66, 28, cw - 120, 16)];
                    descLbl.text = [NSString stringWithFormat:@"共 %ld 个插件", (long)catCount];
                    descLbl.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
                    descLbl.textColor = [UIColor secondaryLabelColor];
                    [cell.contentView addSubview:descLbl];
                    // 右侧箭头
                    UILabel *arrowLbl = [[UILabel alloc] initWithFrame:CGRectMake(cw - 30, 14, 20, 24)];
                    arrowLbl.text = @"›";
                    arrowLbl.font = [UIFont systemFontOfSize:24 weight:UIFontWeightBold];
                    arrowLbl.textColor = [UIColor tertiaryLabelColor];
                    arrowLbl.textAlignment = NSTextAlignmentCenter;
                    [cell.contentView addSubview:arrowLbl];
    applySettingsTheme(cell, indexPath);
                    return cell;
                }
                currentRow++;
                // 该分类的插件行
                for (NSInteger j = 0; j < catCount; j++) {
                    if (relativeRow == currentRow) {
                        NSInteger pluginIdx = catStart + j;
                        if (pluginIdx >= 0 && pluginIdx < (NSInteger)gInstalledPlugins.count) {
                            NSDictionary *plugin = gInstalledPlugins[pluginIdx];
                            // 左侧彩色小图标
                            UIView *iconBg = [[UIView alloc] initWithFrame:CGRectMake(24, 14, 32, 32)];
                            iconBg.backgroundColor = [catColor colorWithAlphaComponent:0.15];
                            iconBg.layer.cornerRadius = 8;
                            [cell.contentView addSubview:iconBg];
                            UILabel *iconLbl = [[UILabel alloc] initWithFrame:CGRectMake(24, 14, 32, 32)];
                            iconLbl.text = @"🔧";
                            iconLbl.font = [UIFont systemFontOfSize:16];
                            iconLbl.textAlignment = NSTextAlignmentCenter;
                            [cell.contentView addSubview:iconLbl];
                            // 插件名称 + 版本号 + 耗电等级
                            NSString *ver = plugin[@"version"];
                            NSInteger powerLevel = estimatePowerConsumption(plugin);
                            NSString *powerIcon = (powerLevel == 2) ? @"🔴" : (powerLevel == 1) ? @"🟡" : @"🟢";
                            UILabel *nameLbl = [[UILabel alloc] initWithFrame:CGRectMake(66, 8, cw - 110, 20)];
                            nameLbl.text = [NSString stringWithFormat:@"%@  v%@  %@", plugin[@"name"], ver, powerIcon];
                            nameLbl.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
                            nameLbl.textColor = [UIColor labelColor];
                            [cell.contentView addSubview:nameLbl];
                            // 描述（最多两行完整显示，不再硬截断）
                            UILabel *descLbl = [[UILabel alloc] initWithFrame:CGRectMake(66, 30, cw - 110, 30)];
                            descLbl.text = plugin[@"desc"];
                            descLbl.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
                            descLbl.textColor = [UIColor colorWithWhite:0.15 alpha:1.0]; // 黑色小字清晰可读
                            descLbl.numberOfLines = 2;
                            [cell.contentView addSubview:descLbl];
                            // 注入进程数
                            NSArray *injected = plugin[@"injectedBundles"];
                            UILabel *injectLbl = [[UILabel alloc] initWithFrame:CGRectMake(66, 62, cw - 110, 14)];
                            injectLbl.text = [NSString stringWithFormat:@"注入 %ld 个进程 · %@", (long)injected.count, plugin[@"category"]];
                            injectLbl.font = [UIFont systemFontOfSize:10 weight:UIFontWeightRegular];
                            injectLbl.textColor = [UIColor colorWithWhite:0.35 alpha:1.0];
                            [cell.contentView addSubview:injectLbl];
                            // 右侧箭头
                            UILabel *arrowLbl = [[UILabel alloc] initWithFrame:CGRectMake(cw - 30, 32, 20, 24)];
                            arrowLbl.text = @"›";
                            arrowLbl.font = [UIFont systemFontOfSize:24 weight:UIFontWeightBold];
                            arrowLbl.textColor = [UIColor tertiaryLabelColor];
                            arrowLbl.textAlignment = NSTextAlignmentCenter;
                            [cell.contentView addSubview:arrowLbl];
                        }
    applySettingsTheme(cell, indexPath);
                        return cell;
                    }
                    currentRow++;
                }
            }
        }
    }

    if (indexPath.section == 10) {
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        cell.textLabel.textColor = [UIColor darkGrayColor];
        cell.textLabel.numberOfLines = 0;
        if (indexPath.row == 0) cell.textLabel.text = @"👆 单击悬浮窗：展开双层 UI / 0延迟直达聊天";
        else if (indexPath.row == 1) cell.textLabel.text = @"✌️ 双击悬浮窗：已移除，请前往系统设置";
        else if (indexPath.row == 2) cell.textLabel.text = @"👆 长按悬浮窗：全屏展示设备深层物理状态";
        else if (indexPath.row == 3) cell.textLabel.text = @"🤚 拖动悬浮窗：自由挪动位置并带物理回弹";
        else if (indexPath.row == 4) cell.textLabel.text = @"🔋 充电增强：实时功率监测与高电量充电目标";
    applySettingsTheme(cell, indexPath);
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
        } else if (indexPath.row == 5) {
            cell.textLabel.text = @"横屏迷你胶囊单段";
            cell.detailTextLabel.text = @"游戏内收成单段（仅 CPU），不显示四段，不碍眼";
            UISwitch *sw = [UISwitch new];
            sw.on = compactLandscapeCapsule;
            [sw addTarget:self action:@selector(changeCompactLandscapeCapsule:) forControlEvents:UIControlEventValueChanged];
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
        } else if (indexPath.row == 3) {
            cell.textLabel.text = @"锁屏清理后台";
            cell.detailTextLabel.text = @"锁屏后自动关闭所有后台应用";
            UISwitch *sw = [UISwitch new];
            sw.on = lockCleanupEnable;
            [sw addTarget:self action:@selector(changeLockCleanup:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (indexPath.row == 4) {
            cell.textLabel.text = @"锁屏清理白名单";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"已保护 %lu 个应用", (unsigned long)lockCleanupWhitelist.count];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    } else if (indexPath.section == 2) {
        // 清理 cell 复用残留（滑块行结构自绘，必须移除旧视图防重叠）
        for (UIView *v in [cell.contentView.subviews copy]) {
            if (v.tag >= 900) [v removeFromSuperview];
        }
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
            // 浮窗大小：一行式（标题 + 弹性滑块 + 右侧数值），iOS 原生滑块行风格
            cell.textLabel.hidden = YES;
            cell.detailTextLabel.hidden = YES;
            CGFloat cw2 = self.tableView.bounds.size.width - 32.0;
            UILabel *titleLbl = [[UILabel alloc] initWithFrame:CGRectMake(16, 8, 90, 28)];
            titleLbl.text = @"浮窗大小";
            titleLbl.font = [UIFont systemFontOfSize:16 weight:UIFontWeightRegular];
            titleLbl.textColor = [UIColor labelColor];
            titleLbl.tag = 966;
            [cell.contentView addSubview:titleLbl];
            UILabel *valLbl = [[UILabel alloc] initWithFrame:CGRectMake(cw2 - 80, 7, 66, 30)];
            valLbl.text = [NSString stringWithFormat:@"%.0f%%", floatingScale * 100];
            valLbl.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightBold];
            valLbl.textColor = [UIColor systemBlueColor];
            valLbl.textAlignment = NSTextAlignmentRight;
            valLbl.tag = 960;
            [cell.contentView addSubview:valLbl];
            UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(112, 11, cw2 - 112 - 84, 32)];
            slider.minimumValue = 0.4; slider.maximumValue = 1.6; slider.value = floatingScale;
            slider.continuous = YES;
            slider.tag = 963;
            [slider addTarget:self action:@selector(changeScaleSlider:) forControlEvents:UIControlEventValueChanged];
            [cell.contentView addSubview:slider];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (indexPath.row == 3) {
            // 字体大小：一行式
            cell.textLabel.hidden = YES;
            cell.detailTextLabel.hidden = YES;
            CGFloat cw3 = self.tableView.bounds.size.width - 32.0;
            UILabel *titleLbl = [[UILabel alloc] initWithFrame:CGRectMake(16, 8, 90, 28)];
            titleLbl.text = @"字体大小";
            titleLbl.font = [UIFont systemFontOfSize:16 weight:UIFontWeightRegular];
            titleLbl.textColor = [UIColor labelColor];
            titleLbl.tag = 967;
            [cell.contentView addSubview:titleLbl];
            UILabel *valLbl = [[UILabel alloc] initWithFrame:CGRectMake(cw3 - 80, 7, 66, 30)];
            valLbl.text = [NSString stringWithFormat:@"%.0fpt", floatingFontSize];
            valLbl.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightBold];
            valLbl.textColor = [UIColor systemBlueColor];
            valLbl.textAlignment = NSTextAlignmentRight;
            valLbl.tag = 961;
            [cell.contentView addSubview:valLbl];
            UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(112, 11, cw3 - 112 - 84, 32)];
            slider.minimumValue = 8.0; slider.maximumValue = 15.0; slider.value = floatingFontSize;
            slider.continuous = YES;
            slider.tag = 964;
            [slider addTarget:self action:@selector(changeFontSlider:) forControlEvents:UIControlEventValueChanged];
            [cell.contentView addSubview:slider];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (indexPath.row == 4) {
            // 圆角大小：一行式
            cell.textLabel.hidden = YES;
            cell.detailTextLabel.hidden = YES;
            CGFloat cw4 = self.tableView.bounds.size.width - 32.0;
            UILabel *titleLbl = [[UILabel alloc] initWithFrame:CGRectMake(16, 8, 90, 28)];
            titleLbl.text = @"圆角大小";
            titleLbl.font = [UIFont systemFontOfSize:16 weight:UIFontWeightRegular];
            titleLbl.textColor = [UIColor labelColor];
            titleLbl.tag = 968;
            [cell.contentView addSubview:titleLbl];
            UILabel *valLbl = [[UILabel alloc] initWithFrame:CGRectMake(cw4 - 80, 7, 66, 30)];
            valLbl.text = [NSString stringWithFormat:@"%.0f", floatingCornerRadius];
            valLbl.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightBold];
            valLbl.textColor = [UIColor systemBlueColor];
            valLbl.textAlignment = NSTextAlignmentRight;
            valLbl.tag = 962;
            [cell.contentView addSubview:valLbl];
            UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(112, 11, cw4 - 112 - 84, 32)];
            slider.minimumValue = 4.0; slider.maximumValue = 35.0; slider.value = floatingCornerRadius;
            slider.continuous = YES;
            slider.tag = 965;
            [slider addTarget:self action:@selector(changeCornerRadiusSlider:) forControlEvents:UIControlEventValueChanged];
            [cell.contentView addSubview:slider];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
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
    } else if (indexPath.section == 7) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"充电增强（实时验证）";
            UISwitch *sw = [UISwitch new];
            sw.on = chargeBoostEnable;
            [sw addTarget:self action:@selector(changeChargeBoost:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"🔋 快充辅助（安全模式）";
            cell.detailTextLabel.text = @"尝试设为100%上限，不绕过温控";
            UISwitch *sw = [UISwitch new];
            sw.on = forceFastChargeEnable;
            [sw addTarget:self action:@selector(changeForceFastCharge:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (indexPath.row == 2) {
            cell.textLabel.text = @"🛡️ 屏蔽部件与维修记录";
            cell.detailTextLabel.text = @"隐藏部件与服务历史（电池/屏幕/相机），保留电池健康页";
            UISwitch *sw = [UISwitch new];
            sw.on = suppressPartRepairEnabled;
            [sw addTarget:self action:@selector(changeSuppressPartRepair:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (indexPath.row == 3) {
            cell.textLabel.text = @"📊 充电历史";
            loadChargeSessionsFromDisk();
            NSInteger cnt = gChargeSessions ? gChargeSessions.count : 0;
            cell.detailTextLabel.text = cnt > 0 ? [NSString stringWithFormat:@"%ld 条记录", (long)cnt] : @"暂无记录";
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        } else if (indexPath.row == 4) {
            cell.textLabel.text = @"⛔ 阻止充电";
            BOOL smcOK = (sbSMCInit() == kIOReturnSuccess);
            cell.detailTextLabel.text = smcOK
                ? (sbSMCGetChargeBlocked() ? @"已阻止充电（保留供电）" : @"硬件级停充（AppleSMC CH0C）")
                : @"SMC 守护进程未运行";
            UISwitch *sw = [UISwitch new];
            sw.on = blockChargingEnable && smcOK;
            [sw addTarget:self action:@selector(changeBlockCharging:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (indexPath.row == 5) {
            cell.textLabel.text = @"🚫 阻止外部供电";
            BOOL smcOK = (sbSMCInit() == kIOReturnSuccess);
            cell.detailTextLabel.text = smcOK
                ? (sbSMCGetPowerBlocked() ? @"已断开外部供电" : @"硬件级断供（AppleSMC CH0I）")
                : @"SMC 守护进程未运行";
            UISwitch *sw = [UISwitch new];
            sw.on = blockPowerEnable && smcOK;
            [sw addTarget:self action:@selector(changeBlockPower:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
    } else if (indexPath.section == 8) {
        CGFloat cw = self.tableView.bounds.size.width - 32.0; // 滑块行布局需要（稳定口径）
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
        } else if (indexPath.row == 7) {
            // 玻璃不透明度滑块
            cell.textLabel.text = @"玻璃不透明度";
            cell.textLabel.hidden = NO;
            cell.detailTextLabel.hidden = YES;
            UILabel *valLbl = [[UILabel alloc] initWithFrame:CGRectMake(cw - 90, 8, 75, 28)];
            valLbl.text = [NSString stringWithFormat:@"%.0f%%", glassDimOpacity * 100.0f];
            valLbl.font = [UIFont monospacedDigitSystemFontOfSize:16 weight:UIFontWeightBold];
            valLbl.textColor = [UIColor systemBlueColor];
            valLbl.textAlignment = NSTextAlignmentRight;
            valLbl.tag = 950;
            [cell.contentView addSubview:valLbl];
            UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(16, 40, cw - 32, 30)];
            slider.minimumValue = 40;
            slider.maximumValue = 100;
            slider.value = glassDimOpacity * 100.0f;
            slider.continuous = NO;
            slider.minimumTrackTintColor = [UIColor systemBlueColor];
            slider.tag = 951;
            [slider addTarget:self action:@selector(changeGlassDimOpacity:) forControlEvents:UIControlEventValueChanged];
            [cell.contentView addSubview:slider];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (indexPath.row == 8) {
            cell.textLabel.text = @"显示 SIM 卡信号";
            cell.detailTextLabel.text = @"浮窗底部显示运营商、网络制式和信号强度";
            UISwitch *sw = [UISwitch new];
            sw.on = showSignalStrength;
            [sw addTarget:self action:@selector(changeShowSignalStrength:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (indexPath.row == 9) {
            cell.textLabel.text = @"浮窗吸附到状态栏";
            cell.detailTextLabel.text = @"开启后在灵动岛下方显示可选信息胶囊";
            UISwitch *sw = [UISwitch new];
            sw.on = statusBarDockEnable;
            [sw addTarget:self action:@selector(changeStatusBarDock:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (indexPath.row == 10) {
            cell.textLabel.text = @"顶部显示 CPU";
            UISwitch *sw = [UISwitch new]; sw.on = statusDockShowCPU;
            [sw addTarget:self action:@selector(changeStatusDockCPU:) forControlEvents:UIControlEventValueChanged]; cell.accessoryView = sw;
        } else if (indexPath.row == 11) {
            cell.textLabel.text = @"顶部显示 FPS";
            UISwitch *sw = [UISwitch new]; sw.on = statusDockShowFPS;
            [sw addTarget:self action:@selector(changeStatusDockFPS:) forControlEvents:UIControlEventValueChanged]; cell.accessoryView = sw;
        } else if (indexPath.row == 12) {
            cell.textLabel.text = @"顶部显示 CPU 频率";
            UISwitch *sw = [UISwitch new]; sw.on = statusDockShowFrequency;
            [sw addTarget:self action:@selector(changeStatusDockFrequency:) forControlEvents:UIControlEventValueChanged]; cell.accessoryView = sw;
        } else if (indexPath.row == 13) {
            cell.textLabel.text = @"顶部显示电流";
            UISwitch *sw = [UISwitch new]; sw.on = statusDockShowCurrent;
            [sw addTarget:self action:@selector(changeStatusDockCurrent:) forControlEvents:UIControlEventValueChanged]; cell.accessoryView = sw;
        } else if (indexPath.row == 14) {
            cell.textLabel.text = @"顶部显示温度";
            UISwitch *sw = [UISwitch new]; sw.on = statusDockShowTemperature;
            [sw addTarget:self action:@selector(changeStatusDockTemperature:) forControlEvents:UIControlEventValueChanged]; cell.accessoryView = sw;
        } else if (indexPath.row == 15) {
            cell.textLabel.text = @"顶部显示电量";
            UISwitch *sw = [UISwitch new]; sw.on = statusDockShowBattery;
            [sw addTarget:self action:@selector(changeStatusDockBattery:) forControlEvents:UIControlEventValueChanged]; cell.accessoryView = sw;
        } else if (indexPath.row == 16) {
            cell.textLabel.text = @"顶部显示 SIM1 信号";
            UISwitch *sw = [UISwitch new]; sw.on = statusDockShowSIM1;
            [sw addTarget:self action:@selector(changeStatusDockSIM1:) forControlEvents:UIControlEventValueChanged]; cell.accessoryView = sw;
        } else if (indexPath.row == 17) {
            cell.textLabel.text = @"顶部显示 SIM2 信号";
            UISwitch *sw = [UISwitch new]; sw.on = statusDockShowSIM2;
            [sw addTarget:self action:@selector(changeStatusDockSIM2:) forControlEvents:UIControlEventValueChanged]; cell.accessoryView = sw;
        } else if (indexPath.row == 18) {
            cell.textLabel.text = @"顶部拖动回位延迟";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld 秒", (long)statusDockReturnDelay];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (indexPath.row == 19) {
            cell.textLabel.text = @"浮窗数值刷新频率";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%.2g 秒", floatingValueRefreshInterval];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    }
    applySettingsTheme(cell, indexPath);
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == 8 && indexPath.row == 19) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"浮窗数值刷新频率"
            message:@"数值越小越实时，也会增加桌面读取和刷新开销。"
            preferredStyle:UIAlertControllerStyleActionSheet];
        NSArray *values = @[@1.0, @2.0];
        for (NSNumber *number in values) {
            [alert addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%.2g 秒", number.doubleValue]
                style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                    floatingValueRefreshInterval = number.doubleValue;
                    setFloatPref(CFSTR("floatingValueRefreshInterval"), (float)floatingValueRefreshInterval);
                    [gFloatingUpdateTimer invalidate];
                    gFloatingUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:floatingValueRefreshInterval repeats:YES block:^(NSTimer *timer) { updateCPU(); chargeSessionTick(); }];
                    [[NSRunLoop mainRunLoop] addTimer:gFloatingUpdateTimer forMode:NSRunLoopCommonModes];
                    [self.tableView reloadData];
                }]];
        }
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        alert.popoverPresentationController.sourceView = self.view;
        alert.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    if (indexPath.section == 8 && indexPath.row == 18) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"顶部拖动回位延迟"
            message:@"松手后等待所选秒数，再平滑回到顶部；再次拖动会重新计时。"
            preferredStyle:UIAlertControllerStyleActionSheet];
        for (NSInteger seconds = 1; seconds <= 30; seconds++) {
            [alert addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%ld 秒", (long)seconds]
                style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                    statusDockReturnDelay = seconds;
                    SavePreferencesAndNotify();
                    if (floatingView.statusDockReturnTimer.valid) [floatingView scheduleStatusDockReturn];
                    [self.tableView reloadData];
                }]];
        }
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        alert.popoverPresentationController.sourceView = self.view;
        alert.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    // 🔍 插件冲突检测：点击冲突警告或插件显示详情
    if (indexPath.section == 12) {
        if (indexPath.row == 0) return;

        // 点击冲突警告（row 1 ~ gPluginConflictCount）
        if (indexPath.row <= gPluginConflictCount && gPluginConflicts.count > 0) {
            NSInteger conflictIndex = indexPath.row - 1;
            if (conflictIndex >= 0 && conflictIndex < (NSInteger)gPluginConflicts.count) {
                NSDictionary *conflict = gPluginConflicts[conflictIndex];
                NSString *title = conflict[@"title"] ?: @"冲突";
                NSString *desc = conflict[@"desc"] ?: @"";
                NSInteger severity = [conflict[@"severity"] integerValue];
                NSArray *plugins = conflict[@"plugins"] ?: @[];
                NSString *severityStr = (severity == 0) ? @"🔴 高风险" : (severity == 1) ? @"🟡 中风险" : @"🟢 低风险";

                NSMutableString *pluginStr = [NSMutableString string];
                for (NSString *p in plugins) {
                    [pluginStr appendFormat:@"\n• %@", p];
                }

                NSString *message = [NSString stringWithFormat:@"风险等级：%@\n\n冲突说明：%@\n\n涉及插件：%@\n\n建议：禁用其中一个插件，或确认两者功能不重叠后继续使用", severityStr, desc, pluginStr];

                UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:alert animated:YES completion:nil];
                return;
            }
        }

        // 点击插件列表（需要跳过分类标题行）
        if (gInstalledPlugins.count == 0) return;
        NSInteger listStartRow = 1 + gPluginConflictCount;
        NSInteger relativeRow = indexPath.row - listStartRow;
        NSInteger currentRow = 0;
        NSInteger pluginIndex = -1;
        for (NSInteger catIdx = 0; catIdx < (NSInteger)gPluginCategories.count; catIdx++) {
            NSDictionary *catInfo = gPluginCategories[catIdx];
            NSInteger catCount = [catInfo[@"count"] integerValue];
            NSInteger catStart = [catInfo[@"startIndex"] integerValue];
            currentRow++; // 跳过分类标题行
            for (NSInteger j = 0; j < catCount; j++) {
                if (relativeRow == currentRow) {
                    pluginIndex = catStart + j;
                    break;
                }
                currentRow++;
            }
            if (pluginIndex >= 0) break;
        }
        if (pluginIndex < 0 || pluginIndex >= (NSInteger)gInstalledPlugins.count) return;

        NSDictionary *plugin = gInstalledPlugins[pluginIndex];
        NSString *name = plugin[@"name"] ?: @"未知";
        NSString *version = plugin[@"version"] ?: @"未知";
        NSString *desc = plugin[@"desc"] ?: @"暂无描述";
        NSString *category = plugin[@"category"] ?: @"其他";
        NSString *bundleID = plugin[@"bundleID"] ?: @"未知";
        NSArray *injected = plugin[@"injectedBundles"] ?: @[];

        // 🎨 创建插件详情视图控制器
        UIViewController *detailVC = [[UIViewController alloc] init];
        detailVC.view.backgroundColor = [UIColor systemBackgroundColor];
        detailVC.title = @"插件详情";

        // 导航栏关闭按钮（用 self 处理，避免参数不匹配崩溃）
        UIBarButtonItem *closeBtn = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(closePluginDetail:)];
        detailVC.navigationItem.rightBarButtonItem = closeBtn;

        // 滚动视图
        UIScrollView *scrollView = [[UIScrollView alloc] initWithFrame:detailVC.view.bounds];
        scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [detailVC.view addSubview:scrollView];

        CGFloat y = 20;
        CGFloat w = detailVC.view.bounds.size.width - 40;

        // 插件名称（大标题）
        UILabel *nameLbl = [[UILabel alloc] initWithFrame:CGRectMake(20, y, w, 32)];
        nameLbl.text = name;
        nameLbl.font = [UIFont systemFontOfSize:24 weight:UIFontWeightBold];
        nameLbl.textColor = [UIColor labelColor];
        [scrollView addSubview:nameLbl];
        y += 40;

        // 版本号 + 分类
        UILabel *verLbl = [[UILabel alloc] initWithFrame:CGRectMake(20, y, w, 20)];
        verLbl.text = [NSString stringWithFormat:@"版本：v%@  ·  分类：%@", version, category];
        verLbl.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        verLbl.textColor = [UIColor secondaryLabelColor];
        [scrollView addSubview:verLbl];
        y += 28;

        // Bundle ID
        UILabel *bidLbl = [[UILabel alloc] initWithFrame:CGRectMake(20, y, w, 18)];
        bidLbl.text = [NSString stringWithFormat:@"Bundle ID：%@", bundleID];
        bidLbl.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
        bidLbl.textColor = [UIColor tertiaryLabelColor];
        [scrollView addSubview:bidLbl];
        y += 24;

        // 分隔线
        UIView *sep1 = [[UIView alloc] initWithFrame:CGRectMake(20, y, w, 1)];
        sep1.backgroundColor = [UIColor separatorColor];
        [scrollView addSubview:sep1];
        y += 16;

        // 描述标题
        UILabel *descTitle = [[UILabel alloc] initWithFrame:CGRectMake(20, y, w, 20)];
        descTitle.text = @"插件描述";
        descTitle.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        descTitle.textColor = [UIColor labelColor];
        [scrollView addSubview:descTitle];
        y += 26;

        // 描述内容（为空时显示默认值）
        if (desc.length == 0 || [desc isEqualToString:@"暂无描述"]) {
            desc = @"该插件未提供描述信息";
        }
        UILabel *descLbl = [[UILabel alloc] initWithFrame:CGRectMake(20, y, w, 0)];
        descLbl.text = desc;
        descLbl.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
        descLbl.textColor = [UIColor secondaryLabelColor];
        descLbl.numberOfLines = 0;
        [descLbl sizeToFit];
        descLbl.frame = CGRectMake(20, y, w, descLbl.frame.size.height);
        [scrollView addSubview:descLbl];
        y += descLbl.frame.size.height + 20;

        // 分隔线
        UIView *sep2 = [[UIView alloc] initWithFrame:CGRectMake(20, y, w, 1)];
        sep2.backgroundColor = [UIColor separatorColor];
        [scrollView addSubview:sep2];
        y += 16;

        // 注入进程标题
        UILabel *injectTitle = [[UILabel alloc] initWithFrame:CGRectMake(20, y, w, 20)];
        injectTitle.text = [NSString stringWithFormat:@"注入进程（%ld 个）", (long)injected.count];
        injectTitle.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        injectTitle.textColor = [UIColor labelColor];
        [scrollView addSubview:injectTitle];
        y += 26;

        // 注入进程列表
        if (injected.count > 0) {
            for (NSString *bundle in injected) {
                UILabel *bundleLbl = [[UILabel alloc] initWithFrame:CGRectMake(30, y, w - 10, 18)];
                bundleLbl.text = [NSString stringWithFormat:@"• %@", bundle];
                bundleLbl.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
                bundleLbl.textColor = [UIColor secondaryLabelColor];
                [scrollView addSubview:bundleLbl];
                y += 22;
            }
        } else {
            UILabel *noInject = [[UILabel alloc] initWithFrame:CGRectMake(30, y, w - 10, 18)];
            noInject.text = @"无（全局注入或未配置 Filter）";
            noInject.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
            noInject.textColor = [UIColor tertiaryLabelColor];
            [scrollView addSubview:noInject];
            y += 22;
        }

        // 耗电评估
        UIView *sep3 = [[UIView alloc] initWithFrame:CGRectMake(20, y, w, 1)];
        sep3.backgroundColor = [UIColor separatorColor];
        [scrollView addSubview:sep3];
        y += 16;

        UILabel *powerTitle = [[UILabel alloc] initWithFrame:CGRectMake(20, y, w, 20)];
        powerTitle.text = @"耗电评估";
        powerTitle.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        powerTitle.textColor = [UIColor labelColor];
        [scrollView addSubview:powerTitle];
        y += 26;

        NSString *powerDesc = powerConsumptionDesc(plugin);
        UILabel *powerLbl = [[UILabel alloc] initWithFrame:CGRectMake(20, y, w, 0)];
        powerLbl.text = powerDesc;
        powerLbl.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
        powerLbl.textColor = [UIColor secondaryLabelColor];
        powerLbl.numberOfLines = 0;
        [powerLbl sizeToFit];
        powerLbl.frame = CGRectMake(20, y, w, powerLbl.frame.size.height);
        [scrollView addSubview:powerLbl];
        y += powerLbl.frame.size.height + 20;

        scrollView.contentSize = CGSizeMake(detailVC.view.bounds.size.width, y + 20);

        // 用导航控制器包裹，显示导航栏
        UINavigationController *navVC = [[UINavigationController alloc] initWithRootViewController:detailVC];
        navVC.modalPresentationStyle = UIModalPresentationFormSheet;
        // 保存当前 presentedViewController 引用，用于关闭
        objc_setAssociatedObject(self, "presentedPluginDetail", navVC, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self presentViewController:navVC animated:YES completion:nil];
        return;
    }

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
        } else if (indexPath.row == 4) {
            SBCPUSpringBoardLockCleanupWhitelistController *vc = [[SBCPUSpringBoardLockCleanupWhitelistController alloc] initWithStyle:UITableViewStyleInsetGrouped];
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
    } else if (indexPath.section == 7) {
        if (indexPath.row == 3) {
            SBCPUSpringBoardChargeHistoryController *vc = [[SBCPUSpringBoardChargeHistoryController alloc] initWithStyle:UITableViewStyleInsetGrouped];
            [self.navigationController pushViewController:vc animated:YES];
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
    if (cell) {
        UILabel *l = [cell.contentView viewWithTag:960];
        if (l) l.text = [NSString stringWithFormat:@"%.0f%%", floatingScale * 100];
        else cell.detailTextLabel.text = [NSString stringWithFormat:@"%.0f%%", floatingScale * 100];
    }

    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(saveConfigs) object:nil];
    [self performSelector:@selector(saveConfigs) withObject:nil afterDelay:0.5];
}

- (void)changeFontSlider:(UISlider *)s {
    floatingFontSize = s.value;
    UITableViewCell *cell = [self _cellForView:s];
    if (cell) {
        UILabel *l = [cell.contentView viewWithTag:961];
        if (l) l.text = [NSString stringWithFormat:@"%.0fpt", floatingFontSize];
        else cell.detailTextLabel.text = [NSString stringWithFormat:@"%.0fpt", floatingFontSize];
    }

    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(saveConfigs) object:nil];
    [self performSelector:@selector(saveConfigs) withObject:nil afterDelay:0.5];
}

- (void)changeCornerRadiusSlider:(UISlider *)s {
    floatingCornerRadius = s.value;
    UITableViewCell *cell = [self _cellForView:s];
    if (cell) {
        UILabel *l = [cell.contentView viewWithTag:962];
        if (l) l.text = [NSString stringWithFormat:@"%.0f", floatingCornerRadius];
        else cell.detailTextLabel.text = [NSString stringWithFormat:@"%.0f", floatingCornerRadius];
    }

    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(saveConfigs) object:nil];
    [self performSelector:@selector(saveConfigs) withObject:nil afterDelay:0.5];
}
// ==========================================

// UI Switch Actions
- (void)changeAutoCollapse:(UISwitch *)sw { autoCollapseEnable = sw.isOn; SavePreferencesAndNotify(); }
- (void)changeAutoExpandLandscape:(UISwitch *)sw { autoExpandLandscape = sw.isOn; SavePreferencesAndNotify(); updateFloatingSize(); }
- (void)changeCompactLandscapeCapsule:(UISwitch *)sw {
    compactLandscapeCapsule = sw.isOn;
    SavePreferencesAndNotify();
    updateFloatingSize();
    // 立即生效：横屏且已折叠时同步胶囊形态（四段 ↔ 单段）
    UIInterfaceOrientation orientation = getEffectiveFloatingOrientation();
    BOOL isLandscape = (orientation == UIInterfaceOrientationLandscapeLeft || orientation == UIInterfaceOrientationLandscapeRight);
    if (isLandscape && floatingView && floatingView.isCollapsed) {
        [floatingView syncCollapsedLayoutForOrientation];
    }
}
- (void)changeLandscapeMode:(UISwitch *)sw { landscapeModeEnable = sw.isOn; SavePreferencesAndNotify(); updateFloatingSize(); }
- (void)changeLogout:(UISwitch *)sw { autoLogoutEnable = sw.isOn; SavePreferencesAndNotify(); }
- (void)changeAlphaEnable:(UISwitch *)sw { floatingAlphaEnable = sw.isOn; SavePreferencesAndNotify(); applyFloatingAlpha(); }
- (void)changeKeyboardAvoid:(UISwitch *)sw { keyboardAvoidEnable = sw.isOn; SavePreferencesAndNotify(); }
- (void)changeSmartDock:(UISwitch *)sw { smartDockEnable = sw.isOn; SavePreferencesAndNotify(); }
- (void)changeRememberPosition:(UISwitch *)sw { rememberPositionEnable = sw.isOn; SavePreferencesAndNotify(); }
- (void)changeStatusBarDock:(UISwitch *)sw {
    statusBarDockEnable = sw.isOn;
    [floatingView.statusDockReturnTimer invalidate];
    floatingView.statusDockReturnTimer = nil;
    floatingView.statusDockDragging = NO;
    SavePreferencesAndNotify();
    if (floatingView) {
        // 状态栏模式本身就是胶囊：开启时立即收起，关闭时恢复完整浮窗。
        if (statusBarDockEnable && !floatingView.isCollapsed) {
            [floatingView collapseToEdgeAnimated:YES];
        } else if (!statusBarDockEnable && floatingView.isCollapsed) {
            [floatingView expandFromEdgeAnimated:YES];
        } else {
            [floatingView syncCollapsedLayoutForOrientation];
            clampAndPositionFloatingView(floatingView.center, YES);
        }
    }
}
- (void)changeStatusDockCPU:(UISwitch *)sw { statusDockShowCPU = sw.isOn; SavePreferencesAndNotify(); if (floatingView) [floatingView syncCollapsedLayoutForOrientation]; }
- (void)changeStatusDockFPS:(UISwitch *)sw { statusDockShowFPS = sw.isOn; SavePreferencesAndNotify(); if (floatingView) [floatingView syncCollapsedLayoutForOrientation]; }
- (void)changeStatusDockFrequency:(UISwitch *)sw { statusDockShowFrequency = sw.isOn; SavePreferencesAndNotify(); if (floatingView) [floatingView syncCollapsedLayoutForOrientation]; }
- (void)changeStatusDockCurrent:(UISwitch *)sw { statusDockShowCurrent = sw.isOn; SavePreferencesAndNotify(); if (floatingView) [floatingView syncCollapsedLayoutForOrientation]; }
- (void)changeStatusDockTemperature:(UISwitch *)sw { statusDockShowTemperature = sw.isOn; SavePreferencesAndNotify(); if (floatingView) [floatingView syncCollapsedLayoutForOrientation]; }
- (void)changeStatusDockBattery:(UISwitch *)sw { statusDockShowBattery = sw.isOn; SavePreferencesAndNotify(); if (floatingView) [floatingView syncCollapsedLayoutForOrientation]; }
- (void)changeStatusDockSIM1:(UISwitch *)sw { statusDockShowSIM1 = sw.isOn; SavePreferencesAndNotify(); if (floatingView) [floatingView syncCollapsedLayoutForOrientation]; }
- (void)changeStatusDockSIM2:(UISwitch *)sw { statusDockShowSIM2 = sw.isOn; SavePreferencesAndNotify(); if (floatingView) [floatingView syncCollapsedLayoutForOrientation]; }
- (void)changeShowCpuFreq:(UISwitch *)sw { showCpuFrequency = sw.isOn; SavePreferencesAndNotify(); updateFloatingSize(); }
- (void)changeShowFps:(UISwitch *)sw { showFps = sw.isOn; SavePreferencesAndNotify(); updateFloatingSize(); }
- (void)changeShowSignalStrength:(UISwitch *)sw { showSignalStrength = sw.isOn; SavePreferencesAndNotify(); updateFloatingSize(); }
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

// 智能停充：开关（V4.22：只改偏好 + 下发 daemon，SMC 决策由 daemon 完成）
- (void)changeSmartChargeEnable:(UISwitch *)sw {
    smartChargeEnable = sw.isOn;
    if (!SBChargePatch(@{@"smartChargeEnable": @(smartChargeEnable)})) {
        LoadPreferences();
        [self.tableView reloadData];
        return;
    }
    SavePreferencesAndNotify();
    if (!smartChargeEnable) {
        smartChargeStopped = NO;
    }
    // 下发配置并让 daemon 立即重判（关闭开关 → daemon 恢复充电）
    updateSmartCharge();
    [self.tableView reloadData];
}

// V4.22 — 阻止充电（手动，经 root daemon 写 AppleSMC CH0C）
- (void)changeBlockCharging:(UISwitch *)sw {
    if (!sw.isOn) {
        // 关闭：经 daemon 恢复充电
        IOReturn initResult = sbSMCInit();
        {
            IOReturn r = initResult == kIOReturnSuccess ? sbSMCSetChargeBlock(NO, NO) : initResult;
            if (r != kIOReturnSuccess) {
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"恢复充电失败"
                    message:sbChargeErrorMessage(r)
                    preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:alert animated:YES completion:nil];
                sw.on = YES;
                return;
            }
        }
        blockChargingEnable = NO;
        SavePreferencesAndNotify();
        updateSmartCharge();
        [self.tableView reloadData];
        return;
    }
    // 开启：先检查 SMC 可用
    if (sbSMCInit() != kIOReturnSuccess) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"阻止充电失败"
            message:sbChargeErrorMessage(kIOReturnNotOpen)
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        sw.on = NO;
        return;
    }
    // 手动请求独立，不能在 SMC 操作前偷偷关闭智能停充。
    IOReturn r = sbSMCSetChargeBlock(YES, NO);
    if (r != kIOReturnSuccess) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"阻止充电失败"
            message:sbChargeErrorMessage(r)
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        sw.on = NO;
        return;
    }
    blockChargingEnable = YES;
    SavePreferencesAndNotify();
    updateSmartCharge();
    [self.tableView reloadData];
}

// V4.22 — 阻止外部供电（手动，经 root daemon 写 AppleSMC CH0I）
- (void)changeBlockPower:(UISwitch *)sw {
    if (!sw.isOn) {
        // 关闭手动断供：先强制清 CH0I，并确认硬件已经恢复；
        // 即使 CHCE 因为之前的 CH0I=1 暂时为 0，也不能阻止恢复。
        if (sbSMCInit() != kIOReturnSuccess) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"恢复外部供电失败"
                message:sbChargeErrorMessage(kIOReturnNotOpen)
                preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
            sw.on = YES;
            return;
        }
        IOReturn r = sbSMCSetPowerBlock(NO, NO);
        if (r != kIOReturnSuccess || sbSMCGetPowerBlocked()) {
            r = sbSMCSetPowerBlock(NO, NO);
        }
        if (r != kIOReturnSuccess || sbSMCGetPowerBlocked()) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"恢复外部供电失败"
                message:sbChargeErrorMessage(r)
                preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
            sw.on = YES;
            return;
        }
        blockPowerEnable = NO;
        SavePreferencesAndNotify();
        updateSmartCharge();
        [self.tableView reloadData];
        return;
    }

    if (sbSMCInit() != kIOReturnSuccess) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"阻止外部供电失败"
            message:sbChargeErrorMessage(kIOReturnNotOpen)
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        sw.on = NO;
        return;
    }
    IOReturn r = sbSMCSetPowerBlock(YES, NO);
    if (r != kIOReturnSuccess) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"阻止外部供电失败"
            message:sbChargeErrorMessage(r)
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        sw.on = NO;
        return;
    }
    blockPowerEnable = YES;
    SavePreferencesAndNotify();
    updateSmartCharge();
    [self.tableView reloadData];
}

- (void)changeSmartThermalEnable:(UISwitch *)sw {
    smartThermalChargeEnable = sw.isOn;
    if (!SBChargePatch(@{@"smartThermalChargeEnable": @(smartThermalChargeEnable)})) {
        LoadPreferences();
        [self.tableView reloadData];
        return;
    }
    SavePreferencesAndNotify();
    updateSmartCharge();
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:9] withRowAnimation:UITableViewRowAnimationNone];
}

- (void)changeSmartThermalUpper:(UISlider *)slider {
    smartThermalUpperC = (NSInteger)lrintf(slider.value);
    if (smartThermalLowerC >= smartThermalUpperC) smartThermalLowerC = MAX(25, smartThermalUpperC - 1);
    UILabel *value = [slider.superview viewWithTag:951];
    if (value) value.text = [NSString stringWithFormat:@"%ld°C", (long)smartThermalUpperC];
    for (UITableViewCell *cell in self.tableView.visibleCells) {
        UISlider *lower = [cell.contentView viewWithTag:954];
        if ([lower isKindOfClass:[UISlider class]]) lower.value = smartThermalLowerC;
        UILabel *lowerValue = [cell.contentView viewWithTag:953];
        if (lowerValue) lowerValue.text = [NSString stringWithFormat:@"%ld°C", (long)smartThermalLowerC];
    }
}

- (void)changeSmartThermalLower:(UISlider *)slider {
    smartThermalLowerC = (NSInteger)lrintf(slider.value);
    if (smartThermalLowerC >= smartThermalUpperC) smartThermalUpperC = MIN(55, smartThermalLowerC + 1);
    for (UITableViewCell *cell in self.tableView.visibleCells) {
        UISlider *upper = [cell.contentView viewWithTag:952];
        if ([upper isKindOfClass:[UISlider class]]) upper.value = smartThermalUpperC;
        UILabel *upperValue = [cell.contentView viewWithTag:951];
        if (upperValue) upperValue.text = [NSString stringWithFormat:@"%ld°C", (long)smartThermalUpperC];
    }
}

- (void)commitSmartThermal:(UISlider *)slider {
    (void)slider;
    if (!SBChargePatch(@{@"smartThermalUpperC": @(smartThermalUpperC), @"smartThermalLowerC": @(smartThermalLowerC)})) {
        LoadPreferences();
        [self.tableView reloadData];
        return;
    }
    SavePreferencesAndNotify();
    updateSmartCharge();
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:9] withRowAnimation:UITableViewRowAnimationNone];
}

// 智能停充：预设模式（V4.22：改偏好后下发 daemon 重判）
- (void)changeSmartChargeMode:(UIButton *)btn {
    smartChargeMode = btn.tag - 900; // 按钮tag=900+i，还原为0/1/2
    if (smartChargeMode == 0) { smartChargeUpperLimit = 80; smartChargeLowerLimit = 70; }
    else if (smartChargeMode == 1) { smartChargeUpperLimit = 100; smartChargeLowerLimit = 90; }
    else if (smartChargeMode == 2) { smartChargeUpperLimit = 60; smartChargeLowerLimit = 50; }
    if (!SBChargePatch(@{@"smartChargeMode": @(smartChargeMode), @"smartChargeUpperLimit": @(smartChargeUpperLimit), @"smartChargeLowerLimit": @(smartChargeLowerLimit)})) {
        LoadPreferences();
        [self.tableView reloadData];
        return;
    }
    SavePreferencesAndNotify();
    smartChargeStopped = NO;
    updateSmartCharge();
    [self.tableView reloadData];
}

// 智能停充：实时更新“充电区间”可视化。
// 拖动过程中不 reloadData、不写 CFPreferences，避免主线程被反复布局/写配置拖慢。
// 松手后再保存，确保设置仍然持久化。
- (void)updateSmartChargeRangeVisualization {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateSmartChargeRangeVisualization];
        });
        return;
    }

    NSIndexPath *path = [NSIndexPath indexPathForRow:2 inSection:9];
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:path];
    if (!cell) return;

    CGFloat cw = self.tableView.bounds.size.width - 32.0;
    CGFloat px = 20.0;
    CGFloat pw = MAX(40.0, cw - 40.0);
    CGFloat by = 62.0;
    CGFloat bh = 14.0;

    UILabel *lowVal = [cell.contentView viewWithTag:901];
    UILabel *highVal = [cell.contentView viewWithTag:903];
    if ([lowVal isKindOfClass:[UILabel class]])
        lowVal.text = [NSString stringWithFormat:@"%ld%%", (long)smartChargeLowerLimit];
    if ([highVal isKindOfClass:[UILabel class]])
        highVal.text = [NSString stringWithFormat:@"%ld%%", (long)smartChargeUpperLimit];

    UIView *rangeBar = [cell.contentView viewWithTag:905];
    if (rangeBar) {
        CGFloat startX = px + (smartChargeLowerLimit / 100.0) * pw;
        CGFloat endX = px + (smartChargeUpperLimit / 100.0) * pw;
        CGFloat width = MAX(bh, endX - startX);

        // 关闭隐式动画：颜色区间与手指移动同一帧更新。
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        rangeBar.frame = CGRectMake(startX, by, width, bh);
        rangeBar.layer.cornerRadius = bh / 2.0;
        [CATransaction commit];

        // Liquid Glass 风格：区间从暖色过渡到绿色，范围变化时实时重绘。
        CAGradientLayer *gradient = nil;
        for (CALayer *sub in [rangeBar.layer.sublayers copy]) {
            if ([sub.name isEqualToString:@"SBCPUSmartChargeGradient"]) {
                gradient = (CAGradientLayer *)sub;
                break;
            }
        }
        if (!gradient) {
            gradient = [CAGradientLayer layer];
            gradient.name = @"SBCPUSmartChargeGradient";
            gradient.startPoint = CGPointMake(0, 0.5);
            gradient.endPoint = CGPointMake(1, 0.5);
            [rangeBar.layer insertSublayer:gradient atIndex:0];
        }
        gradient.frame = rangeBar.bounds;
        gradient.cornerRadius = bh / 2.0;
        gradient.colors = @[
            (id)[UIColor systemOrangeColor].CGColor,
            (id)[UIColor systemYellowColor].CGColor,
            (id)[UIColor systemGreenColor].CGColor
        ];
    }

    // 如果上下限发生自动修正，两个滑块也立即保持一致。
    UISlider *upperSlider = [cell.contentView viewWithTag:931];
    UISlider *lowerSlider = [cell.contentView viewWithTag:941];
    if ([upperSlider isKindOfClass:[UISlider class]])
        [upperSlider setValue:(float)smartChargeUpperLimit animated:NO];
    if ([lowerSlider isKindOfClass:[UISlider class]])
        [lowerSlider setValue:(float)smartChargeLowerLimit animated:NO];
}

// 智能停充：停充上限
- (void)changeSmartChargeUpper:(UISlider *)slider {
    smartChargeUpperLimit = (NSInteger)lrintf(slider.value);
    if (smartChargeUpperLimit <= smartChargeLowerLimit)
        smartChargeLowerLimit = MAX(40, smartChargeUpperLimit - 5);

    smartChargeStopped = NO;
    [self updateSmartChargeRangeVisualization];
}

- (void)commitSmartChargeUpper:(UISlider *)slider {
    (void)slider;
    if (!SBChargePatch(@{@"smartChargeUpperLimit": @(smartChargeUpperLimit), @"smartChargeLowerLimit": @(smartChargeLowerLimit)})) {
        LoadPreferences();
        [self.tableView reloadData];
        return;
    }
    SavePreferencesAndNotify();
    [self updateSmartChargeRangeVisualization];
    updateSmartCharge(); // V4.22：下发配置 + daemon 重判
}

// 智能停充：回充下限
- (void)changeSmartChargeLower:(UISlider *)slider {
    smartChargeLowerLimit = (NSInteger)lrintf(slider.value);
    if (smartChargeLowerLimit >= smartChargeUpperLimit)
        smartChargeUpperLimit = MIN(100, smartChargeLowerLimit + 5);

    smartChargeStopped = NO;
    [self updateSmartChargeRangeVisualization];
}

- (void)commitSmartChargeLower:(UISlider *)slider {
    (void)slider;
    if (!SBChargePatch(@{@"smartChargeUpperLimit": @(smartChargeUpperLimit), @"smartChargeLowerLimit": @(smartChargeLowerLimit)})) {
        LoadPreferences();
        [self.tableView reloadData];
        return;
    }
    SavePreferencesAndNotify();
    [self updateSmartChargeRangeVisualization];
    updateSmartCharge(); // V4.22：下发配置 + daemon 重判
}

// 🔍 插件冲突检测：扫描按钮
- (void)scanPluginsTapped:(UIButton *)sender {
    sender.enabled = NO;
    [sender setTitle:@"扫描中..." forState:UIControlStateNormal];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        scanInstalledPlugins();
        dispatch_async(dispatch_get_main_queue(), ^{
            sender.enabled = YES;
            [self.tableView reloadData];
        });
    });
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

#pragma mark - 🔍 插件冲突检测核心逻辑

// 分类数据库：BundleID → 分类
static NSDictionary *pluginCategoryMap(void) {
    return @{
        // 充电/电池管理
        @"com.mowang.sbcpufloating": @"充电管理",
        @"com.alexander.cputhermal": @"充电管理",
        @"com.opa334.appstore++": @"充电管理",
        // 系统监控
        @"com.nscube.cpu": @"系统监控",
        @"com.artikus.statusvol": @"系统监控",
        // 手势/交互
        @"com.rpetrich.activator": @"手势增强",
        // 主题/美化
        @"com.anemos.neon": @"主题美化",
        // 控制中心
        @"com.a3tweaks.ctcenter": @"控制中心",
    };
}

// 分类关键词（名称/描述包含关键词则归类）
static NSDictionary *categoryKeywords(void) {
    return @{
        @"充电管理": @[@"charge", @"battery", @"充电", @"电池", @"power", @"快充", @"cputhermal", @"powerd", @"fixrepair"],
        @"系统监控": @[@"cpu", @"fps", @"monitor", @"监控", @"status", @"system", @"thermal", @"温度", @"memory", @"0hello"],
        @"手势增强": @[@"gesture", @"activator", @"手势", @"swipe", @"touch", @"squidgesture", @"leftpan"],
        @"主题美化": @[@"theme", @"winterboard", @"snowboard", @"主题", @"美化", @"icon", @"wallpaper", @"themecore", @"kongzhimeihua", @"spectrum"],
        @"控制中心": @[@"control", @"cc", @"控制中心", @"module", @"ccsupport", @"ccborder", @"ccmusic", @"customcc"],
        @"通知中心": @[@"notification", @"nc", @"通知", @"preferenceloader"],
        @"锁屏": @[@"lockscreen", @"锁屏", @"lock", @"nopass"],
        @"截屏录屏": @[@"screenshot", @"record", @"snap", @"截屏", @"录屏", @"snapvision", @"recordanywhere"],
        @"键盘": @[@"keyboard", @"键盘", @"floatingviewkeyboard", @"trollopenkeyboard"],
        @"相机": @[@"camera", @"相机", @"floatingviewcamera", @"trollopencamera", @"pulloverxcamera"],
        @"剪贴板": @[@"paste", @"copy", @"clipboard", @"剪贴板", @"copyvault", @"doubaopaste", @"hellodisablepaste"],
        @"网络代理": @[@"vpn", @"proxy", @"network", @"代理", @"single", @"sandyproxy"],
        @"浮窗": @[@"floating", @"float", @"浮窗", @"pullover", @"floatingview"],
        @"越狱工具": @[@"troll", @"jailbreak", @"越狱", @"jb", @"trollopen", @"choicy", @"aperture"],
        @"桌面": @[@"springboard", @"sb", @"桌面", @"home", @"cranesb", @"sblist", @"folderpro"],
        @"音乐音量": @[@"music", @"volume", @"音乐", @"音量", @"waveform", @"nowaveform"],
        @"应用修改": @[@"tweak", @"hack", @"修改", @"破解", @"plus", @"pro", @"app", @"doubao", @"snapper3", @"appdata", @"apptool"],
    };
}

// 已知冲突对：[bundleID1, bundleID2, 标题, 描述, 严重程度(0高1中2低)]
static NSArray *knownConflictPairs(void) {
    return @[
        // 🔴 高风险（功能直接冲突，可能导致崩溃或功能失效）
        @[@"com.mowang.sbcpufloating", @"com.alexander.cputhermal",
          @"充电管理冲突", @"两个插件同时注入 powerd 并修改充电属性，可能导致充电策略互相覆盖", @0],
        @[@"com.alexander.cputhermal", @"com.nscube.cpu",
          @"温度监控冲突", @"两个插件同时读取温度传感器并修改温控属性，可能导致温度读数异常", @0],
        @[@"com.rpetrich.activator", @"com.a3tweaks.ctcenter",
          @"手势冲突", @"Activator 和控制中心插件可能在底部手势区域冲突，导致手势失效", @0],

        // 🟡 中风险（功能重叠，可能导致性能问题或功能异常）
        @[@"com.mowang.sbcpufloating", @"com.nscube.cpu",
          @"系统监控冲突", @"两个插件同时高频读取 CPU/温度传感器，可能导致读数冲突和额外耗电", @1],
        @[@"com.nscube.cpu", @"com.artikus.statusvol",
          @"状态栏监控冲突", @"两个插件同时在状态栏显示监控信息，可能导致布局重叠", @1],
        @[@"com.a3tweaks.ctcenter", @"com.opa334.ccmodules",
          @"控制中心冲突", @"两个控制中心插件同时修改模块布局，可能导致模块显示异常", @1],
        @[@"com.rpetrich.libgesture", @"com.a3tweaks.libgesture",
          @"手势库冲突", @"两个手势库同时注入，可能导致手势识别异常", @1],

        // 🟢 低风险（功能轻微重叠，一般不影响使用）
        @[@"com.mowang.sbcpufloating", @"com.opa334.appstore++",
          @"功能重叠", @"两个插件都有充电相关功能，建议确认功能不重叠", @2],
        @[@"com.artikus.statusvol", @"com.nscube.cpu",
          @"状态栏重叠", @"两个插件都在状态栏显示信息，建议调整显示位置", @2],
        @[@"com.opa334.ccmodules", @"com.a3tweaks.ctcenter",
          @"控制中心重叠", @"两个控制中心插件功能部分重叠，建议保留一个", @2],
    ];
}

// 根据 BundleID 或名称分类
static NSString *categorizePlugin(NSString *bundleID, NSString *name, NSString *desc) {
    NSDictionary *catMap = pluginCategoryMap();
    if (bundleID && catMap[bundleID]) return catMap[bundleID];

    NSDictionary *kwMap = categoryKeywords();
    NSString *lower = [NSString stringWithFormat:@"%@ %@ %@",
                        bundleID ?: @"", name ?: @"", desc ?: @""].lowercaseString;
    for (NSString *cat in kwMap) {
        for (NSString *kw in kwMap[cat]) {
            if ([lower containsString:kw.lowercaseString]) return cat;
        }
    }
    return @"其他";
}

// 扫描已安装插件
static void scanInstalledPlugins(void) {
    gInstalledPlugins = [NSMutableArray array];
    gPluginConflicts = [NSMutableArray array];
    gPluginTotalCount = 0;
    gPluginConflictCount = 0;
    gScanError = @"";
    gScanMethod = @"";
    gDylibPath = @"";
    gDylibCount = 0;
    gPluginScanDirectoryCount = 0;

    NSFileManager *fm = [NSFileManager defaultManager];

    // 🔥 最可靠的方法：用 dladdr 获取当前插件自己的 .dylib 路径
    // 当前插件(SBCPUFloating)就在 DynamicLibraries 目录里，找到自己就找到了所有插件
    NSMutableArray *selfFoundDylibs = [NSMutableArray array];
    NSMutableSet *selfAddedNames = [NSMutableSet set];
    NSString *selfDylibPath = nil;
    NSString *dynamicLibDir = nil;
    @try {
        Dl_info dlinfo;
        // 用当前插件自己的函数地址，确保返回的是 SBCPUFloating 的路径，不是系统库
        if (dladdr((void *)scanInstalledPlugins, &dlinfo) && dlinfo.dli_fname) {
            selfDylibPath = [NSString stringWithUTF8String:dlinfo.dli_fname];
            NSLog(@"[SBCPUFloating] self dylib path: %@", selfDylibPath);
            dynamicLibDir = [selfDylibPath stringByDeletingLastPathComponent];
            NSLog(@"[SBCPUFloating] DynamicLibraries dir: %@", dynamicLibDir);
            gScanError = [NSString stringWithFormat:@"自身路径:%@", dynamicLibDir];
            NSError *dirErr = nil;
            NSArray *dirFiles = [fm contentsOfDirectoryAtPath:dynamicLibDir error:&dirErr];
            NSLog(@"[SBCPUFloating] dir files: %ld, err: %@", (long)dirFiles.count, dirErr);
            if (dirFiles) {
                // 先收集所有 plist 文件（用于获取注入进程）
                NSMutableDictionary *plistMap = [NSMutableDictionary dictionary];
                for (NSString *f in dirFiles) {
                    if ([f.pathExtension isEqualToString:@"plist"]) {
                        NSString *pn = f.stringByDeletingPathExtension;
                        plistMap[pn] = [dynamicLibDir stringByAppendingPathComponent:f];
                    }
                }
                for (NSString *f in dirFiles) {
                    if ([f.pathExtension isEqualToString:@"dylib"]) {
                        NSString *dn = f.stringByDeletingPathExtension;
                        // 过滤以lib开头的系统库（如libSystem、libobjc等），只保留真正的越狱插件
                        if ([dn hasPrefix:@"lib"]) continue;
                        if (dn.length > 0 && ![selfAddedNames containsObject:dn]) {
                            [selfAddedNames addObject:dn];
                            // 读取同名 plist 获取注入进程
                            NSMutableArray *injectedBundles = [NSMutableArray array];
                            NSString *plistPath = plistMap[dn];
                            if (plistPath) {
                                @try {
                                    NSDictionary *plistDict = [NSDictionary dictionaryWithContentsOfFile:plistPath];
                                    if (plistDict) {
                                        NSDictionary *filter = plistDict[@"Filter"];
                                        if (filter) {
                                            NSArray *bundles = filter[@"Bundles"];
                                            if (bundles) {
                                                for (NSString *b in bundles) {
                                                    if (b.length > 0) [injectedBundles addObject:b];
                                                }
                                            }
                                            NSArray *executables = filter[@"Executables"];
                                            if (executables) {
                                                for (NSString *e in executables) {
                                                    if (e.length > 0) [injectedBundles addObject:e];
                                                }
                                            }
                                        }
                                    }
                                } @catch (NSException *e) {}
                            }
                            [selfFoundDylibs addObject:@{
                                @"name": dn,
                                @"injectedBundles": [injectedBundles copy],
                            }];
                        }
                    }
                }
            }
        }
    } @catch (NSException *e) {
        NSLog(@"[SBCPUFloating] dladdr failed: %@", e);
    }
    gDylibCount = selfFoundDylibs.count;
    NSLog(@"[SBCPUFloating] self-found dylibs: %ld", (long)selfFoundDylibs.count);

    // 如果通过自身路径找到了 dylib，直接用这些作为插件列表（最可靠，不需要猜路径）
    if (selfFoundDylibs.count > 0) {
        gScanMethod = @"自身路径探测";
        gDylibPath = dynamicLibDir ?: @"";
        gPluginScanDirectoryCount = dynamicLibDir.length ? 1 : 0;
        for (NSDictionary *pluginInfo in selfFoundDylibs) {
            NSString *dn = pluginInfo[@"name"];
            NSArray *injected = pluginInfo[@"injectedBundles"];
            [gInstalledPlugins addObject:@{
                @"name": dn, @"bundleID": dn, @"version": @"",
                @"desc": @"", @"injectedBundles": injected ? injected : @[],
                @"category": categorizePlugin(dn, dn, @""),
            }];
            gPluginTotalCount++;
        }
        [gInstalledPlugins sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            NSComparisonResult r = [a[@"category"] compare:b[@"category"]];
            if (r == NSOrderedSame) r = [a[@"name"] compare:b[@"name"]];
            return r;
        }];
        // 构建分类列表
        gPluginCategories = [NSMutableArray array];
        NSString *lastCat = nil;
        for (NSInteger i = 0; i < (NSInteger)gInstalledPlugins.count; i++) {
            NSString *cat = gInstalledPlugins[i][@"category"] ?: @"其他";
            if (![cat isEqualToString:lastCat]) {
                [gPluginCategories addObject:@{@"name": cat, @"startIndex": @(i)}];
                lastCat = cat;
            }
        }
        // 统计每个分类的数量
        for (NSInteger i = 0; i < (NSInteger)gPluginCategories.count; i++) {
            NSInteger start = [gPluginCategories[i][@"startIndex"] integerValue];
            NSInteger end = (i + 1 < (NSInteger)gPluginCategories.count) ? [gPluginCategories[i+1][@"startIndex"] integerValue] : gInstalledPlugins.count;
            gPluginCategories[i] = @{@"name": gPluginCategories[i][@"name"], @"startIndex": @(start), @"count": @(end - start)};
        }
        detectPluginConflicts();
        gPluginScanDone = YES;
        NSLog(@"[SBCPUFloating] scan done via self path, plugins: %ld", (long)gPluginTotalCount);
        return;
    }

    // 1. 读取 DynamicLibraries 目录下的 plist（Substrate/Substitute 通用路径）
    NSArray *libPaths = @[
        @"/Library/MobileSubstrate/DynamicLibraries",
        @"/var/jb/Library/MobileSubstrate/DynamicLibraries",
        @"/usr/lib/TweakInject",
        @"/var/jb/usr/lib/TweakInject",
        @"/Library/TweakInject",
        @"/var/jb/Library/TweakInject",
    ];

    NSMutableDictionary *plistMap = [NSMutableDictionary dictionary]; // dylib名 → {bundles, version, desc}
    NSMutableArray *dylibNames = [NSMutableArray array]; // 所有.dylib文件名（fallback用）
    for (NSString *libPath in libPaths) {
        NSError *err = nil;
        NSArray *files = [fm contentsOfDirectoryAtPath:libPath error:&err];
        NSLog(@"[SBCPUFloating] DynamicLibraries %@ files:%ld err:%@", libPath, (long)files.count, err);
        if (!files) continue;
        gPluginScanDirectoryCount++;
        if (gDylibCount == 0) gDylibPath = libPath;
        for (NSString *f in files) {
            if ([f.pathExtension isEqualToString:@"dylib"]) {
                NSString *dn = [f.stringByDeletingPathExtension copy];
                if (![dylibNames containsObject:dn]) { [dylibNames addObject:dn]; gDylibCount++; }
                continue;
            }
            if (![f.pathExtension isEqualToString:@"plist"]) continue;
            NSString *plistPath = [libPath stringByAppendingPathComponent:f];
            NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:plistPath];
            if (!plist) continue;
            NSMutableArray *bundles = [NSMutableArray array];
            NSDictionary *filter = plist[@"Filter"];
            if (filter) {
                NSArray *b = filter[@"Bundles"];
                if (b) [bundles addObjectsFromArray:b];
                NSArray *e = filter[@"Executables"];
                if (e) [bundles addObjectsFromArray:e];
            } else {
                [bundles addObject:@"*（全局注入）"];
            }
            // 读取版本号和描述
            NSString *version = plist[@"CFBundleShortVersionString"] ?: plist[@"CFBundleVersion"] ?: @"未知";
            NSString *desc = plist[@"CFBundleDescription"] ?: plist[@"NSHumanReadableCopyright"] ?: @"";
            NSString *dylibName = [f.stringByDeletingPathExtension lowercaseString];
            plistMap[dylibName] = @{@"bundles": bundles, @"version": version, @"desc": desc};
        }
    }

    // 2. 用 dpkg -l 命令获取已安装包列表（最可靠，自动适配各种越狱环境）
    NSMutableString *dpkgOutput = [NSMutableString string];
    FILE *pipe = popen("dpkg -l 2>/dev/null", "r");
    if (pipe) {
        char buf[2048];
        while (fgets(buf, sizeof(buf), pipe)) {
            [dpkgOutput appendString:[NSString stringWithUTF8String:buf]];
        }
        pclose(pipe);
    }
    gDpkgOutputLength = dpkgOutput.length;
    gScanMethod = (dpkgOutput.length > 0) ? @"dpkg命令" : @"未获取";
    NSLog(@"[SBCPUFloating] dpkg -l output length: %ld", (long)dpkgOutput.length);

    // 解析 dpkg -l 输出：ii 开头的行是已安装包
    NSMutableArray *packages = [NSMutableArray array];
    if (dpkgOutput.length > 0) {
        NSArray *lines = [dpkgOutput componentsSeparatedByString:@"\n"];
        for (NSString *line in lines) {
            if (![line hasPrefix:@"ii "]) continue;
            // 格式: ii  name  version  arch  description
            NSArray *parts = [line componentsSeparatedByString:@"  "];
            NSMutableArray *cleanParts = [NSMutableArray array];
            for (NSString *p in parts) {
                NSString *trimmed = [p stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                if (trimmed.length > 0) [cleanParts addObject:trimmed];
            }
            if (cleanParts.count >= 2) {
                NSString *pkgName = cleanParts[1];
                NSString *pkgVersion = cleanParts.count > 2 ? cleanParts[2] : @"";
                NSString *pkgDesc = cleanParts.count > 4 ? [[cleanParts subarrayWithRange:NSMakeRange(4, cleanParts.count - 4)] componentsJoinedByString:@" "] : @"";
                [packages addObject:@{@"package": pkgName, @"version": pkgVersion, @"desc": pkgDesc}];
            }
        }
    }
    gDpkgParsedCount = packages.count;
    NSLog(@"[SBCPUFloating] dpkg -l parsed packages: %ld", (long)packages.count);

    // 如果 dpkg -l 没结果，fallback 到文件路径
    if (packages.count == 0) {
        gScanMethod = @"文件路径(fallback)";
        NSLog(@"[SBCPUFloating] dpkg -l failed, trying file paths");
        NSArray *dpkgPaths = @[
            @"/var/lib/dpkg/status",
            @"/private/var/lib/dpkg/status",
            @"/var/jb/var/lib/dpkg/status",
            @"/var/jb/lib/dpkg/status",
            @"/private/var/jb/var/lib/dpkg/status",
        ];
        for (NSString *p in dpkgPaths) {
            BOOL exists = [fm fileExistsAtPath:p];
            NSLog(@"[SBCPUFloating] fallback path %@ exists: %d", p, exists);
            if (!exists) continue;
            NSError *err = nil;
            NSString *content = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:&err];
            if (content && content.length > 100) {
                NSArray *filePkgs = [content componentsSeparatedByString:@"\n\n"];
                for (NSString *pkg in filePkgs) {
                    NSString *package = @"", *version = @"", *desc = @"", *name = @"", *status = @"";
                    NSArray *pkgLines = [pkg componentsSeparatedByString:@"\n"];
                    for (NSString *pl in pkgLines) {
                        if ([pl hasPrefix:@"Package: "]) package = [pl substringFromIndex:9];
                        else if ([pl hasPrefix:@"Version: "]) version = [pl substringFromIndex:9];
                        else if ([pl hasPrefix:@"Description: "]) desc = [pl substringFromIndex:13];
                        else if ([pl hasPrefix:@"Name: "]) name = [pl substringFromIndex:6];
                        else if ([pl hasPrefix:@"Status: "]) status = [pl substringFromIndex:8];
                    }
                    if (package.length == 0) continue;
                    if (status.length > 0 && ![status containsString:@"install"]) continue;
                    [packages addObject:@{@"package": package, @"version": version, @"desc": desc.length > 0 ? desc : (name.length > 0 ? name : package)}];
                }
                break;
            }
        }
    }

    // 如果 dpkg 完全不可用，用 DynamicLibraries 枚举到的 .dylib 文件作为插件列表
    if (packages.count == 0 && dylibNames.count > 0) {
        NSLog(@"[SBCPUFloating] dpkg unavailable, using %ld dylib files as plugin list", (long)dylibNames.count);
        gScanMethod = [NSString stringWithFormat:@"dylib枚举(%@)", gDylibPath];
        for (NSString *dylibName in dylibNames) {
            [packages addObject:@{@"package": dylibName, @"version": @"", @"desc": @""}];
        }
    }

    // 终极 fallback：自动枚举 /var 所有子目录探测越狱根路径（不预设路径，不过滤）
    if (packages.count == 0) {
        NSLog(@"[SBCPUFloating] all methods failed, auto-detecting jailbreak root");
        gScanMethod = @"自动探测";
        NSMutableArray *foundDylibs = [NSMutableArray array];
        NSMutableString *foundPathInfo = [NSMutableString string];

        // 1. 枚举 /var 所有子目录
        NSError *varErr = nil;
        NSArray *varSubdirs = [fm contentsOfDirectoryAtPath:@"/var" error:&varErr];
        NSLog(@"[SBCPUFloating] /var subdirs: %@", varSubdirs);
        [foundPathInfo appendFormat:@"/var子目录:%ld ", (long)varSubdirs.count];

        // 2. 对每个子目录，检查是否包含 DynamicLibraries 或 TweakInject
        for (NSString *subdir in varSubdirs) {
            NSString *rootPath = [@"/var" stringByAppendingPathComponent:subdir];
            // 检查常见的插件目录
            NSArray *pluginDirs = @[
                @"Library/MobileSubstrate/DynamicLibraries",
                @"Library/TweakInject",
                @"usr/lib/TweakInject",
                @"Library/MobileSubstrate",
            ];
            for (NSString *pluginDir in pluginDirs) {
                NSString *fullPath = [rootPath stringByAppendingPathComponent:pluginDir];
                BOOL exists = [fm fileExistsAtPath:fullPath];
                if (exists) {
                    NSLog(@"[SBCPUFloating] FOUND plugin dir: %@", fullPath);
                    [foundPathInfo appendFormat:@"根:%@ ", subdir];
                    NSError *dirErr = nil;
                    NSArray *files = [fm contentsOfDirectoryAtPath:fullPath error:&dirErr];
                    NSLog(@"[SBCPUFloating] files in %@: %ld, err: %@", fullPath, (long)files.count, dirErr);
                    if (files) {
                        for (NSString *f in files) {
                            if ([f.pathExtension isEqualToString:@"dylib"]) {
                                NSString *fileName = f.stringByDeletingPathExtension;
                                if (fileName.length > 0 && ![foundDylibs containsObject:fileName]) {
                                    [foundDylibs addObject:fileName];
                                }
                            }
                        }
                    }
                    if (foundDylibs.count > 0) break;
                }
            }
            if (foundDylibs.count > 0) break;
        }

        // 3. 如果 /var 子目录没找到，试标准路径和 /private/var
        if (foundDylibs.count == 0) {
            NSArray *stdPaths = @[
                @"/Library/MobileSubstrate/DynamicLibraries",
                @"/private/var/jb/Library/MobileSubstrate/DynamicLibraries",
                @"/var/lib/MobileSubstrate/DynamicLibraries",
                @"/usr/lib/TweakInject",
                @"/Library/TweakInject",
            ];
            for (NSString *stdPath in stdPaths) {
                BOOL exists = [fm fileExistsAtPath:stdPath];
                NSLog(@"[SBCPUFloating] std path %@ exists: %d", stdPath, exists);
                if (!exists) continue;
                [foundPathInfo appendFormat:@"标准:%@ ", stdPath.lastPathComponent];
                NSError *stdErr = nil;
                NSArray *stdFiles = [fm contentsOfDirectoryAtPath:stdPath error:&stdErr];
                if (stdFiles) {
                    for (NSString *f in stdFiles) {
                        if ([f.pathExtension isEqualToString:@"dylib"]) {
                            NSString *fileName = f.stringByDeletingPathExtension;
                            if (fileName.length > 0 && ![foundDylibs containsObject:fileName]) {
                                [foundDylibs addObject:fileName];
                            }
                        }
                    }
                }
                if (foundDylibs.count > 0) break;
            }
        }

        // 4. 记录 /var 所有子目录名到调试信息（方便排查）
        if (foundDylibs.count == 0 && varSubdirs.count > 0) {
            [foundPathInfo appendFormat:@"[全部:%@]", [varSubdirs componentsJoinedByString:@","]];
        }

        NSLog(@"[SBCPUFloating] auto-detect found %ld dylibs, pathInfo: %@", (long)foundDylibs.count, foundPathInfo);
        gDylibCount = foundDylibs.count;
        gScanError = [foundPathInfo copy];
        for (NSString *dn in foundDylibs) {
            [packages addObject:@{@"package": dn, @"version": @"", @"desc": @""}];
        }
    }

    // 遍历包列表（统一格式）
    for (NSDictionary *pkgDict in packages) {
        NSString *package = pkgDict[@"package"] ?: @"";
        NSString *version = pkgDict[@"version"] ?: @"";
        NSString *desc = pkgDict[@"desc"] ?: @"";
        NSString *name = package;
        // 只处理有效的包
        if (package.length == 0) continue;
        // 过滤明显的系统包和基础工具（保留 lib 因为很多插件包名含 lib）
        if ([package hasPrefix:@"gsc."] || [package hasPrefix:@"cy+"] ||
            [package hasPrefix:@"apt"] || [package hasPrefix:@"dpkg"] ||
            [package isEqualToString:@"coreutils"] || [package isEqualToString:@"sed"] ||
            [package isEqualToString:@"grep"] || [package isEqualToString:@"bash"] ||
            [package isEqualToString:@"perl"] || [package isEqualToString:@"python"] ||
            [package isEqualToString:@"zstd"] || [package isEqualToString:@"xz"] ||
            [package isEqualToString:@"tar"] || [package isEqualToString:@"gzip"] ||
            [package isEqualToString:@"findutils"] || [package hasPrefix:@"system-cmds"] ||
            [package hasPrefix:@"firmware"] || [package hasPrefix:@"base"]) continue;

        // 匹配 plist 注入信息（同时读取版本号和描述）
        NSArray *injected = @[];
        NSString *plistVersion = nil;
        NSString *plistDesc = nil;
        NSString *pkgLower = package.lowercaseString;
        for (NSString *key in plistMap) {
            if ([pkgLower containsString:key] || [key containsString:pkgLower]) {
                NSDictionary *plistInfo = plistMap[key];
                injected = plistInfo[@"bundles"] ?: @[];
                plistVersion = plistInfo[@"version"];
                plistDesc = plistInfo[@"desc"];
                break;
            }
        }

        // 优先使用 dpkg 的版本号和描述，没有则用 plist 的
        NSString *finalVersion = version.length > 0 ? version : (plistVersion.length > 0 ? plistVersion : @"未知");
        NSString *finalDesc = desc.length > 0 ? desc : (plistDesc.length > 0 ? plistDesc : @"暂无描述");

        NSString *category = categorizePlugin(package, name, finalDesc);

        NSDictionary *pluginInfo = @{
            @"name": name,
            @"bundleID": package,
            @"version": finalVersion,
            @"desc": finalDesc,
            @"injectedBundles": injected,
            @"category": category,
        };
        [gInstalledPlugins addObject:pluginInfo];
        gPluginTotalCount++;
    }

    // 3. 按分类排序
    [gInstalledPlugins sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"category"] compare:b[@"category"]];
    }];

    // 4. 冲突检测
    detectPluginConflicts();

    gPluginScanDone = YES;
}

static void onPluginScanRequested(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    if (![[NSProcessInfo processInfo].processName isEqualToString:@"SpringBoard"]) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        scanInstalledPlugins();
        NSMutableArray *plugins = [NSMutableArray array];
        for (NSDictionary *plugin in gInstalledPlugins ?: @[]) {
            [plugins addObject:@{ @"name": plugin[@"name"] ?: @"未知插件", @"bundleID": plugin[@"bundleID"] ?: @"", @"version": plugin[@"version"] ?: @"", @"category": plugin[@"category"] ?: @"其他", @"desc": plugin[@"desc"] ?: @"", @"injectedBundles": plugin[@"injectedBundles"] ?: @[], @"injectionKnown": @([plugin[@"injectedBundles"] count] > 0) }];
        }
        NSMutableArray *conflicts = [NSMutableArray array];
        for (NSDictionary *conflict in gPluginConflicts ?: @[]) {
            [conflicts addObject:@{ @"title": conflict[@"title"] ?: @"潜在冲突", @"desc": conflict[@"desc"] ?: @"", @"severity": conflict[@"severity"] ?: @0, @"confidence": conflict[@"confidence"] ?: @"heuristic", @"plugins": conflict[@"plugins"] ?: @[] }];
        }
        NSDictionary *snapshot = @{ @"plugins": plugins, @"conflicts": conflicts, @"pluginCount": @(gPluginTotalCount), @"dylibCount": @(gDylibCount), @"directories": @(gPluginScanDirectoryCount), @"scanPath": gDylibPath ?: @"", @"method": gScanMethod ?: @"", @"error": gScanError ?: @"", @"finished": @YES };
        NSData *data = [NSJSONSerialization dataWithJSONObject:snapshot options:0 error:nil];
        if (data) [data writeToFile:@"/var/mobile/Library/Preferences/com.sbcpu.floating.plugin-scan.json" atomically:YES];
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.sbcpu.floating.plugin-scan.finished"), NULL, NULL, YES);
    });
}

// 冲突检测
// ========== 插件耗电等级评估 ==========
// 返回：0=低耗电，1=中耗电，2=高耗电
static NSInteger estimatePowerConsumption(NSDictionary *plugin) {
    NSInteger score = 0;
    NSArray *injected = plugin[@"injectedBundles"] ?: @[];
    NSString *category = plugin[@"category"] ?: @"";

    // 全局注入：最耗电
    for (NSString *b in injected) {
        if ([b isEqualToString:@"*（全局注入）"]) { score += 2; break; }
    }

    // 注入 SpringBoard：常驻系统进程
    for (NSString *b in injected) {
        if ([b.lowercaseString containsString:@"springboard"]) { score += 1; break; }
    }

    // 注入进程数量
    if (injected.count >= 5) score += 2;
    else if (injected.count >= 3) score += 1;

    // 分类评估
    if ([category isEqualToString:@"系统监控"] || [category isEqualToString:@"温度监控"]) {
        score += 2; // 通常高频轮询传感器
    } else if ([category isEqualToString:@"充电管理"] || [category isEqualToString:@"手势操作"]) {
        score += 1;
    }

    // 转换为等级
    if (score >= 3) return 2; // 高耗电
    if (score >= 1) return 1; // 中耗电
    return 0; // 低耗电
}

// 获取耗电等级描述
static NSString *powerConsumptionDesc(NSDictionary *plugin) {
    NSInteger level = estimatePowerConsumption(plugin);
    NSArray *injected = plugin[@"injectedBundles"] ?: @[];
    NSString *category = plugin[@"category"] ?: @"";
    NSMutableString *desc = [NSMutableString string];

    if (level == 2) [desc appendString:@"🔴 高耗电"];
    else if (level == 1) [desc appendString:@"🟡 中耗电"];
    else [desc appendString:@"🟢 低耗电"];

    [desc appendString:@"\n评估依据："];
    BOOL hasGlobal = NO, hasSB = NO;
    for (NSString *b in injected) {
        if ([b isEqualToString:@"*（全局注入）"]) hasGlobal = YES;
        if ([b.lowercaseString containsString:@"springboard"]) hasSB = YES;
    }
    if (hasGlobal) [desc appendString:@"\n• 全局注入所有 App"];
    if (hasSB) [desc appendString:@"\n• 注入 SpringBoard 常驻进程"];
    [desc appendFormat:@"\n• 注入 %ld 个进程", (long)injected.count];
    if ([category isEqualToString:@"系统监控"] || [category isEqualToString:@"温度监控"]) {
        [desc appendString:@"\n• 监控类插件通常高频轮询传感器"];
    } else if ([category isEqualToString:@"充电管理"]) {
        [desc appendString:@"\n• 充电管理类插件持续监听充电状态"];
    }

    return desc;
}

static void detectPluginConflicts(void) {
    // ========== 4a. 已知冲突对检测 ==========
    NSArray *pairs = knownConflictPairs();
    for (NSArray *pair in pairs) {
        NSString *id1 = pair[0], *id2 = pair[1];
        NSString *title = pair[2], *desc = pair[3];
        NSInteger severity = [pair[4] integerValue];
        BOOL found1 = NO, found2 = NO;
        for (NSDictionary *p in gInstalledPlugins) {
            NSString *bid = p[@"bundleID"];
            if ([bid isEqualToString:id1] || [bid.lowercaseString containsString:id1.lowercaseString]) found1 = YES;
            if ([bid isEqualToString:id2] || [bid.lowercaseString containsString:id2.lowercaseString]) found2 = YES;
        }
        if (found1 && found2) {
            [gPluginConflicts addObject:@{
                @"title": title, @"desc": desc, @"severity": @(severity), @"confidence": @"known-rule",
                @"plugins": @[id1, id2],
            }];
            gPluginConflictCount++;
        }
    }

    // ========== 4b. 注入进程重叠检测（增强） ==========
    // 两个插件注入了相同的进程，且分类相同，可能冲突
    NSInteger pluginCount = gInstalledPlugins.count;
    for (NSInteger i = 0; i < pluginCount; i++) {
        for (NSInteger j = i + 1; j < pluginCount; j++) {
            NSDictionary *p1 = gInstalledPlugins[i];
            NSDictionary *p2 = gInstalledPlugins[j];
            NSString *cat1 = p1[@"category"], *cat2 = p2[@"category"];
            // 只检测同分类插件
            if (![cat1 isEqualToString:cat2]) continue;
            // 排除同一个主插件的不同子组件（名称前缀相同）
            NSString *name1 = [p1[@"name"] lowercaseString];
            NSString *name2 = [p2[@"name"] lowercaseString];
            NSString *prefix1 = (name1.length >= 6) ? [name1 substringToIndex:6] : name1;
            NSString *prefix2 = (name2.length >= 6) ? [name2 substringToIndex:6] : name2;
            if ([prefix1 isEqualToString:prefix2]) continue;
            NSArray *b1 = p1[@"injectedBundles"], *b2 = p2[@"injectedBundles"];
            // 计算交集
            NSMutableArray *overlap = [NSMutableArray array];
            for (NSString *bundle in b1) {
                for (NSString *bundle2 in b2) {
                    if ([bundle isEqualToString:bundle2] && ![bundle isEqualToString:@"*（全局注入）"]) {
                        [overlap addObject:bundle];
                        break;
                    }
                }
            }
            if (overlap.count >= 2) {
                NSInteger severity = (overlap.count >= 3) ? 0 : 1;
                NSString *title = [NSString stringWithFormat:@"%@注入重叠", cat1];
                NSString *desc = [NSString stringWithFormat:@"%@ 和 %@ 同时注入 %ld 个相同进程（%@），可能存在功能冲突",
                                  p1[@"name"], p2[@"name"], (long)overlap.count,
                                  [overlap componentsJoinedByString:@"、"]];
                [gPluginConflicts addObject:@{
                    @"title": title, @"desc": desc, @"severity": @(severity), @"confidence": @"injection-overlap",
                    @"plugins": @[p1[@"name"], p2[@"name"]],
                }];
                gPluginConflictCount++;
            }
        }
    }

    // ========== 4c. 功能关键词智能匹配（增强） ==========
    // 基于插件名称和分类的关键词匹配，发现潜在冲突
    NSArray *keywordGroups = @[
        @{@"name": @"充电管理", @"keywords": @[@"charge", @"battery", @"power", @"充电", @"电池", @"快充"], @"severity": @0},
        @{@"name": @"温度监控", @"keywords": @[@"thermal", @"temperature", @"temp", @"温度", @"温控", @"降温"], @"severity": @0},
        @{@"name": @"系统监控", @"keywords": @[@"monitor", @"cpu", @"memory", @"ram", @"监控", @"性能"], @"severity": @1},
        @{@"name": @"手势操作", @"keywords": @[@"gesture", @"activator", @"swipe", @"手势", @"触摸"], @"severity": @1},
        @{@"name": @"控制中心", @"keywords": @[@"controlcenter", @"ccmodule", @"控制中心", @"cc"], @"severity": @1},
        @{@"name": @"状态栏", @"keywords": @[@"statusbar", @"status bar", @"状态栏"], @"severity": @2},
        @{@"name": @"主题美化", @"keywords": @[@"theme", @"winterboard", @"主题", @"美化"], @"severity": @2},
    ];
    for (NSDictionary *group in keywordGroups) {
        NSString *groupName = group[@"name"];
        NSArray *keywords = group[@"keywords"];
        NSInteger groupSeverity = [group[@"severity"] integerValue];
        NSMutableArray *matched = [NSMutableArray array];
        NSMutableSet *seenPrefixes = [NSMutableSet set]; // 去重：同一个主插件的不同子组件只算一个
        for (NSDictionary *p in gInstalledPlugins) {
            NSString *name = [p[@"name"] lowercaseString];
            NSString *cat = [p[@"category"] lowercaseString];
            for (NSString *kw in keywords) {
                if ([name containsString:[kw lowercaseString]] || [cat containsString:[kw lowercaseString]]) {
                    // 提取插件名称前缀（前6个字符），用于识别同一个主插件的不同子组件
                    NSString *prefix = (name.length >= 6) ? [name substringToIndex:6] : name;
                    if (![seenPrefixes containsObject:prefix]) {
                        [seenPrefixes addObject:prefix];
                        [matched addObject:p];
                    }
                    break;
                }
            }
        }
        if (matched.count >= 2) {
            NSMutableArray *names = [NSMutableArray array];
            for (NSDictionary *p in matched) [names addObject:p[@"name"]];
            NSString *title = [NSString stringWithFormat:@"%@功能重叠", groupName];
            NSString *desc = [NSString stringWithFormat:@"检测到 %ld 个%@相关插件（%@），功能可能重叠，建议保留一个",
                              (long)matched.count, groupName, [names componentsJoinedByString:@"、"]];
            [gPluginConflicts addObject:@{
                @"title": title, @"desc": desc, @"severity": @(groupSeverity), @"confidence": @"keyword-heuristic",
                @"plugins": names,
            }];
            gPluginConflictCount++;
        }
    }

    // ========== 4d. 同进程注入过多检测（增强） ==========
    // 统计每个进程被多少插件注入，同时收集插件列表
    NSMutableDictionary *processCount = [NSMutableDictionary dictionary];
    NSMutableDictionary *processPlugins = [NSMutableDictionary dictionary];
    for (NSDictionary *p in gInstalledPlugins) {
        NSArray *bundles = p[@"injectedBundles"];
        for (NSString *b in bundles) {
            if ([b isEqualToString:@"*（全局注入）"]) continue;
            processCount[b] = @([processCount[b] integerValue] + 1);
            if (!processPlugins[b]) processPlugins[b] = [NSMutableArray array];
            [processPlugins[b] addObject:p[@"name"]];
        }
    }
    // 找出注入最多的进程
    NSArray *sortedProcesses = [processCount keysSortedByValueUsingComparator:^NSComparisonResult(id a, id b) {
        return [b compare:a];
    }];
    for (NSString *proc in sortedProcesses) {
        NSInteger count = [processCount[proc] integerValue];
        if (count >= 8) {
            NSInteger severity = (count >= 15) ? 0 : (count >= 10 ? 1 : 2);
            NSArray *plugins = processPlugins[proc];
            [gPluginConflicts addObject:@{
                @"title": [NSString stringWithFormat:@"%@ 注入过多", proc],
                @"desc": [NSString stringWithFormat:@"%ld 个插件注入 %@ 进程，可能影响该进程稳定性", (long)count, proc],
                @"severity": @(severity),
                @"plugins": plugins,
            }];
            gPluginConflictCount++;
        }
    }

    // ========== 4e. 全局注入插件检测（增强） ==========
    NSMutableArray *globalPlugins = [NSMutableArray array];
    for (NSDictionary *p in gInstalledPlugins) {
        NSArray *bundles = p[@"injectedBundles"];
        for (NSString *b in bundles) {
            if ([b isEqualToString:@"*（全局注入）"]) {
                [globalPlugins addObject:p[@"name"]];
                break;
            }
        }
    }
    if (globalPlugins.count >= 3) {
        [gPluginConflicts addObject:@{
            @"title": @"全局注入插件过多",
            @"desc": [NSString stringWithFormat:@"%ld 个插件全局注入（%@），可能影响所有 App 性能",
                      (long)globalPlugins.count, [globalPlugins componentsJoinedByString:@"、"]],
            @"severity": @1,
            @"plugins": globalPlugins,
        }];
        gPluginConflictCount++;
    }

    // ========== 4f. SpringBoard 注入过多检测（保留） ==========
    NSInteger sbCount = 0;
    NSMutableArray *sbPlugins = [NSMutableArray array];
    for (NSDictionary *p in gInstalledPlugins) {
        NSArray *bundles = p[@"injectedBundles"];
        for (NSString *b in bundles) {
            if ([b containsString:@"springboard"] || [b isEqualToString:@"*（全局注入）"]) {
                sbCount++;
                [sbPlugins addObject:p[@"name"]];
                break;
            }
        }
    }
    if (sbCount >= 20) {
        [gPluginConflicts addObject:@{
            @"title": @"SpringBoard 注入过多",
            @"desc": [NSString stringWithFormat:@"%ld 个插件注入 SpringBoard，可能影响系统稳定性和流畅度", (long)sbCount],
            @"severity": @2,
            @"plugins": sbPlugins,
        }];
        gPluginConflictCount++;
    }

    // 去重：相同标题的冲突只保留一个
    NSMutableArray *uniqueConflicts = [NSMutableArray array];
    NSMutableSet *seenTitles = [NSMutableSet set];
    for (NSDictionary *c in gPluginConflicts) {
        NSString *title = c[@"title"];
        if (![seenTitles containsObject:title]) {
            [seenTitles addObject:title];
            [uniqueConflicts addObject:c];
        }
    }
    gPluginConflicts = uniqueConflicts;
    gPluginConflictCount = gPluginConflicts.count;

    // 按严重程度排序
    [gPluginConflicts sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"severity"] compare:b[@"severity"]];
    }];
}

- (void)closePluginDetail:(UIBarButtonItem *)sender {
    UIViewController *vc = objc_getAssociatedObject(self, "presentedPluginDetail");
    if (vc) {
        [vc dismissViewControllerAnimated:YES completion:nil];
        objc_setAssociatedObject(self, "presentedPluginDetail", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

- (void)changeSuppressPartRepair:(UISwitch *)sw {
    suppressPartRepairEnabled = sw.isOn;
    SavePreferencesAndNotify();
}

- (void)changeForceFastCharge:(UISwitch *)sw {
    if (sw.isOn) {
        sw.on = NO;
        forceFastChargeEnable = NO;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"安全充电提示"
                                                                         message:@"此开关仅尝试将电池充电上限设为 100%，不会绕过苹果原厂温度、电流或过热保护，也不能保证提高充电功率。实际功率由充电器、线材、电池温度及系统策略决定。"
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
            applyExperimentalChargeLimit100(YES);
            SavePreferencesAndNotify();
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    } else {
        // 关闭时先同步全局状态，再保存，避免旧状态被重新写回 YES。
        forceFastChargeEnable = NO;
        sw.on = NO;
        applyExperimentalChargeLimit100(chargeBoostEnable);
        SavePreferencesAndNotify();
    }
}



- (void)changeNotificationEnable:(UISwitch *)sw { notificationEnable = sw.isOn; SavePreferencesAndNotify(); }
- (void)changeLandscapeNotificationEnable:(UISwitch *)sw { landscapeNotificationEnable = sw.isOn; SavePreferencesAndNotify(); }
- (void)changeWechatEnable:(UISwitch *)sw { wechatEnable = sw.isOn; SavePreferencesAndNotify(); }
- (void)changeQqEnable:(UISwitch *)sw { qqEnable = sw.isOn; SavePreferencesAndNotify(); }
- (void)changeTimEnable:(UISwitch *)sw { timEnable = sw.isOn; SavePreferencesAndNotify(); }
// 液态玻璃自定义：三个滑块 action + 即时应用
- (void)changeGlassDimOpacity:(UISlider *)sender {
    glassDimOpacity = sender.value / 100.0f;
    setFloatPref(CFSTR("glassDimOpacity"), glassDimOpacity);
    [self applyGlassTheme];
    [self reloadGlassValueLabels];
}
- (void)changeGlassBlurRadius:(UISlider *)sender {
    glassBlurRadius = sender.value;
    setFloatPref(CFSTR("glassBlurRadius"), glassBlurRadius);
    [self applyGlassTheme];
    [self reloadGlassValueLabels];
}
- (void)changeGlassCardOpacity:(UISlider *)sender {
    glassCardOpacity = sender.value / 100.0f;
    setFloatPref(CFSTR("glassCardOpacity"), glassCardOpacity);
    [self.tableView reloadData];
}
- (void)applyGlassTheme {
    // 浅色原生模式下：保持系统浅色背景与白色导航栏（滑块仍保存数值，供浮窗玻璃使用）
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    if (self.glassGradient) {
        self.glassGradient.opacity = glassDimOpacity;
    }
    if (self.glassBackdrop) {
        @try {
            [self.glassBackdrop setValue:@(glassBlurRadius) forKey:@"blurRadius"];
        } @catch (NSException *e) {}
    }
    if (@available(iOS 13.0, *)) {
        UINavigationBarAppearance *app = self.navigationController.navigationBar.standardAppearance;
        if (app) {
            app.backgroundColor = UIColor.whiteColor;
            self.navigationController.navigationBar.standardAppearance = app;
            self.navigationController.navigationBar.scrollEdgeAppearance = app;
            self.navigationController.navigationBar.compactAppearance = app;
        }
    }
}
- (void)reloadGlassValueLabels {
    for (UITableViewCell *cell in self.tableView.visibleCells) {
        UILabel *l = [cell.contentView viewWithTag:950];
        if (l) l.text = [NSString stringWithFormat:@"%.0f%%", glassDimOpacity * 100.0f];
        l = [cell.contentView viewWithTag:952];
        if (l) l.text = [NSString stringWithFormat:@"%.0f", glassBlurRadius];
    }
}
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    if (indexPath.section == 9) {
        if (indexPath.row == 0) return 84.0;  // 智能停充开关（说明两行完整显示）
        if (indexPath.row == 1) return 92.0;   // 预设按钮（卡片式）
        if (indexPath.row == 2) return 88.0;   // 充电区间可视化
        if (indexPath.row == 3 || indexPath.row == 4 || indexPath.row == 6 || indexPath.row == 7) return 78.0; // 百分比/温度滑块
        if (indexPath.row == 5) return 76.0; // 智能温度开关
        return 64.0;
    }
    if (indexPath.section == 2) {
        if (indexPath.row == 2 || indexPath.row == 3 || indexPath.row == 4) return 56.0; // 浮窗/字体/圆角一行式滑块
        return 56.0;
    }
    if (indexPath.section == 8) {
        if (indexPath.row == 7) return 78.0; // 玻璃不透明度滑块
        return 64.0;
    }
    if (indexPath.section == 12) {
        if (indexPath.row == 0) return 116.0;  // 状态卡片
        if (indexPath.row <= gPluginConflictCount) return 88.0;  // 冲突警告卡片
        // 判断是分类标题还是插件
        NSInteger listStartRow = 1 + gPluginConflictCount;
        NSInteger relativeRow = indexPath.row - listStartRow;
        NSInteger currentRow = 0;
        for (NSInteger catIdx = 0; catIdx < (NSInteger)gPluginCategories.count; catIdx++) {
            NSDictionary *catInfo = gPluginCategories[catIdx];
            NSInteger catCount = [catInfo[@"count"] integerValue];
            if (relativeRow == currentRow) return 48.0;  // 分类标题
            currentRow++;
            for (NSInteger j = 0; j < catCount; j++) {
                if (relativeRow == currentRow) return 90.0;  // 插件（名称+两行描述+注入进程）
                currentRow++;
            }
        }
        return 56.0;
    }
    return UITableViewAutomaticDimension;
}

- (void)changeHideContentLockScreen:(UISwitch *)sw { hideContentOnLockScreen = sw.isOn; SavePreferencesAndNotify(); }
- (void)changeLockCleanup:(UISwitch *)sw { lockCleanupEnable = sw.isOn; SavePreferencesAndNotify(); }

@end

#pragma mark - 锁屏清理白名单

// 根据 bundle id 解析应用显示名（LSApplicationWorkspace）
static NSString *appDisplayNameForBundleID(NSString *bundleID) {
    if (![bundleID isKindOfClass:[NSString class]] || bundleID.length == 0) return bundleID;
    Class wsCls = NSClassFromString(@"LSApplicationWorkspace");
    if (wsCls && [wsCls respondsToSelector:@selector(defaultWorkspace)]) {
        id ws = [wsCls performSelector:@selector(defaultWorkspace)];
        if (ws && [ws respondsToSelector:@selector(allApplications)]) {
            NSArray *apps = [ws performSelector:@selector(allApplications)];
            for (id proxy in apps) {
                NSString *bid = [proxy respondsToSelector:@selector(bundleIdentifier)] ? [proxy performSelector:@selector(bundleIdentifier)] : nil;
                if ([bid isKindOfClass:[NSString class]] && [bid isEqualToString:bundleID]) {
                    NSString *name = [proxy respondsToSelector:@selector(localizedName)] ? [proxy performSelector:@selector(localizedName)] : nil;
                    if ([name isKindOfClass:[NSString class]] && name.length > 0) return name;
                    break;
                }
            }
        }
    }
    return bundleID;
}

// ===== 添加白名单：已安装应用选择页 =====
@implementation SBCPULockCleanupAddAppController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"添加白名单应用";
    NSMutableArray *apps = [NSMutableArray array];
    Class wsCls = NSClassFromString(@"LSApplicationWorkspace");
    if (wsCls && [wsCls respondsToSelector:@selector(defaultWorkspace)]) {
        id ws = [wsCls performSelector:@selector(defaultWorkspace)];
        if (ws && [ws respondsToSelector:@selector(allApplications)]) {
            NSArray *all = [ws performSelector:@selector(allApplications)];
            for (id proxy in all) {
                NSString *bid = [proxy respondsToSelector:@selector(bundleIdentifier)] ? [proxy performSelector:@selector(bundleIdentifier)] : nil;
                if (![bid isKindOfClass:[NSString class]] || bid.length == 0) continue;
                [apps addObject:proxy];
            }
        }
    }
    [apps sortUsingComparator:^NSComparisonResult(id a, id b) {
        NSString *na = [a respondsToSelector:@selector(localizedName)] ? [a performSelector:@selector(localizedName)] : @"";
        NSString *nb = [b respondsToSelector:@selector(localizedName)] ? [b performSelector:@selector(localizedName)] : @"";
        return [na localizedCompare:nb];
    }];
    self.allApps = apps;
    self.filteredApps = apps;

    self.searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, self.tableView.bounds.size.width, 44)];
    self.searchBar.delegate = self;
    self.searchBar.placeholder = @"搜索应用";
    self.tableView.tableHeaderView = self.searchBar;
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"Cell"];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.filteredApps.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell" forIndexPath:indexPath];
    id proxy = self.filteredApps[indexPath.row];
    NSString *name = [proxy respondsToSelector:@selector(localizedName)] ? [proxy performSelector:@selector(localizedName)] : @"";
    NSString *bid = [proxy respondsToSelector:@selector(bundleIdentifier)] ? [proxy performSelector:@selector(bundleIdentifier)] : @"";
    cell.textLabel.text = ([name isKindOfClass:[NSString class]] && [name length] > 0) ? name : bid;
    cell.detailTextLabel.text = bid;
    cell.accessoryType = [lockCleanupWhitelist containsObject:bid] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    id proxy = self.filteredApps[indexPath.row];
    NSString *bid = [proxy respondsToSelector:@selector(bundleIdentifier)] ? [proxy performSelector:@selector(bundleIdentifier)] : @"";
    if (![bid isKindOfClass:[NSString class]] || bid.length == 0) return;
    if ([lockCleanupWhitelist containsObject:bid]) {
        [lockCleanupWhitelist removeObject:bid];
    } else {
        [lockCleanupWhitelist addObject:bid];
    }
    SavePreferencesAndNotify();
    [self.tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    if (searchText.length == 0) {
        self.filteredApps = self.allApps;
    } else {
        NSMutableArray *filtered = [NSMutableArray array];
        for (id proxy in self.allApps) {
            NSString *name = [proxy respondsToSelector:@selector(localizedName)] ? [proxy performSelector:@selector(localizedName)] : @"";
            NSString *bid = [proxy respondsToSelector:@selector(bundleIdentifier)] ? [proxy performSelector:@selector(bundleIdentifier)] : @"";
            NSString *haystack = [NSString stringWithFormat:@"%@ %@", name, bid];
            if ([haystack rangeOfString:searchText options:NSCaseInsensitiveSearch].location != NSNotFound) {
                [filtered addObject:proxy];
            }
        }
        self.filteredApps = filtered;
    }
    [self.tableView reloadData];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
}
@end

// ===== 锁屏清理白名单管理页 =====
@implementation SBCPUSpringBoardLockCleanupWhitelistController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"锁屏清理白名单";
    UIBarButtonItem *addBtn = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(addApp)];
    self.navigationItem.rightBarButtonItem = addBtn;
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"Cell"];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"说明";
    return @"白名单应用";
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 1;
    return lockCleanupWhitelist.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell" forIndexPath:indexPath];
    if (indexPath.section == 0) {
        cell.textLabel.text = @"锁屏清理时会跳过白名单中的应用，不杀进程、不清卡片。适合需要持续运行的应用（音乐、下载、导航、输入法等）。";
        cell.textLabel.numberOfLines = 0;
        cell.textLabel.font = [UIFont systemFontOfSize:13];
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    NSString *bid = lockCleanupWhitelist[indexPath.row];
    cell.textLabel.text = appDisplayNameForBundleID(bid);
    cell.detailTextLabel.text = bid;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) return;
    NSString *bid = lockCleanupWhitelist[indexPath.row];
    NSString *name = appDisplayNameForBundleID(bid);
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:name message:[NSString stringWithFormat:@"从白名单移除 %@？", bid] preferredStyle:UIAlertControllerStyleActionSheet];
    [alert addAction:[UIAlertAction actionWithTitle:@"移出白名单" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [lockCleanupWhitelist removeObject:bid];
        SavePreferencesAndNotify();
        [self.tableView reloadData];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)addApp {
    SBCPULockCleanupAddAppController *vc = [[SBCPULockCleanupAddAppController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    [self.navigationController pushViewController:vc animated:YES];
}
@end

@implementation SBCPUSpringBoardChargeHistoryController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"充电历史";
    UIBarButtonItem *clearBtn = [[UIBarButtonItem alloc] initWithTitle:@"清空" style:UIBarButtonItemStylePlain target:self action:@selector(clearAll)];
    self.navigationItem.rightBarButtonItem = clearBtn;
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"Cell"];
    loadChargeSessionsFromDisk();
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    loadChargeSessionsFromDisk();
    [self.tableView reloadData];
}

- (void)clearAll {
    loadChargeSessionsFromDisk();
    NSInteger cnt = gChargeSessions ? gChargeSessions.count : 0;
    if (cnt == 0) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"暂无记录" message:@"还没有任何充电记录" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"清空充电历史" message:[NSString stringWithFormat:@"确定删除全部 %ld 条充电记录？此操作不可恢复", (long)cnt] preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"全部清空" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        clearChargeSessions();
        [self.tableView reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 1;
    loadChargeSessionsFromDisk();
    return gChargeSessions ? gChargeSessions.count : 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"说明";
    loadChargeSessionsFromDisk();
    return [NSString stringWithFormat:@"全部记录（%ld）", (long)(gChargeSessions ? gChargeSessions.count : 0)];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell" forIndexPath:indexPath];
    if (indexPath.section == 0) {
        cell.textLabel.text = @"每次插上充电器自动开始记录，拔下自动归档。包含：时长、充入电量、输入能量、峰值功率、转换效率与热降频时间。";
        cell.textLabel.numberOfLines = 0;
        cell.textLabel.font = [UIFont systemFontOfSize:13];
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    loadChargeSessionsFromDisk();
    NSDictionary *s = gChargeSessions[indexPath.row];
    NSString *timeStr = formatSessionStartTime([s[@"start"] doubleValue]);
    NSString *durStr = formatSessionDurationStr([s[@"duration"] doubleValue]);
    NSInteger sp = [s[@"startPercent"] integerValue], ep = [s[@"endPercent"] integerValue];
    double mah = [s[@"batteryMah"] doubleValue];
    double peak = [s[@"peakInputW"] doubleValue];
    BOOL wireless = [s[@"wireless"] boolValue];
    double inWh = [s[@"inputWh"] doubleValue], batWh = [s[@"batteryWh"] doubleValue];
    NSInteger throttled = [s[@"throttledSeconds"] integerValue];

    NSMutableString *title = [NSMutableString string];
    [title appendFormat:@"%@ · %@ · %ld%%→%ld%%", timeStr, durStr, (long)sp, (long)ep];
    if (wireless) [title appendString:@" · 无线"];
    cell.textLabel.text = title;
    cell.textLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];

    NSMutableString *detail = [NSMutableString string];
    if (mah >= 1) [detail appendFormat:@"充入%.0fmAh", mah];
    if (peak > 0.5) {
        if (detail.length) [detail appendString:@" · "];
        [detail appendFormat:@"峰值%.1fW", peak];
    }
    if (inWh >= 0.001 && batWh >= 0.001) {
        double eff = MIN(batWh / inWh * 100.0, 100.0);
        if (detail.length) [detail appendString:@" · "];
        [detail appendFormat:@"效率%.0f%%", eff];
    }
    if (throttled > 30) {
        if (detail.length) [detail appendString:@" · "];
        [detail appendFormat:@"热降频%@", formatSessionDurationStr(throttled)];
    }
    cell.detailTextLabel.text = detail;
    cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) return;
    loadChargeSessionsFromDisk();
    NSDictionary *s = gChargeSessions[indexPath.row];
    NSMutableString *msg = [NSMutableString string];
    [msg appendFormat:@"开始：%@（电量 %ld%%）\n", formatSessionStartTime([s[@"start"] doubleValue]), (long)[s[@"startPercent"] integerValue]];
    [msg appendFormat:@"时长：%@\n", formatSessionDurationStr([s[@"duration"] doubleValue])];
    [msg appendFormat:@"电量：%ld%% → %ld%%\n", (long)[s[@"startPercent"] integerValue], (long)[s[@"endPercent"] integerValue]];
    if ([s[@"batteryMah"] doubleValue] >= 1) [msg appendFormat:@"充入：%.0f mAh（%.1f Wh）\n", [s[@"batteryMah"] doubleValue], [s[@"batteryWh"] doubleValue]];
    if ([s[@"inputWh"] doubleValue] >= 0.001) {
        double loss = MAX([s[@"inputWh"] doubleValue] - [s[@"batteryWh"] doubleValue], 0);
        [msg appendFormat:@"输入能量：%.1f Wh（损耗 %.1f Wh）\n", [s[@"inputWh"] doubleValue], loss];
    }
    if ([s[@"peakInputW"] doubleValue] > 0.5) [msg appendFormat:@"峰值功率：%.1f W\n", [s[@"peakInputW"] doubleValue]];
    if ([s[@"peakTemp"] isKindOfClass:[NSNumber class]]) [msg appendFormat:@"峰值温度：%.1f°C\n", [s[@"peakTemp"] doubleValue]];
    [msg appendFormat:@"充电方式：%@\n", [s[@"wireless"] boolValue] ? @"无线 (MagSafe)" : @"有线"];
    [msg appendFormat:@"热降频时间：%@", formatSessionDurationStr([s[@"throttledSeconds"] integerValue])];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"充电详情" message:msg preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - 8. 进程通知与 SpringBoard 状态初始化

static void onCCNotificationReceived(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    LoadPreferences();
    if (floatingView) {
        [floatingView applyLiquidGlassStyle];
        [floatingView refreshNativeLiquidGlass];
        updateFloatingSize();
    }
}

static void registerV160Observers(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserverForName:UIDeviceOrientationDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            if (cpuWindow && floatingView) updateFloatingSize();
        }];
        [nc addObserverForName:UIKeyboardWillShowNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            if (floatingView.positionLocked || floatingTextOnlyMode || settingsShowing || detailShowing || !keyboardAvoidEnable) return;
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
            if (!floatingView.positionLocked && !floatingTextOnlyMode && !settingsShowing && !detailShowing && keyboardMoved && floatingView) {
                [UIView animateWithDuration:0.25 animations:^{ floatingView.frame = keyboardBeforeFrame; }]; keyboardMoved = NO;
            }
        }];
    });
}

// ========== 锁屏清理后台（V4.13.1 加固版） ==========
// 注意：SBApplication / FBSSystemService 均为 SpringBoard 私有类，
// 必须先以主类形式声明（不能写 category，否则找不到主 interface 会编译报错）
@interface SBApplication : NSObject
- (BOOL)isRunning;
- (BOOL)isSystemApplication;
- (NSString *)bundleIdentifier;
- (void)killForReason:(long long)reason;
- (int)pid;
@end

@interface FBSSystemService : NSObject
+ (id)sharedService;
- (void)terminateApplication:(NSString *)bundleIdentifier forReason:(int)reason andReport:(BOOL)report withDescription:(NSString *)description;
@end

// App Switcher（后台卡片）模型：用于锁屏后清空后台应用卡片
@interface SBAppSwitcherModel : NSObject
+ (id)sharedInstance;
- (NSArray *)applications;
- (void)removeApplication:(id)application;
- (void)removeApplications:(NSArray *)applications;
@end

// SpringBoard 主工作空间：正规终止流程会联动清理 App Switcher 卡片
@interface SBMainWorkspace : NSObject
+ (id)sharedInstance;
- (void)terminateApplication:(id)application forReason:(int)reason;
@end

// iOS 16+ 的 App Switcher 管理器：卡片 = SBAppLayout（含 SBDisplayItem）
// 清卡片必须用 _deleteAppLayoutsMatchingBundleIdentifier:（社区在 iOS 16/17 验证有效）
@interface SBMainSwitcherControllerCoordinator : NSObject
+ (id)sharedInstance;
- (NSArray *)recentAppLayouts;
- (void)_deleteAppLayoutsMatchingBundleIdentifier:(NSString *)bundleIdentifier;
@end

// 实时读取当前是否已锁屏（所有触发路径共用同一判断）
// 注意：SBLockScreenManager 在 SpringBoard 启动极早期（dyld 构造器阶段）不可访问，
// 此时调用 +sharedInstance 会在 dispatch_once 内抛异常导致 SIGABRT 安全模式，
// 因此 gSBReady 在 %ctor 延迟 3 秒后才置 YES，早期一律返回 NO。
static BOOL gSBReady = NO;
static BOOL isSBLocked(void) {
    if (!gSBReady) return NO;
    Class lockClass = NSClassFromString(@"SBLockScreenManager");
    if (lockClass && [lockClass respondsToSelector:@selector(sharedInstance)]) {
        id mgr = [lockClass performSelector:@selector(sharedInstance)];
        if ([mgr respondsToSelector:@selector(isUILocked)]) {
            return (BOOL)[mgr performSelector:@selector(isUILocked)];
        }
    }
    return NO;
}

// iOS 16+ 专用：统计当前 App Switcher 里的布局数（-1 表示接口不可用）
static long countRecentAppLayouts(void) {
    Class coordCls = NSClassFromString(@"SBMainSwitcherControllerCoordinator");
    if (coordCls && [coordCls respondsToSelector:@selector(sharedInstance)]) {
        id coord = [coordCls performSelector:@selector(sharedInstance)];
        if (coord && [coord respondsToSelector:@selector(recentAppLayouts)]) {
            NSArray *layouts = [coord performSelector:@selector(recentAppLayouts)];
            if ([layouts isKindOfClass:[NSArray class]]) {
                return (long)layouts.count;
            }
        }
    }
    return -1;
}

// iOS 16+ 专用：清空 App Switcher 卡片（SBMainSwitcherControllerCoordinator 方案）
// 逐个 SBAppLayout → SBDisplayItem → bundleIdentifier → _deleteAppLayoutsMatchingBundleIdentifier:
static void clearAllSwitcherCards(void) {
    Class coordCls = NSClassFromString(@"SBMainSwitcherControllerCoordinator");
    if (!coordCls) {
        NSLog(@"[SBCPUFloating] 锁屏清理：SBMainSwitcherControllerCoordinator 类不存在");
        return;
    }
    if (![coordCls respondsToSelector:@selector(sharedInstance)]) {
        NSLog(@"[SBCPUFloating] 锁屏清理：coordinator 无 sharedInstance");
        return;
    }
    id coord = [coordCls performSelector:@selector(sharedInstance)];
    if (!coord) {
        NSLog(@"[SBCPUFloating] 锁屏清理：coordinator 实例不可用");
        return;
    }
    if (![coord respondsToSelector:@selector(recentAppLayouts)]) {
        NSLog(@"[SBCPUFloating] 锁屏清理：coordinator 无 recentAppLayouts 接口");
        return;
    }
    NSArray *layouts = [coord performSelector:@selector(recentAppLayouts)];
    if (![layouts isKindOfClass:[NSArray class]]) {
        NSLog(@"[SBCPUFloating] 锁屏清理：recentAppLayouts 返回类型异常");
        return;
    }
    NSLog(@"[SBCPUFloating] 锁屏清理：当前 recentAppLayouts 共 %lu 个布局", (unsigned long)layouts.count);
    if (![coord respondsToSelector:@selector(_deleteAppLayoutsMatchingBundleIdentifier:)]) {
        NSLog(@"[SBCPUFloating] ⚠️ coordinator 无 _deleteAppLayoutsMatchingBundleIdentifier: 接口");
        return;
    }
    int deleted = 0;
    for (id layout in layouts) {
        NSArray *items = nil;
        if ([layout respondsToSelector:@selector(allItems)]) {
            items = [layout performSelector:@selector(allItems)];
        }
        for (id item in items) {
            NSString *bid = [item respondsToSelector:@selector(bundleIdentifier)] ? [item performSelector:@selector(bundleIdentifier)] : nil;
            if (![bid isKindOfClass:[NSString class]] || bid.length == 0) continue;
            if ([bid isEqualToString:@"com.apple.springboard"]) continue; // 唯一硬排除：不清 SpringBoard 自身
            if ([lockCleanupWhitelist containsObject:bid]) continue; // 白名单保护：不清卡片
            [coord performSelector:@selector(_deleteAppLayoutsMatchingBundleIdentifier:) withObject:bid];
            deleted++;
        }
    }
    NSLog(@"[SBCPUFloating] 锁屏清理：已对 %d 个应用布局调用 _deleteAppLayoutsMatchingBundleIdentifier:", deleted);
}

static void performLockScreenCleanup(void) {
    if (!lockCleanupEnable) return;
    if (!isSBLocked()) return; // 只在真正锁屏时执行
    // 3 秒内去重，防止多个触发路径重复执行
    static CFAbsoluteTime lastCleanupTime = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - lastCleanupTime < 3.0) return;
    lastCleanupTime = now;

    NSLog(@"[SBCPUFloating] 锁屏清理后台：触发，开始清理…");
    // 延后执行：等锁屏动画走完再清，避免与锁屏过程抢主线程
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{

        // ========== 第一步：收集卡片中的应用（iOS 16+ 主方案 + 老接口兜底）==========
        NSMutableSet *bidsToKill = [NSMutableSet set];

        // 来源1（iOS 16+ 主方案）：SBMainSwitcherControllerCoordinator recentAppLayouts → SBDisplayItem
        Class coordCls = NSClassFromString(@"SBMainSwitcherControllerCoordinator");
        if (coordCls && [coordCls respondsToSelector:@selector(sharedInstance)]) {
            id coord = [coordCls performSelector:@selector(sharedInstance)];
            if (coord && [coord respondsToSelector:@selector(recentAppLayouts)]) {
                NSArray *layouts = [coord performSelector:@selector(recentAppLayouts)];
                for (id layout in layouts) {
                    NSArray *items = [layout respondsToSelector:@selector(allItems)] ? [layout performSelector:@selector(allItems)] : nil;
                    for (id item in items) {
                        NSString *bid = [item respondsToSelector:@selector(bundleIdentifier)] ? [item performSelector:@selector(bundleIdentifier)] : nil;
                        if ([bid isKindOfClass:[NSString class]] && bid.length > 0) {
                            [bidsToKill addObject:bid];
                        }
                    }
                }
            }
        }
        // 来源2（老接口兜底）：SBAppSwitcherModel applications
        if (bidsToKill.count == 0) {
            Class swModelCls = NSClassFromString(@"SBAppSwitcherModel");
            if (swModelCls && [swModelCls respondsToSelector:@selector(sharedInstance)]) {
                id swModel = [swModelCls performSelector:@selector(sharedInstance)];
                if (swModel && [swModel respondsToSelector:@selector(applications)]) {
                    NSArray *apps = [swModel performSelector:@selector(applications)];
                    for (id app in apps) {
                        NSString *bid = [app respondsToSelector:@selector(bundleIdentifier)] ? [app performSelector:@selector(bundleIdentifier)] : nil;
                        if ([bid isKindOfClass:[NSString class]] && bid.length > 0) {
                            [bidsToKill addObject:bid];
                        }
                    }
                }
            }
        }
        [bidsToKill removeObject:@"com.apple.springboard"]; // 唯一硬排除：不杀 SpringBoard 自身
        // 白名单跳过：受保护的应用不杀进程、不清卡片
        for (NSString *bid in [bidsToKill copy]) {
            if ([lockCleanupWhitelist containsObject:bid]) {
                NSLog(@"[SBCPUFloating] 锁屏清理：白名单保护，跳过 %@", bid);
                [bidsToKill removeObject:bid];
            }
        }
        NSLog(@"[SBCPUFloating] 锁屏清理：收集到 %lu 个待清理应用", (unsigned long)bidsToKill.count);

        // ========== 第二步：杀进程（SBMainWorkspace 正规终止 → killForReason → SIGKILL）==========
        int killedCount = 0;
        NSMutableArray *killedBids = [NSMutableArray array];
        Class ctrlCls = NSClassFromString(@"SBApplicationController");
        id ctrl = (ctrlCls && [ctrlCls respondsToSelector:@selector(sharedInstance)]) ? [ctrlCls performSelector:@selector(sharedInstance)] : nil;
        Class wsMainCls = NSClassFromString(@"SBMainWorkspace");
        id mainWS = (wsMainCls && [wsMainCls respondsToSelector:@selector(sharedInstance)]) ? [wsMainCls performSelector:@selector(sharedInstance)] : nil;
        for (NSString *bid in bidsToKill) {
            if (![bid isKindOfClass:[NSString class]] || bid.length == 0) continue;
            id app = nil;
            if (ctrl && [ctrl respondsToSelector:@selector(applicationWithBundleIdentifier:)]) {
                app = [ctrl performSelector:@selector(applicationWithBundleIdentifier:) withObject:bid];
            }
            BOOL killed = NO;
            // 方式1（最优）：SBMainWorkspace 正规终止——完整终止流程，系统会联动处理 App Switcher
            if (mainWS && [mainWS respondsToSelector:@selector(terminateApplication:forReason:)] && app) {
                [mainWS terminateApplication:app forReason:0];
                killed = YES;
            }
            // 方式2：killForReason:
            if (!killed && [app respondsToSelector:@selector(killForReason:)]) {
                [app killForReason:1];
                killed = YES;
            }
            // 方式3（兜底）：SIGKILL
            if (!killed && [app respondsToSelector:@selector(pid)]) {
                int pid = [app pid];
                if (pid > 1) {
                    kill(pid, SIGKILL);
                    killed = YES;
                }
            }
            if (killed) {
                killedCount++;
                [killedBids addObject:bid];
            }
        }
        NSLog(@"[SBCPUFloating] 锁屏清理：杀进程完成 %d 个：%@", killedCount, killedBids);

        // ========== 第三步：延迟 0.5 秒等系统完成 termination，再清空卡片 ==========
        // 不能立刻清：App 终止后 FrontBoard 还在更新 workspace，立即清会状态竞争导致卡片残留
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            clearAllSwitcherCards();

            // ========== 第四步：再延迟 0.5 秒回读验证，有残留再清一次 ==========
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                long left = countRecentAppLayouts();
                if (left > 0) {
                    NSLog(@"[SBCPUFloating] 锁屏清理：仍有 %ld 个布局残留，再清一次", left);
                    clearAllSwitcherCards();
                } else if (left == 0) {
                    NSLog(@"[SBCPUFloating] 锁屏清理：后台卡片已全部清空 ✓");
                } else {
                    NSLog(@"[SBCPUFloating] 锁屏清理：验证接口不可用（countRecentAppLayouts=-1）");
                }
            });
        });
    });
}

// 锁屏清理触发：只接受真正的 SBLockScreenManager 锁屏事件。
// 不再监听 com.apple.springboard.lockstate，也不再轮询 isUILocked。
// 某些 iOS 版本在下拉通知中心/展开锁屏相关 UI 时，isUILocked() 或
// lockstate Darwin 通知可能出现短暂状态变化，从而误触发后台清理。
// 现在只在 SBLockScreenManager 的实际 lockUIFromSource* 流程完成后触发。
static void scheduleLockCleanupAfterRealLock(void) {
    if (!lockCleanupEnable) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!lockCleanupEnable) return;
        if (isSBLocked()) {
            performLockScreenCleanup();
        } else {
            NSLog(@"[SBCPUFloating] 锁屏清理：lockUI 事件后未确认真实锁屏，跳过");
        }
    });
}

// 锁屏事件 hook：电源键锁屏 / 自动锁屏 / 手势锁屏。
// 不再由通知中心下拉、lockstate Darwin 通知或轮询触发。
%hook SBLockScreenManager
- (void)lockUIFromSource:(long long)source {
    %orig;
    scheduleLockCleanupAfterRealLock();
}
- (void)lockUIFromSource:(long long)source withOptions:(id)options {
    %orig;
    scheduleLockCleanupAfterRealLock();
}
- (void)_lockUIFromSource:(long long)source withOptions:(id)options {
    %orig;
    scheduleLockCleanupAfterRealLock();
}
%end

// 观测：SBAppSwitcherModel 移除接口是否存在、是否被调用（诊断用）
%hook SBAppSwitcherModel
- (void)removeApplication:(id)application {
    NSLog(@"[SBCPUFloating] hook观测：removeApplication: 被调用，bid=%@", [application respondsToSelector:@selector(bundleIdentifier)] ? [application performSelector:@selector(bundleIdentifier)] : @"?");
    %orig;
}
- (void)removeApplications:(NSArray *)applications {
    NSLog(@"[SBCPUFloating] hook观测：removeApplications: 被调用，%lu 个", (unsigned long)applications.count);
    %orig;
}
%end

// 🚀 终极通知拦截阵列
%hook NCNotificationDispatcher
- (void)postNotificationWithRequest:(id)arg1 {
    %orig;
    [[SBNotificationManager sharedInstance] extractAndHandleRequest:arg1];
}
%end
%hook SBNCNotificationDispatcher
- (void)postNotificationWithRequest:(id)arg1 {
    %orig;
    [[SBNotificationManager sharedInstance] extractAndHandleRequest:arg1];
}
%end

#pragma mark - 9.5 屏蔽部件与维修记录（移植自 CPUthermal PrefHook）

// 完整接口声明（%hook 需要，@class 前向声明不够）
@interface PSSpecifier : NSObject
- (id)propertyForKey:(id)key;
- (void)setProperty:(id)value forKey:(id)key;
@end

@interface PSListController : UIViewController
- (NSArray *)specifiers;
- (void)setSpecifiers:(NSArray *)specifiers;
@end

@interface PSTableCell : UITableViewCell
- (id)specifier;
@end


// ========== 字符串与对象工具 ==========
static BOOL cStringContainsInsensitive(const char *value, const char *token) {
    if (!value || !token || !token[0]) return NO;
    size_t tokenLength = strlen(token);
    for (const char *cursor = value; *cursor; cursor++) {
        size_t index = 0;
        while (index < tokenLength && cursor[index] &&
               tolower((unsigned char)cursor[index]) == tolower((unsigned char)token[index])) index++;
        if (index == tokenLength) return YES;
    }
    return NO;
}

static BOOL cStringEndsWithInsensitive(const char *value, const char *suffix) {
    if (!value || !suffix) return NO;
    size_t valueLength = strlen(value);
    size_t suffixLength = strlen(suffix);
    if (suffixLength > valueLength) return NO;
    return strncasecmp(value + valueLength - suffixLength, suffix, suffixLength) == 0;
}

static id callObjectNoArgument(id object, const char *selectorName) {
    if (!object || !selectorName) return nil;
    SEL selector = sel_registerName(selectorName);
    if (![object respondsToSelector:selector]) return nil;
    IMP implementation = [object methodForSelector:selector];
    return implementation ? ((id (*)(id, SEL))implementation)(object, selector) : nil;
}

static id callObjectWithObject(id object, const char *selectorName, id argument) {
    if (!object || !selectorName) return nil;
    SEL selector = sel_registerName(selectorName);
    if (![object respondsToSelector:selector]) return nil;
    IMP implementation = [object methodForSelector:selector];
    return implementation ? ((id (*)(id, SEL, id))implementation)(object, selector, argument) : nil;
}

static NSString *inspectionStringForValue(id value) {
    if (!value) return nil;
    if ([value isKindOfClass:[NSString class]]) return (NSString *)value;
    if ([value isKindOfClass:[NSURL class]]) return [(NSURL *)value absoluteString];
    Class metaClass = object_getClass(value);
    if (metaClass && class_isMetaClass(metaClass)) return NSStringFromClass((Class)value);
    return nil;
}

static BOOL stringContainsBatteryWarningToken(NSString *value) {
    if (![value isKindOfClass:[NSString class]] || [value length] == 0) return NO;
    static const char *tokens[] = {
        "importantbatterymessage", "important_battery", "important battery message",
        "batteryservicesuggestion", "battery_service", "battery service",
        "servicerecommended", "service_recommended", "service recommended",
        "nongenuinebattery", "nongenuine_battery", "non-genuine battery",
        "batteryhealthunknown", "battery_health_unknown", "battery health unknown",
        "battery not trusted", "untrusted battery", "recalibrat",
        "plfollowupheadercell", "plfollowupsecondaryheadercell",
        "significantly degraded", "unable to verify",
        "unable to determine battery health",
        "unable to determine if your iphone battery is a genuine apple part",
        "genuine apple battery", "battery authenticity",
        "无法确定iphone电池是否为正品apple部件",
        "无法确定 iphone 电池是否为正品 apple 部件",
        "非正品apple部件", "非正品 Apple 部件",
        "重要电池信息", "电池健康状况显著下降",
        "无法验证", "无法确定电池健康状况", "重新校准", "建议维修",
    };
    NSString *lowercaseValue = [value lowercaseString];
    for (NSUInteger index = 0; index < sizeof(tokens) / sizeof(tokens[0]); index++) {
        if ([lowercaseValue rangeOfString:[NSString stringWithUTF8String:tokens[index]]].location != NSNotFound) return YES;
    }
    return NO;
}

static BOOL valueContainsBatteryWarning(id value) {
    NSString *inspectionString = inspectionStringForValue(value);
    if (stringContainsBatteryWarningToken(inspectionString)) return YES;
    if ([value isKindOfClass:[NSDictionary class]]) {
        for (id key in (NSDictionary *)value) {
            if (valueContainsBatteryWarning(key) || valueContainsBatteryWarning([(NSDictionary *)value objectForKey:key])) return YES;
        }
    }
    return NO;
}

static BOOL specifierContainsBatteryWarning(id specifier);

static id filteredBatteryHealthSpecifiers(id result) {
    if (![result isKindOfClass:[NSArray class]]) return result;
    NSArray *specifiers = (NSArray *)result;
    NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:[specifiers count]];
    BOOL removedWarning = NO;
    for (id specifier in specifiers) {
        if (suppressPartRepairEnabled && specifierContainsBatteryWarning(specifier)) {
            removedWarning = YES;
            continue;
        }
        [filtered addObject:specifier];
    }
    if (removedWarning) return filtered;
    return result;
}

// ========== PSSpecifier 属性 hook（隐藏属性强制 YES） ==========
static BOOL gInspectingSpecifier = NO;
static IMP gOrigSpecifierPropertyForKey = NULL;
static IMP gOrigSpecifierSetPropertyForKey = NULL;

static BOOL specifierContainsBatteryWarning(id specifier) {
    if (!specifier) return NO;
    if (stringContainsBatteryWarningToken(NSStringFromClass([specifier class]))) return YES;
    id identifier = callObjectNoArgument(specifier, "identifier");
    id name = callObjectNoArgument(specifier, "name");
    if (valueContainsBatteryWarning(identifier) || valueContainsBatteryWarning(name)) return YES;
    static const char *propertyKeys[] = {
        "id", "identifier", "name", "label", "title", "text",
        "detailText", "footerText", "headerText",
        "cellClass", "headerCellClass", "footerCellClass",
        "url", "URL", "link",
    };
    for (NSUInteger index = 0; index < sizeof(propertyKeys) / sizeof(propertyKeys[0]); index++) {
        id value = callObjectWithObject(specifier, "propertyForKey:", [NSString stringWithUTF8String:propertyKeys[index]]);
        if (valueContainsBatteryWarning(value)) return YES;
    }
    return NO;
}

static id specifierPropertyHook(id self, SEL selector, id key) {
    id result = gOrigSpecifierPropertyForKey ? ((id (*)(id, SEL, id))gOrigSpecifierPropertyForKey)(self, selector, key) : nil;
    if (suppressPartRepairEnabled && !gInspectingSpecifier && [key isKindOfClass:[NSString class]] &&
        ([(NSString *)key caseInsensitiveCompare:@"hidden"] == NSOrderedSame ||
         [(NSString *)key caseInsensitiveCompare:@"isHidden"] == NSOrderedSame)) {
        gInspectingSpecifier = YES;
        BOOL warning = specifierContainsBatteryWarning(self);
        gInspectingSpecifier = NO;
        if (warning) return [NSNumber numberWithBool:YES];
    }
    return result;
}

static void specifierSetPropertyHook(id self, SEL selector, id value, id key) {
    if (gOrigSpecifierSetPropertyForKey) ((void (*)(id, SEL, id, id))gOrigSpecifierSetPropertyForKey)(self, selector, value, key);
}

static void installSpecifierHooks(void) {
    Class cls = objc_getClass("PSSpecifier");
    if (!cls) return;
    SEL getSelector = sel_registerName("propertyForKey:");
    SEL setSelector = sel_registerName("setProperty:forKey:");
    if (!gOrigSpecifierPropertyForKey && class_getInstanceMethod(cls, getSelector)) {
        MSHookMessageEx(cls, getSelector, (IMP)specifierPropertyHook, (IMP *)&gOrigSpecifierPropertyForKey);
    }
    if (!gOrigSpecifierSetPropertyForKey && class_getInstanceMethod(cls, setSelector)) {
        MSHookMessageEx(cls, setSelector, (IMP)specifierSetPropertyHook, (IMP *)&gOrigSpecifierSetPropertyForKey);
    }
}

// ========== 动态扫描 hook 引擎（遍历所有类，自动适配 iOS 版本） ==========
typedef NS_ENUM(NSUInteger, SuppressHookKind) {
    SuppressHookKindSuppressObject,
    SuppressHookKindEmptyArray,
    SuppressHookKindFilterSpecifiers,
};

typedef struct {
    Class targetClass;
    SEL selector;
    IMP original;
    SuppressHookKind kind;
} SuppressHookRecord;

static SuppressHookRecord gSuppressHooks[24];
static NSUInteger gSuppressHookCount = 0;

static id invokeSuppressHook(NSUInteger index, id self, SEL selector) {
    if (index >= gSuppressHookCount) return nil;
    SuppressHookRecord *record = &gSuppressHooks[index];
    IMP original = record->original;
    if (record->kind == SuppressHookKindFilterSpecifiers) {
        id result = original ? ((id (*)(id, SEL))original)(self, selector) : nil;
        return suppressPartRepairEnabled ? filteredBatteryHealthSpecifiers(result) : result;
    }
    if (suppressPartRepairEnabled) {
        if (record->kind == SuppressHookKindEmptyArray) return [NSArray array];
        return nil;
    }
    return original ? ((id (*)(id, SEL))original)(self, selector) : nil;
}

#define DEFINE_SUPPRESS_HOOK(index) \
    static id suppressHook##index(id self, SEL selector) { \
        return invokeSuppressHook(index, self, selector); \
    }

DEFINE_SUPPRESS_HOOK(0)
DEFINE_SUPPRESS_HOOK(1)
DEFINE_SUPPRESS_HOOK(2)
DEFINE_SUPPRESS_HOOK(3)
DEFINE_SUPPRESS_HOOK(4)
DEFINE_SUPPRESS_HOOK(5)
DEFINE_SUPPRESS_HOOK(6)
DEFINE_SUPPRESS_HOOK(7)
DEFINE_SUPPRESS_HOOK(8)
DEFINE_SUPPRESS_HOOK(9)
DEFINE_SUPPRESS_HOOK(10)
DEFINE_SUPPRESS_HOOK(11)
DEFINE_SUPPRESS_HOOK(12)
DEFINE_SUPPRESS_HOOK(13)
DEFINE_SUPPRESS_HOOK(14)
DEFINE_SUPPRESS_HOOK(15)
DEFINE_SUPPRESS_HOOK(16)
DEFINE_SUPPRESS_HOOK(17)
DEFINE_SUPPRESS_HOOK(18)
DEFINE_SUPPRESS_HOOK(19)
DEFINE_SUPPRESS_HOOK(20)
DEFINE_SUPPRESS_HOOK(21)
DEFINE_SUPPRESS_HOOK(22)
DEFINE_SUPPRESS_HOOK(23)

static IMP gSuppressImplementations[] = {
    (IMP)suppressHook0, (IMP)suppressHook1, (IMP)suppressHook2, (IMP)suppressHook3,
    (IMP)suppressHook4, (IMP)suppressHook5, (IMP)suppressHook6, (IMP)suppressHook7,
    (IMP)suppressHook8, (IMP)suppressHook9, (IMP)suppressHook10, (IMP)suppressHook11,
    (IMP)suppressHook12, (IMP)suppressHook13, (IMP)suppressHook14, (IMP)suppressHook15,
    (IMP)suppressHook16, (IMP)suppressHook17, (IMP)suppressHook18, (IMP)suppressHook19,
    (IMP)suppressHook20, (IMP)suppressHook21, (IMP)suppressHook22, (IMP)suppressHook23,
};

static BOOL suppressHookAlreadyInstalled(Class targetClass, SEL selector) {
    for (NSUInteger index = 0; index < gSuppressHookCount; index++) {
        if (gSuppressHooks[index].targetClass == targetClass && gSuppressHooks[index].selector == selector) return YES;
    }
    return NO;
}

static Method copyOwnInstanceMethod(Class targetClass, SEL selector) {
    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(targetClass, &methodCount);
    Method result = NULL;
    for (unsigned int index = 0; index < methodCount; index++) {
        if (method_getName(methods[index]) == selector) { result = methods[index]; break; }
    }
    free(methods);
    return result;
}

static BOOL methodReturnsObjectWithoutArguments(Method method) {
    if (!method || method_getNumberOfArguments(method) != 2) return NO;
    const char *typeEncoding = method_getTypeEncoding(method);
    if (!typeEncoding) return NO;
    while (*typeEncoding && strchr("rnNoORV", *typeEncoding)) typeEncoding++;
    return *typeEncoding == '@';
}

static BOOL installSuppressHook(Class targetClass, SEL selector, SuppressHookKind kind) {
    if (!targetClass || !selector || suppressHookAlreadyInstalled(targetClass, selector)) return NO;
    Method method = copyOwnInstanceMethod(targetClass, selector);
    if (!methodReturnsObjectWithoutArguments(method)) return NO;
    if (gSuppressHookCount >= sizeof(gSuppressHooks) / sizeof(gSuppressHooks[0])) return NO;
    NSUInteger index = gSuppressHookCount++;
    gSuppressHooks[index].targetClass = targetClass;
    gSuppressHooks[index].selector = selector;
    gSuppressHooks[index].kind = kind;
    gSuppressHooks[index].original = NULL;
    MSHookMessageEx(targetClass, selector, gSuppressImplementations[index], &gSuppressHooks[index].original);
    return YES;
}

static BOOL isBatteryHealthControllerClass(Class targetClass) {
    const char *className = class_getName(targetClass);
    if (!className) return NO;
    if (cStringContainsInsensitive(className, "batteryhealth")) return YES;
    return cStringContainsInsensitive(className, "battery") &&
           cStringContainsInsensitive(className, "health") &&
           cStringContainsInsensitive(className, "controller");
}

static BOOL isWarningSpecifierFactorySelector(const char *selectorName) {
    if (!selectorName || strchr(selectorName, ':') || !cStringEndsWithInsensitive(selectorName, "specifiers")) return NO;
    if (strcasecmp(selectorName, "headerSpecifiers") == 0) return YES;
    return cStringContainsInsensitive(selectorName, "importantbattery") ||
           cStringContainsInsensitive(selectorName, "batteryservice") ||
           cStringContainsInsensitive(selectorName, "servicerecommend") ||
           cStringContainsInsensitive(selectorName, "nongenuine") ||
           cStringContainsInsensitive(selectorName, "recalibration") ||
           cStringContainsInsensitive(selectorName, "unknownheader") ||
           cStringContainsInsensitive(selectorName, "datacollectionnotice");
}

static BOOL isBatteryServiceSuggestionSelector(const char *selectorName) {
    if (!selectorName || strchr(selectorName, ':')) return NO;
    return strcasecmp(selectorName, "getBatteryServiceSuggestion") == 0 ||
           cStringContainsInsensitive(selectorName, "batteryservicesuggestion") ||
           cStringContainsInsensitive(selectorName, "servicebatterysuggestion");
}

static void installHooksForClass(Class targetClass) {
    const char *className = class_getName(targetClass);
    if (!className) return;
    BOOL batteryController = cStringContainsInsensitive(className, "battery");
    BOOL aboutController = cStringContainsInsensitive(className, "about") ||
                           cStringContainsInsensitive(className, "general") ||
                           cStringContainsInsensitive(className, "parts") ||
                           cStringContainsInsensitive(className, "warranty") ||
                           cStringContainsInsensitive(className, "deviceinfo");
    if (!batteryController && !aboutController) return;
    BOOL batteryHealthController = isBatteryHealthControllerClass(targetClass);
    if (batteryController || aboutController) {
        installSuppressHook(targetClass, sel_registerName("specifiers"), SuppressHookKindFilterSpecifiers);
    }
    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(targetClass, &methodCount);
    for (unsigned int index = 0; index < methodCount; index++) {
        Method method = methods[index];
        SEL selector = method_getName(method);
        const char *selectorName = sel_getName(selector);
        if (batteryHealthController && isWarningSpecifierFactorySelector(selectorName)) {
            installSuppressHook(targetClass, selector, SuppressHookKindEmptyArray);
        } else if (selectorName && !strchr(selectorName, ':') && cStringEndsWithInsensitive(selectorName, "specifiers")) {
            installSuppressHook(targetClass, selector, SuppressHookKindFilterSpecifiers);
        } else if (isBatteryServiceSuggestionSelector(selectorName)) {
            installSuppressHook(targetClass, selector, SuppressHookKindSuppressObject);
        }
    }
    free(methods);
}

static void installBatteryHooks(void) {
    @autoreleasepool {
        int classCount = objc_getClassList(NULL, 0);
        if (classCount <= 0) return;
        Class *classes = (Class *)calloc((size_t)classCount, sizeof(Class));
        if (!classes) return;
        int loadedClassCount = objc_getClassList(classes, classCount);
        int scanCount = loadedClassCount < classCount ? loadedClassCount : classCount;
        for (int index = 0; index < scanCount; index++) installHooksForClass(classes[index]);
        free(classes);
    }
}

// ========== 参考类 hook（BatteryUIResourceClass / SystemHealthUI / FollowUp / SBIcon） ==========
static long long (*origGenuineBatteryStatus)(id, SEL) = NULL;
static long long (*origBatteryHealthServiceState)(id, SEL) = NULL;
static id (*origBatteryServiceSuggestion)(id, SEL, id) = NULL;
static id (*origCurrentSystemHealthInfoSpecifiers)(id, SEL) = NULL;
static void (*origFollowUpAddItem)(id, SEL, id) = NULL;
static BOOL (*origAllowsBadgingForIcon)(id, SEL, id) = NULL;

static long long hookedGenuineBatteryStatus(id self, SEL selector) {
    return suppressPartRepairEnabled ? 0 : (origGenuineBatteryStatus ? origGenuineBatteryStatus(self, selector) : 0);
}

static long long hookedBatteryHealthServiceState(id self, SEL selector) {
    return suppressPartRepairEnabled ? 0 : (origBatteryHealthServiceState ? origBatteryHealthServiceState(self, selector) : 0);
}

static id hookedBatteryServiceSuggestion(id self, SEL selector, id argument) {
    return suppressPartRepairEnabled ? nil : (origBatteryServiceSuggestion ? origBatteryServiceSuggestion(self, selector, argument) : nil);
}

static id hookedCurrentSystemHealthInfoSpecifiers(id self, SEL selector) {
    return suppressPartRepairEnabled ? nil : (origCurrentSystemHealthInfoSpecifiers ? origCurrentSystemHealthInfoSpecifiers(self, selector) : nil);
}

static BOOL objectLooksLikeBatteryRepair(id object) {
    if (!object) return NO;
    if (valueContainsBatteryWarning(object)) return YES;
    static const char *selectors[] = {"applicationBundleID", "clientIdentifier", "containerPath", "title", "subtitle", "localizedTitle"};
    for (NSUInteger i = 0; i < sizeof(selectors)/sizeof(selectors[0]); i++) {
        id value = callObjectNoArgument(object, selectors[i]);
        NSString *text = inspectionStringForValue(value);
        if (stringContainsBatteryWarningToken(text)) return YES;
        if ([text isKindOfClass:[NSString class]] &&
            ([text rangeOfString:@"battery" options:NSCaseInsensitiveSearch].location != NSNotFound ||
             [text containsString:@"电池"])) return YES;
    }
    return NO;
}

static void hookedFollowUpAddItem(id self, SEL selector, id item) {
    if (suppressPartRepairEnabled && objectLooksLikeBatteryRepair(item)) return;
    if (origFollowUpAddItem) origFollowUpAddItem(self, selector, item);
}

static BOOL hookedAllowsBadgingForIcon(id self, SEL selector, id icon) {
    if (suppressPartRepairEnabled) {
        id bundleID = callObjectNoArgument(icon, "applicationBundleID");
        if ([bundleID isKindOfClass:[NSString class]] &&
            [(NSString *)bundleID isEqualToString:@"com.apple.Preferences"]) return NO;
    }
    return origAllowsBadgingForIcon ? origAllowsBadgingForIcon(self, selector, icon) : YES;
}

static void installReferenceRepairHooks(void) {
    Class resource = objc_getClass("BatteryUIResourceClass");
    Class resourceMeta = resource ? object_getClass(resource) : Nil;
    if (resourceMeta) {
        SEL genuine = sel_registerName("genuineBatteryStatus");
        SEL state = sel_registerName("getBatteryHealthServiceState");
        SEL suggestion = sel_registerName("getBatteryServiceSuggestion:");
        if (!origGenuineBatteryStatus && class_getInstanceMethod(resourceMeta, genuine)) MSHookMessageEx(resourceMeta, genuine, (IMP)hookedGenuineBatteryStatus, (IMP *)&origGenuineBatteryStatus);
        if (!origBatteryHealthServiceState && class_getInstanceMethod(resourceMeta, state)) MSHookMessageEx(resourceMeta, state, (IMP)hookedBatteryHealthServiceState, (IMP *)&origBatteryHealthServiceState);
        if (!origBatteryServiceSuggestion && class_getInstanceMethod(resourceMeta, suggestion)) MSHookMessageEx(resourceMeta, suggestion, (IMP)hookedBatteryServiceSuggestion, (IMP *)&origBatteryServiceSuggestion);
    }
    Class systemHealth = objc_getClass("SystemHealthUI");
    SEL healthSpecifiers = sel_registerName("getCurrentSystemHealthInfoSpecifiers");
    if (!origCurrentSystemHealthInfoSpecifiers && systemHealth && class_getInstanceMethod(systemHealth, healthSpecifiers))
        MSHookMessageEx(systemHealth, healthSpecifiers, (IMP)hookedCurrentSystemHealthInfoSpecifiers, (IMP *)&origCurrentSystemHealthInfoSpecifiers);
    Class followUp = objc_getClass("FLGroupViewModelImpl");
    SEL addItem = sel_registerName("addItem:");
    if (!origFollowUpAddItem && followUp && class_getInstanceMethod(followUp, addItem))
        MSHookMessageEx(followUp, addItem, (IMP)hookedFollowUpAddItem, (IMP *)&origFollowUpAddItem);
    Class iconController = objc_getClass("SBIconController");
    SEL allowsBadge = sel_registerName("allowsBadgingForIcon:");
    if (!origAllowsBadgingForIcon && iconController && class_getInstanceMethod(iconController, allowsBadge))
        MSHookMessageEx(iconController, allowsBadge, (IMP)hookedAllowsBadgingForIcon, (IMP *)&origAllowsBadgingForIcon);
}

// ========== 通知：设置变更 + bundle 加载 ==========
static void onPartRepairSettingsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    LoadPreferences();
    installSpecifierHooks();
    installBatteryHooks();
    installReferenceRepairHooks();
}

static void onPartRepairBundleDidLoad(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)userInfo;
    NSBundle *bundle = (__bridge NSBundle *)object;
    NSString *bundleIdentifier = [bundle bundleIdentifier];
    installReferenceRepairHooks();
    if (![bundleIdentifier isKindOfClass:[NSString class]]) return;
    if ([bundleIdentifier rangeOfString:@"battery" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [bundleIdentifier rangeOfString:@"powerui" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [bundleIdentifier rangeOfString:@"preferences" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        installBatteryHooks();
    }
}

// ========== 设置页列表过滤（Logos hook） ==========
%hook PSListController
- (NSArray *)specifiers {
    NSArray *result = %orig;
    return suppressPartRepairEnabled ? filteredBatteryHealthSpecifiers(result) : result;
}
- (void)setSpecifiers:(NSArray *)specifiers {
    NSArray *patched = suppressPartRepairEnabled ? filteredBatteryHealthSpecifiers(specifiers) : specifiers;
    %orig(patched);
}
%end

%hook PSTableCell
- (void)layoutSubviews {
    %orig;
    id specifier = nil;
    if ([self respondsToSelector:@selector(specifier)]) specifier = [self specifier];
    if (suppressPartRepairEnabled && specifierContainsBatteryWarning(specifier)) {
        self.tag = 0x5342;
        self.hidden = YES;
        self.contentView.hidden = YES;
        return;
    }
    if (self.tag == 0x5342) {
        self.tag = 0;
        self.hidden = NO;
        self.contentView.hidden = NO;
    }
}
%end

// Request the native crash/respring policy only; never grant authentication.
// Read at query time so the first boot-policy query sees the persisted switch,
// without saving or replaying any previous lock/authentication state.
%group SBCPUNativeRespringPolicy
%hook SBBootDefaults
- (BOOL)dontLockAfterCrash {
    CFPreferencesSynchronize(kPrefAppID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (getBoolPref(CFSTR("respringPreserveNativeUnlockEnabled"), NO)) return YES;
    return %orig;
}
%end
%end

#pragma mark - 10. 构造函数入口

%ctor {
    %init;
    // 🛡️ 屏蔽部件与维修记录：先加载偏好（确保 Preferences/BatteryUsageUI 进程首次启动开关状态正确），再注册通知 + 初始化 hooks
    LoadPreferences();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, onPartRepairSettingsChanged, kPrefChangedNotification, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(CFNotificationCenterGetLocalCenter(), NULL, onPartRepairBundleDidLoad, (__bridge CFStringRef)NSBundleDidLoadNotification, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    installSpecifierHooks();
    installBatteryHooks();
    installReferenceRepairHooks();
    NSString *processName = [NSProcessInfo processInfo].processName;
    if ([processName isEqualToString:@"SpringBoard"]) {
        Class bootDefaultsClass = NSClassFromString(@"SBBootDefaults");
        if (bootDefaultsClass && class_getInstanceMethod(bootDefaultsClass, @selector(dontLockAfterCrash))) {
            %init(SBCPUNativeRespringPolicy);
        }
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, onPluginScanRequested, CFSTR("com.sbcpu.floating.plugin-scan.request"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, onChargeHistoryClearRequested, CFSTR("com.sbcpu.floating.charge-history.clear"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        LoadPreferences();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, onCCNotificationReceived, kPrefChangedNotification, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        // 锁屏清理后台：仅由 SBLockScreenManager 的真实 lockUIFromSource* 事件触发。
        // 不注册 lockstate Darwin 通知，也不启动 isUILocked 轮询，避免下拉通知中心时误判为锁屏。
        NSLog(@"[SBCPUFloating] 锁屏清理模块已加载，开关状态=%d（仅真实锁屏事件触发）", lockCleanupEnable);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            gSBReady = YES;
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            createCPUWindow();
            registerV160Observers();
            gFloatingUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:floatingValueRefreshInterval repeats:YES block:^(NSTimer *timer) { updateCPU(); chargeSessionTick(); }];
            [[NSRunLoop mainRunLoop] addTimer:gFloatingUpdateTimer forMode:NSRunLoopCommonModes];
        });
    }
}

