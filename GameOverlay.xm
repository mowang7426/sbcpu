#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>

// GameOverlay V2.9.1 Fixed4
// 关键修复：不再创建独立 UIWindow。
// 独立 UIWindow 在部分横屏游戏中会参与界面方向决策，可能导致游戏画面整体旋转/缩放异常。
// 现在直接把透明 Overlay View 挂到游戏自己的前台 UIWindow 上，不参与方向控制。

static CFStringRef const kSBCPUGameOverlayPortName = CFSTR("com.yourname.sbcpufloating.gameoverlay.port");

@interface SBCPUGameOverlayBanner : UIView
@property(nonatomic,strong) UILabel *iconLabel;
@property(nonatomic,strong) UILabel *appLabel;
@property(nonatomic,strong) UILabel *senderLabel;
@property(nonatomic,strong) UILabel *messageLabel;
@property(nonatomic,strong) UIView *content;
@property(nonatomic,assign) BOOL animating;
@end

@implementation SBCPUGameOverlayBanner

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.backgroundColor = UIColor.clearColor;
    self.userInteractionEnabled = NO;

    self.content = [[UIView alloc] initWithFrame:self.bounds];
    self.content.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.content.backgroundColor = [UIColor colorWithWhite:0.06 alpha:0.84];
    self.content.layer.cornerRadius = 22.0;
    self.content.layer.masksToBounds = YES;
    self.content.layer.borderWidth = 0.7;
    self.content.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;
    [self addSubview:self.content];

    UIBlurEffect *effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark];
    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:effect];
    blur.frame = self.content.bounds;
    blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    blur.alpha = 0.55;
    blur.userInteractionEnabled = NO;
    [self.content insertSubview:blur atIndex:0];

    self.iconLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.iconLabel.text = @"●";
    self.iconLabel.textAlignment = NSTextAlignmentCenter;
    self.iconLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    self.iconLabel.textColor = [UIColor systemGreenColor];
    self.iconLabel.userInteractionEnabled = NO;
    [self.content addSubview:self.iconLabel];

    self.appLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.appLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    self.appLabel.textColor = [UIColor colorWithWhite:1 alpha:0.88];
    self.appLabel.userInteractionEnabled = NO;
    [self.content addSubview:self.appLabel];

    self.senderLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.senderLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    self.senderLabel.textColor = UIColor.whiteColor;
    self.senderLabel.userInteractionEnabled = NO;
    [self.content addSubview:self.senderLabel];

    self.messageLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.messageLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    self.messageLabel.textColor = UIColor.whiteColor;
    self.messageLabel.numberOfLines = 1;
    self.messageLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.messageLabel.userInteractionEnabled = NO;
    [self.content addSubview:self.messageLabel];

    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat h = self.bounds.size.height;
    CGFloat w = self.bounds.size.width;
    self.iconLabel.frame = CGRectMake(8, 0, 32, h);
    self.appLabel.frame = CGRectMake(42, 7, MIN(70.0, w - 50.0), 17);
    self.senderLabel.frame = CGRectMake(110, 7, MAX(60.0, w - 122.0), 18);
    self.messageLabel.frame = CGRectMake(42, 28, MAX(80.0, w - 54.0), 23);
}
@end

@interface SBCPUGameOverlayController : UIViewController
@property(nonatomic,strong) SBCPUGameOverlayBanner *banner;
@property(nonatomic,strong) NSTimer *dismissTimer;
@property(nonatomic,strong) NSMutableArray<NSDictionary *> *queue;
@end

@implementation SBCPUGameOverlayController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    self.view.userInteractionEnabled = NO;
    self.queue = [NSMutableArray array];
    [self installBanner];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutBannerPreservingVisibility:NO];
}

