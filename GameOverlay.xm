#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

// SBCPUGameOverlay V2.9.4
// 游戏内通知显示层：
// 1. 不创建新的 UIWindow，避免影响游戏横竖屏方向。
// 2. 直接挂载到游戏当前前台 UIWindow。
// 3. SpringBoard -> 共享 plist -> Darwin Notify -> 游戏进程，避免 CFMessagePort 在部分越狱环境下找不到端口。
// 4. Overlay 永不接收触摸。

static NSString * const kSBCPUGameOverlayFilePath = @"/var/tmp/com.yourname.sbcpufloating.gameoverlay.plist";
static CFStringRef const kSBCPUGameOverlayDarwinNotification = CFSTR("com.yourname.sbcpufloating.gameoverlay.message");

@class SBCPUGameOverlayManager;
static void SBCPUGameOverlayDarwinCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo);

static BOOL SBCPUGameOverlayIsAllowedProcess(void) {
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"";
    NSArray *allowed = @[
        @"com.tencent.tmgp.sgame",
        @"com.tencent.tmgp.pubgmhd",
        @"com.tencent.tmgp.speedmobile",
        @"com.tencent.tmgp.cf",
        @"com.miHoYo.GenshinImpact",
        @"com.miHoYo.hkrpg",
        @"com.miHoYo.Yuanshen",
        @"com.hypergryph.arknights",
        @"com.tencent.wzryAndroid",
        @"com.netease.wxzc"
    ];
    return [allowed containsObject:bundleID];
}

@interface SBCPUGameOverlayBanner : UIView
@property(nonatomic,strong) UIView *content;
@property(nonatomic,strong) UILabel *iconLabel;
@property(nonatomic,strong) UILabel *appLabel;
@property(nonatomic,strong) UILabel *senderLabel;
@property(nonatomic,strong) UILabel *messageLabel;
@end

@implementation SBCPUGameOverlayBanner

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.backgroundColor = UIColor.clearColor;
    self.userInteractionEnabled = NO;
    self.layer.shadowColor = UIColor.blackColor.CGColor;
    self.layer.shadowOpacity = 0.28;
    self.layer.shadowRadius = 12.0;
    self.layer.shadowOffset = CGSizeMake(0, 5);

    self.content = [[UIView alloc] initWithFrame:self.bounds];
    self.content.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.content.backgroundColor = [UIColor colorWithWhite:0.035 alpha:0.94];
    self.content.layer.cornerRadius = 27.0;
    self.content.layer.masksToBounds = YES;
    self.content.layer.borderWidth = 0.6;
    self.content.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.16].CGColor;
    [self addSubview:self.content];

    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark]];
    blur.frame = self.content.bounds;
    blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    blur.alpha = 0.45;
    blur.userInteractionEnabled = NO;
    [self.content insertSubview:blur atIndex:0];

    self.iconLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.iconLabel.textAlignment = NSTextAlignmentCenter;
    self.iconLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
    self.iconLabel.userInteractionEnabled = NO;
    [self.content addSubview:self.iconLabel];

    self.appLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.appLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    self.appLabel.textColor = [UIColor colorWithWhite:1 alpha:0.70];
    self.appLabel.userInteractionEnabled = NO;
    [self.content addSubview:self.appLabel];

    self.senderLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.senderLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    self.senderLabel.textColor = UIColor.whiteColor;
    self.senderLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.senderLabel.userInteractionEnabled = NO;
    [self.content addSubview:self.senderLabel];

    self.messageLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.messageLabel.font = [UIFont systemFontOfSize:14.5 weight:UIFontWeightMedium];
    self.messageLabel.textColor = [UIColor colorWithWhite:1 alpha:0.94];
    self.messageLabel.numberOfLines = 1;
    self.messageLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.messageLabel.userInteractionEnabled = NO;
    [self.content addSubview:self.messageLabel];

    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    self.iconLabel.frame = CGRectMake(12, 0, 34, h);
    self.appLabel.frame = CGRectMake(48, 9, 42, 16);
    self.senderLabel.frame = CGRectMake(88, 8, MAX(80, w - 100), 18);
    self.messageLabel.frame = CGRectMake(48, 29, MAX(100, w - 62), 21);
}
@end

@interface SBCPUGameOverlayManager : NSObject
@property(nonatomic,strong) UIWindow *hostWindow;
@property(nonatomic,strong) UIView *overlayView;
@property(nonatomic,strong) SBCPUGameOverlayBanner *banner;
@property(nonatomic,strong) NSMutableArray<NSDictionary *> *queue;
@property(nonatomic,strong) NSTimer *dismissTimer;
@property(nonatomic,assign) BOOL showing;
@property(nonatomic,assign) NSTimeInterval processStartTime;
@property(nonatomic,assign) BOOL observingDarwin;
@property(nonatomic,strong) NSTimer *pollTimer;
@property(nonatomic,assign) NSTimeInterval lastConsumedTimestamp;
+ (instancetype)sharedManager;
- (void)start;
@end

