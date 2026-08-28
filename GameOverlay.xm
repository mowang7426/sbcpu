#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

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
    [self.content addSubview:self.iconLabel];

    self.appLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.appLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    self.appLabel.textColor = [UIColor colorWithWhite:1 alpha:0.88];
    [self.content addSubview:self.appLabel];

    self.senderLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.senderLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    self.senderLabel.textColor = UIColor.whiteColor;
    [self.content addSubview:self.senderLabel];

    self.messageLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.messageLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    self.messageLabel.textColor = UIColor.whiteColor;
    self.messageLabel.numberOfLines = 1;
    self.messageLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.content addSubview:self.messageLabel];

    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat h = self.bounds.size.height;
    self.iconLabel.frame = CGRectMake(9, 0, 34, h);
    self.appLabel.frame = CGRectMake(45, 8, 70, 17);
    self.senderLabel.frame = CGRectMake(112, 7, 150, 18);
    self.messageLabel.frame = CGRectMake(45, 27, self.bounds.size.width - 58, 25);
}

@end

@interface SBCPUGameOverlayController : UIViewController
@property(nonatomic,strong) SBCPUGameOverlayBanner *banner;
@property(nonatomic,strong) NSTimer *dismissTimer;
@property(nonatomic,strong) NSMutableArray<NSDictionary *> *queue;
@property(nonatomic,assign) BOOL portReady;
@end

@implementation SBCPUGameOverlayController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    self.view.userInteractionEnabled = NO;
    self.queue = [NSMutableArray array];
    [self installBanner];
}

- (void)installBanner {
    [self.banner removeFromSuperview];
    CGFloat width = MIN(UIScreen.mainScreen.bounds.size.width - 28.0, 520.0);
    self.banner = [[SBCPUGameOverlayBanner alloc] initWithFrame:CGRectMake(14, 18, width, 62)];
    self.banner.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.banner.alpha = 0.0;
    [self.view addSubview:self.banner];
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

    CGFloat screenW = UIScreen.mainScreen.bounds.size.width;
    CGFloat bannerW = self.banner.bounds.size.width;
    self.banner.center = CGPointMake(screenW + bannerW * 0.5 + 12, self.banner.center.y);
    self.banner.alpha = 0.0;
    self.banner.animating = YES;

    [UIView animateWithDuration:0.42 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.banner.alpha = 1.0;
        self.banner.center = CGPointMake(screenW * 0.5, self.banner.center.y);
    } completion:^(BOOL finished) {
        if (!finished) return;
        self.dismissTimer = [NSTimer scheduledTimerWithTimeInterval:2.6 target:self selector:@selector(dismissCurrent) userInfo:nil repeats:NO];
    }];
}

- (void)dismissCurrent {
    [self.dismissTimer invalidate];
    self.dismissTimer = nil;
    CGFloat bannerW = self.banner.bounds.size.width;
    [UIView animateWithDuration:0.38 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
        self.banner.alpha = 0.0;
        self.banner.center = CGPointMake(-bannerW * 0.5 - 12, self.banner.center.y);
    } completion:^(BOOL finished) {
        self.banner.animating = NO;
        if (self.queue.count) {
            [self showNext];
        }
    }];
}

- (void)handleIncomingData:(NSData *)data {
    if (!data.length) return;
    NSError *error = nil;
    NSDictionary *payload = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:&error];
    if (error || ![payload isKindOfClass:NSDictionary.class]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self showPayload:payload];
    });
}

- (void)updateForOrientation {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self installBanner];
    });
}
@end

static CFDataRef SBCPUGameOverlayMessageCallback(CFMessagePortRef local, SInt32 msgid, CFDataRef data, void *info) {
    (void)local; (void)msgid;
    SBCPUGameOverlayController *controller = (__bridge SBCPUGameOverlayController *)info;
    if (data) {
        NSData *nsData = (__bridge NSData *)data;
        [controller handleIncomingData:nsData];
    }
    return NULL;
}

@interface SBCPUGameOverlayManager : NSObject
@property(nonatomic,strong) UIWindow *window;
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

- (void)start {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.window) return;

        self.controller = [SBCPUGameOverlayController new];
        self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        self.window.rootViewController = self.controller;
        self.window.backgroundColor = UIColor.clearColor;
        self.window.windowLevel = UIWindowLevelAlert + 20.0;
        self.window.userInteractionEnabled = NO;
        self.window.hidden = NO;

        // iOS 13+：把 Overlay 绑定到当前游戏的 UIWindowScene，避免“窗口创建了但不显示”。
        if (@available(iOS 13.0, *)) {
            UIWindowScene *scene = nil;
            for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes) {
                if (candidate.activationState == UISceneActivationStateForegroundActive && [candidate isKindOfClass:UIWindowScene.class]) {
                    scene = (UIWindowScene *)candidate;
                    break;
                }
            }
            if (!scene) {
                for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes) {
                    if ([candidate isKindOfClass:UIWindowScene.class]) {
                        scene = (UIWindowScene *)candidate;
                        break;
                    }
                }
            }
            if (scene) self.window.windowScene = scene;
        }

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

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(orientationChanged:) name:UIDeviceOrientationDidChangeNotification object:nil];
    });
}

- (void)orientationChanged:(NSNotification *)note {
    (void)note;
    [self.controller updateForOrientation];
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