- (void)layoutBannerPreservingVisibility:(BOOL)resetPosition {
    if (!self.banner) return;
    CGRect bounds = self.view.bounds;
    CGFloat safeTop = self.view.safeAreaInsets.top;
    if (safeTop < 8.0) safeTop = 8.0;

    CGFloat width = MIN(MAX(260.0, bounds.size.width - 28.0), 520.0);
    CGFloat height = 62.0;
    CGFloat x = MAX(14.0, (bounds.size.width - width) * 0.5);
    CGFloat y = safeTop + 4.0;

    if (bounds.size.width < 280.0) {
        width = MAX(220.0, bounds.size.width - 20.0);
        x = (bounds.size.width - width) * 0.5;
    }

    CGRect target = CGRectMake(x, y, width, height);
    self.banner.bounds = CGRectMake(0, 0, width, height);
    if (resetPosition || self.banner.alpha <= 0.01) {
        self.banner.center = CGPointMake(CGRectGetMidX(target), CGRectGetMidY(target));
    } else {
        CGPoint oldCenter = self.banner.center;
        self.banner.center = CGPointMake(CGRectGetMidX(target), oldCenter.y);
        if (fabs(oldCenter.y - CGRectGetMidY(target)) > 80.0) {
            self.banner.center = CGPointMake(CGRectGetMidX(target), CGRectGetMidY(target));
        }
    }
}

- (void)installBanner {
    [self.banner removeFromSuperview];
    self.banner = [[SBCPUGameOverlayBanner alloc] initWithFrame:CGRectMake(0, 0, 280, 62)];
    self.banner.autoresizingMask = UIViewAutoresizingNone;
    self.banner.alpha = 0.0;
    [self.view addSubview:self.banner];
    [self layoutBannerPreservingVisibility:YES];
}

- (void)showPayload:(NSDictionary *)payload {
    if (![payload isKindOfClass:NSDictionary.class]) return;
    [self.queue addObject:payload];
    if (self.dismissTimer || self.banner.animating) return;
    [self showNext];
}

- (void)showNext {
    if (self.queue.count == 0) return;
    NSDictionary *p = self.queue.firstObject;
    [self.queue removeObjectAtIndex:0];

    NSString *bundleID = [p[@"bundleID"] isKindOfClass:NSString.class] ? p[@"bundleID"] : @"";
    NSString *title = [p[@"title"] isKindOfClass:NSString.class] ? p[@"title"] : @"新消息";
    NSString *message = [p[@"message"] isKindOfClass:NSString.class] ? p[@"message"] : @"收到一条新消息";

    NSString *app = @"通知";
    NSString *icon = @"●";
    UIColor *iconColor = [UIColor systemGreenColor];
    if ([bundleID isEqualToString:@"com.tencent.xin"]) {
        app = @"微信"; icon = @"●"; iconColor = [UIColor systemGreenColor];
    } else if ([bundleID.lowercaseString containsString:@"qq"]) {
        app = @"QQ"; icon = @"◆"; iconColor = [UIColor systemBlueColor];
    } else if ([bundleID isEqualToString:@"com.tencent.tim"]) {
        app = @"TIM"; icon = @"◆"; iconColor = [UIColor colorWithRed:0.15 green:0.55 blue:1 alpha:1];
    }

    self.banner.iconLabel.text = icon;
    self.banner.iconLabel.textColor = iconColor;
    self.banner.appLabel.text = app;
    self.banner.senderLabel.text = title.length ? title : @"新消息";
    self.banner.messageLabel.text = message.length ? message : @"收到一条新消息";
    [self.banner setNeedsLayout];

    [self layoutBannerPreservingVisibility:YES];

    CGFloat viewW = self.view.bounds.size.width;
    CGFloat bannerW = self.banner.bounds.size.width;
    CGFloat centerY = self.banner.center.y;
    self.banner.center = CGPointMake(viewW + bannerW * 0.5 + 12.0, centerY);
    self.banner.alpha = 0.0;
    self.banner.animating = YES;

    [UIView animateWithDuration:0.42 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.banner.alpha = 1.0;
        self.banner.center = CGPointMake(viewW * 0.5, centerY);
    } completion:^(BOOL finished) {
        if (!finished) {
            self.banner.animating = NO;
            return;
        }
        self.dismissTimer = [NSTimer scheduledTimerWithTimeInterval:2.6 target:self selector:@selector(dismissCurrent) userInfo:nil repeats:NO];
    }];
}

- (void)dismissCurrent {
    [self.dismissTimer invalidate];
    self.dismissTimer = nil;
    CGFloat bannerW = self.banner.bounds.size.width;
    [UIView animateWithDuration:0.38 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
        self.banner.alpha = 0.0;
        self.banner.center = CGPointMake(-bannerW * 0.5 - 12.0, self.banner.center.y);
    } completion:^(BOOL finished) {
        self.banner.animating = NO;
        if (self.queue.count) [self showNext];
    }];
}