@implementation SBCPUGameOverlayManager

+ (instancetype)sharedManager {
    static SBCPUGameOverlayManager *manager;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ manager = [SBCPUGameOverlayManager new]; });
    return manager;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = [NSMutableArray array];
        _processStartTime = NSDate.date.timeIntervalSince1970;
        _lastConsumedTimestamp = _processStartTime;
    }
    return self;
}

- (UIWindow *)findHostWindow {
    UIApplication *app = UIApplication.sharedApplication;
    UIWindow *best = nil;
    CGFloat bestArea = 0.0;

    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            UISceneActivationState state = windowScene.activationState;
            if (state != UISceneActivationStateForegroundActive && state != UISceneActivationStateForegroundInactive) continue;

            for (UIWindow *window in windowScene.windows) {
                if (window.hidden || window.alpha <= 0.01) continue;
                CGRect r = window.bounds;
                CGFloat area = MAX(0.0, r.size.width) * MAX(0.0, r.size.height);
                if (area < 10000.0) continue;
                NSString *className = NSStringFromClass(window.class);
                if ([className containsString:@"UITextEffects"] || [className containsString:@"Keyboard"]) continue;
                if ([className containsString:@"UIRemoteKeyboard"]) continue;
                // 选择面积最大的正常游戏窗口，而不是盲目使用 keyWindow。
                if (area > bestArea) {
                    bestArea = area;
                    best = window;
                }
            }
        }
    }

    if (!best) {
        for (UIWindow *window in app.windows) {
            if (window.hidden || window.alpha <= 0.01) continue;
            CGFloat area = MAX(0.0, window.bounds.size.width) * MAX(0.0, window.bounds.size.height);
            if (area > bestArea) { bestArea = area; best = window; }
        }
    }
    return best;
}
- (void)installOverlayOnWindow:(UIWindow *)window {
    if (!window) return;
    if (self.hostWindow == window && self.overlayView.superview == window) {
        [window bringSubviewToFront:self.overlayView];
        return;
    }

    [self.overlayView removeFromSuperview];
    self.hostWindow = window;

    UIView *overlay = [[UIView alloc] initWithFrame:window.bounds];
    overlay.backgroundColor = UIColor.clearColor;
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.userInteractionEnabled = NO;
    overlay.clipsToBounds = NO;
    self.overlayView = overlay;
    overlay.layer.zPosition = 999999.0;
    [window addSubview:overlay];
    [window bringSubviewToFront:overlay];

    self.banner = [[SBCPUGameOverlayBanner alloc] initWithFrame:CGRectZero];
    self.banner.alpha = 0.0;
    self.banner.hidden = YES;
    [overlay addSubview:self.banner];
    self.banner.layer.zPosition = 1000000.0;
    [self layoutBanner];
}

- (void)layoutBanner {
    if (!self.overlayView || !self.banner) return;
    CGRect bounds = self.overlayView.bounds;
    if (bounds.size.width <= 1 || bounds.size.height <= 1) return;

    CGFloat width = MIN(430.0, MAX(280.0, bounds.size.width - 40.0));
    if (bounds.size.width < 320.0) width = bounds.size.width - 20.0;
    CGFloat height = 58.0;
    CGFloat top = self.overlayView.safeAreaInsets.top;
    // 游戏全屏时 safeArea 可能是 0；给灵动岛/刘海留出空间。
    if (top < 12.0) top = 12.0;
    CGFloat y = top + 8.0;
    self.banner.frame = CGRectMake((bounds.size.width - width) * 0.5, y, width, height);
}

- (void)installObservers {
    if (self.observingDarwin) return;
    self.observingDarwin = YES;

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    (__bridge const void *)(self),
                                    SBCPUGameOverlayDarwinCallback,
                                    kSBCPUGameOverlayDarwinNotification,
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidBecomeActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(windowDidBecomeKey:) name:UIWindowDidBecomeKeyNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(windowDidBecomeKey:) name:UIDeviceOrientationDidChangeNotification object:nil];

    // Darwin 通知在部分 RootHide/游戏进程组合下可能丢失，因此增加轻量轮询兜底。
    // 共享路径与 SpringBoard 发送端统一使用 /var/tmp，确保跨进程读取的是同一份 payload。
    [self.pollTimer invalidate];
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:0.35 target:self selector:@selector(pollSharedPayload) userInfo:nil repeats:YES];
}

static void SBCPUGameOverlayDarwinCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    (void)center; (void)name; (void)object; (void)userInfo;
    SBCPUGameOverlayManager *manager = (__bridge SBCPUGameOverlayManager *)observer;
    if (!manager) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [manager readSharedPayloadAndShow];
    });
}

- (void)applicationDidBecomeActive:(NSNotification *)note {
    (void)note;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self ensureHostWindow];
    });
}

- (void)windowDidBecomeKey:(NSNotification *)note {
    UIWindow *window = note.object;
    if (!window) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (window.windowScene.activationState == UISceneActivationStateForegroundActive) {
            [self installOverlayOnWindow:window];
        }
    });
}

- (void)ensureHostWindow {
    UIWindow *window = [self findHostWindow];
    if (window) {
        [self installOverlayOnWindow:window];
        [self.hostWindow bringSubviewToFront:self.overlayView];
        [self layoutBanner];
    }
}

- (void)pollSharedPayload {
    [self readSharedPayloadAndShow];
}

- (void)readSharedPayloadAndShow {
    NSDictionary *payload = [NSDictionary dictionaryWithContentsOfFile:kSBCPUGameOverlayFilePath];
    if (![payload isKindOfClass:NSDictionary.class]) return;

    NSNumber *timestamp = payload[@"timestamp"];
    if (![timestamp isKindOfClass:NSNumber.class]) return;
    double ts = timestamp.doubleValue;
    // 忽略游戏启动前已经存在的旧消息，并避免轮询重复加入同一条消息。
    if (ts + 0.15 < self.processStartTime) return;
    if (ts <= self.lastConsumedTimestamp + 0.001) return;
    self.lastConsumedTimestamp = ts;

    [self ensureHostWindow];
    [self.queue addObject:payload];
    if (!self.showing) [self showNext];
}

- (void)showNext {
    if (self.queue.count == 0) return;
    if (!self.overlayView || !self.banner) {
        [self ensureHostWindow];
        if (!self.overlayView || !self.banner) return;
    }

    NSDictionary *payload = self.queue.firstObject;
    [self.queue removeObjectAtIndex:0];

    NSString *bundleID = [payload[@"bundleID"] isKindOfClass:NSString.class] ? payload[@"bundleID"] : @"";
    NSString *title = [payload[@"title"] isKindOfClass:NSString.class] ? payload[@"title"] : @"新消息";
    NSString *message = [payload[@"message"] isKindOfClass:NSString.class] ? payload[@"message"] : @"收到一条新消息";

    NSString *appName = @"通知";
    NSString *icon = @"●";
    UIColor *iconColor = [UIColor systemBlueColor];
    if ([bundleID isEqualToString:@"com.tencent.xin"]) {
        appName = @"微信"; icon = @"●"; iconColor = [UIColor systemGreenColor];
    } else if ([bundleID.lowercaseString containsString:@"qq"]) {
        appName = @"QQ"; icon = @"◆"; iconColor = [UIColor systemBlueColor];
    } else if ([bundleID isEqualToString:@"com.tencent.tim"]) {
        appName = @"TIM"; icon = @"◆"; iconColor = [UIColor colorWithRed:0.15 green:0.55 blue:1 alpha:1];
    }

    self.banner.iconLabel.text = icon;
    self.banner.iconLabel.textColor = iconColor;
    self.banner.appLabel.text = appName;
    self.banner.senderLabel.text = title.length ? title : @"新消息";
    self.banner.messageLabel.text = message.length ? message : @"收到一条新消息";
    [self.banner setNeedsLayout];
    [self layoutBanner];

    self.showing = YES;
    self.banner.hidden = NO;
    self.banner.alpha = 0.0;
    CGRect finalFrame = self.banner.frame;
    CGRect startFrame = finalFrame;
    startFrame.origin.y -= 18.0;
    self.banner.frame = startFrame;

    [UIView animateWithDuration:0.28 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.banner.alpha = 1.0;
        self.banner.frame = finalFrame;
    } completion:^(BOOL finished) {
        if (!finished) return;
        [self.dismissTimer invalidate];
        self.dismissTimer = [NSTimer scheduledTimerWithTimeInterval:3.2 target:self selector:@selector(dismissCurrent) userInfo:nil repeats:NO];
    }];
}

- (void)dismissCurrent {
    [self.dismissTimer invalidate];
    self.dismissTimer = nil;
    if (!self.banner) return;

    CGRect endFrame = self.banner.frame;
    endFrame.origin.y -= 16.0;
    [UIView animateWithDuration:0.24 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
        self.banner.alpha = 0.0;
        self.banner.frame = endFrame;
    } completion:^(BOOL finished) {
        self.banner.hidden = YES;
        self.showing = NO;
        [self layoutBanner];
        if (self.queue.count) [self showNext];
    }];
}

- (void)start {
    if (!SBCPUGameOverlayIsAllowedProcess()) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self installObservers];
        [self ensureHostWindow];
    });
}

- (void)dealloc {
    if (_observingDarwin) {
        CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge const void *)(self), kSBCPUGameOverlayDarwinNotification, NULL);
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_dismissTimer invalidate];
    [_pollTimer invalidate];
}
@end

%ctor {
    NSString *process = NSProcessInfo.processInfo.processName ?: @"";
    if ([process isEqualToString:@"SpringBoard"] || [process isEqualToString:@"backboardd"] || [process isEqualToString:@"thermalmonitord"] || [process isEqualToString:@"powerd"]) return;
    if (!SBCPUGameOverlayIsAllowedProcess()) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        [[SBCPUGameOverlayManager sharedManager] start];
    });
}