- (void)handleIncomingData:(NSData *)data {
    if (!data.length) return;
    NSDictionary *payload = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:nil];
    if (![payload isKindOfClass:NSDictionary.class]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self showPayload:payload];
    });
}
@end

static CFDataRef SBCPUGameOverlayMessageCallback(CFMessagePortRef local, SInt32 msgid, CFDataRef data, void *info) {
    (void)local; (void)msgid;
    SBCPUGameOverlayController *controller = (__bridge SBCPUGameOverlayController *)info;
    if (data && controller) {
        [controller handleIncomingData:(__bridge NSData *)data];
    }
    return NULL;
}

@interface SBCPUGameOverlayManager : NSObject
@property(nonatomic,strong) UIWindow *hostWindow;
@property(nonatomic,strong) SBCPUGameOverlayController *controller;
@property(nonatomic,assign) CFMessagePortRef localPort;
+ (instancetype)sharedManager;
- (void)start;
@end

@implementation SBCPUGameOverlayManager

+ (instancetype)sharedManager {
    static SBCPUGameOverlayManager *m;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ m = [SBCPUGameOverlayManager new]; });
    return m;
}

- (UIWindow *)findHostWindow {
    UIApplication *app = UIApplication.sharedApplication;

    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            if (ws.activationState != UISceneActivationStateForegroundActive) continue;
            for (UIWindow *w in ws.windows) {
                if (w.hidden || w.alpha <= 0.01 || w.bounds.size.width <= 0 || w.bounds.size.height <= 0) continue;
                if (w.isKeyWindow) return w;
            }
            for (UIWindow *w in ws.windows) {
                if (!w.hidden && w.alpha > 0.01 && w.bounds.size.width > 0 && w.bounds.size.height > 0) return w;
            }
        }
    }

    for (UIWindow *w in app.windows) {
        if (w.isKeyWindow && !w.hidden && w.alpha > 0.01) return w;
    }
    for (UIWindow *w in app.windows) {
        if (!w.hidden && w.alpha > 0.01 && w.bounds.size.width > 0 && w.bounds.size.height > 0) return w;
    }
    return nil;
}

- (void)start {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.controller && self.hostWindow) return;

        UIWindow *host = [self findHostWindow];
        if (!host) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self start];
            });
            return;
        }

        self.hostWindow = host;
        self.controller = [SBCPUGameOverlayController new];
        UIView *overlayView = self.controller.view;
        overlayView.frame = host.bounds;
        overlayView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        overlayView.userInteractionEnabled = NO;

        // 直接挂到游戏自己的 UIWindow：不创建新 UIWindow，不改变游戏方向、不参与方向决策。
        [host addSubview:overlayView];
        [host bringSubviewToFront:overlayView];

        if (!self.localPort) {
            CFMessagePortContext ctx = {0, (__bridge void *)self.controller, NULL, NULL, NULL};
            Boolean shouldFree = false;
            self.localPort = CFMessagePortCreateLocal(kCFAllocatorDefault, kSBCPUGameOverlayPortName, SBCPUGameOverlayMessageCallback, &ctx, &shouldFree);
            if (self.localPort) {
                CFRunLoopSourceRef source = CFMessagePortCreateRunLoopSource(kCFAllocatorDefault, self.localPort, 0);
                if (source) {
                    CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
                    CFRelease(source);
                }
            }
        }

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(windowDidLayout:) name:UIWindowDidBecomeKeyNotification object:nil];
    });
}

- (void)windowDidLayout:(NSNotification *)note {
    UIWindow *w = note.object;
    if (w == self.hostWindow) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.controller.view.frame = self.hostWindow.bounds;
            [self.controller.view setNeedsLayout];
            [self.hostWindow bringSubviewToFront:self.controller.view];
        });
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (_localPort) CFRelease(_localPort);
}
@end

%ctor {
    NSString *process = [NSProcessInfo processInfo].processName ?: @"";
    if ([process isEqualToString:@"SpringBoard"] || [process isEqualToString:@"backboardd"] || [process isEqualToString:@"thermalmonitord"] || [process isEqualToString:@"powerd"]) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        [[SBCPUGameOverlayManager sharedManager] start];
    });
}
