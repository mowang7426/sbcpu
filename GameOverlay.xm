#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <notify.h>

static UIWindow *SBCPUGameOverlayWindow = nil;
static UIView *SBCPUGamePill = nil;
static UILabel *SBCPUGameIcon = nil;
static UILabel *SBCPUGameApp = nil;
static UILabel *SBCPUGameCount = nil;
static NSUInteger SBCPUGameGeneration = 0;
static NSInteger SBCPUGameUnreadCount = 0;
static BOOL SBCPUGameVisible = NO;

static NSString * const kGameBannerPath = @"/var/mobile/Library/Preferences/com.yourname.sbcpufloating.gamebanner.plist";
static const char *kGameBannerNotify = "com.yourname.sbcpufloating.gamebanner";

@interface SBCPUGameOverlayRoot : UIViewController
@end

@implementation SBCPUGameOverlayRoot
- (void)loadView {
    UIView *v = [[UIView alloc] initWithFrame:CGRectZero];
    v.backgroundColor = UIColor.clearColor;
    v.userInteractionEnabled = NO;
    self.view = v;
}
- (BOOL)shouldAutorotate { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }
- (BOOL)prefersStatusBarHidden { return YES; }
@end

@interface SBCPUGamePassthroughWindow : UIWindow
@end

@implementation SBCPUGamePassthroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    // The overlay is display-only. Never consume game touches.
    return nil;
}
@end

static UIWindowScene *SBCPUCurrentGameScene(void) {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            if (ws.activationState == UISceneActivationStateForegroundActive ||
                ws.activationState == UISceneActivationStateForegroundInactive) {
                return ws;
            }
        }
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) return (UIWindowScene *)scene;
        }
    }
    return nil;
}

static void SBCPUApplyGamePillLayout(void) {
    if (!SBCPUGameOverlayWindow || !SBCPUGamePill) return;

    CGRect b = SBCPUGameOverlayWindow.bounds;
    if (b.size.width < 100 || b.size.height < 100) return;

    BOOL landscape = b.size.width > b.size.height;
    CGFloat width = landscape ? 76.0 : MIN(390.0, b.size.width - 24.0);
    CGFloat height = landscape ? MIN(620.0, MAX(360.0, b.size.height - 90.0)) : 60.0;
    CGFloat x = landscape ? 8.0 : (b.size.width - width) * 0.5;
    CGFloat y = landscape ? (b.size.height - height) * 0.5 : 14.0;

    SBCPUGamePill.frame = CGRectMake(x, y, width, height);
    SBCPUGamePill.layer.cornerRadius = width * 0.5;

    if (landscape) {
        // Vertical side capsule, matching the reference: icon -> app name -> count.
        SBCPUGameIcon.transform = CGAffineTransformMakeRotation(-M_PI_2);
        SBCPUGameApp.transform = CGAffineTransformMakeRotation(-M_PI_2);
        SBCPUGameCount.transform = CGAffineTransformMakeRotation(-M_PI_2);

        SBCPUGameIcon.bounds = CGRectMake(0, 0, 30, 30);
        SBCPUGameIcon.center = CGPointMake(width * 0.5, 48.0);

        SBCPUGameApp.bounds = CGRectMake(0, 0, MIN(300.0, height - 120.0), 20.0);
        SBCPUGameApp.center = CGPointMake(width * 0.5, height * 0.5);

        SBCPUGameCount.bounds = CGRectMake(0, 0, 38, 28);
        SBCPUGameCount.center = CGPointMake(width * 0.5, height - 58.0);
    } else {
        SBCPUGameIcon.transform = CGAffineTransformIdentity;
        SBCPUGameApp.transform = CGAffineTransformIdentity;
        SBCPUGameCount.transform = CGAffineTransformIdentity;

        SBCPUGameIcon.frame = CGRectMake(14, 15, 28, 28);
        SBCPUGameApp.frame = CGRectMake(48, 12, width - 90, 22);
        SBCPUGameCount.frame = CGRectMake(width - 40, 13, 26, 26);
    }
}

static void SBCPUEnsureGameOverlay(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindowScene *scene = SBCPUCurrentGameScene();
        if (!scene) return;

        if (!SBCPUGameOverlayWindow) {
            SBCPUGameOverlayWindow = [[SBCPUGamePassthroughWindow alloc] initWithWindowScene:scene];
            SBCPUGameOverlayWindow.backgroundColor = UIColor.clearColor;
            SBCPUGameOverlayWindow.opaque = NO;
            SBCPUGameOverlayWindow.windowLevel = UIWindowLevelAlert + 100.0;
            SBCPUGameOverlayWindow.rootViewController = [[SBCPUGameOverlayRoot alloc] init];
            SBCPUGameOverlayWindow.hidden = NO;

            SBCPUGamePill = [[UIView alloc] initWithFrame:CGRectZero];
            SBCPUGamePill.backgroundColor = [UIColor colorWithWhite:0.01 alpha:0.96];
            SBCPUGamePill.layer.masksToBounds = YES;
            SBCPUGamePill.userInteractionEnabled = NO;
            [SBCPUGameOverlayWindow.rootViewController.view addSubview:SBCPUGamePill];

            SBCPUGameIcon = [[UILabel alloc] initWithFrame:CGRectZero];
            SBCPUGameIcon.textAlignment = NSTextAlignmentCenter;
            SBCPUGameIcon.font = [UIFont systemFontOfSize:19 weight:UIFontWeightBold];
            SBCPUGameIcon.userInteractionEnabled = NO;
            [SBCPUGamePill addSubview:SBCPUGameIcon];

            SBCPUGameApp = [[UILabel alloc] initWithFrame:CGRectZero];
            SBCPUGameApp.textAlignment = NSTextAlignmentCenter;
            SBCPUGameApp.textColor = [UIColor colorWithWhite:1 alpha:0.90];
            SBCPUGameApp.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
            SBCPUGameApp.numberOfLines = 1;
            SBCPUGameApp.lineBreakMode = NSLineBreakByTruncatingTail;
            SBCPUGameApp.userInteractionEnabled = NO;
            [SBCPUGamePill addSubview:SBCPUGameApp];

            SBCPUGameCount = [[UILabel alloc] initWithFrame:CGRectZero];
            SBCPUGameCount.textAlignment = NSTextAlignmentCenter;
            SBCPUGameCount.textColor = UIColor.whiteColor;
            SBCPUGameCount.font = [UIFont systemFontOfSize:21 weight:UIFontWeightBold];
            SBCPUGameCount.userInteractionEnabled = NO;
            [SBCPUGamePill addSubview:SBCPUGameCount];
        } else if (SBCPUGameOverlayWindow.windowScene != scene) {
            SBCPUGameOverlayWindow.windowScene = scene;
        }

        SBCPUApplyGamePillLayout();
    });
}

static void SBCPUHideGamePillAnimated(void) {
    if (!SBCPUGamePill || !SBCPUGameVisible) return;
    SBCPUGameVisible = NO;
    NSUInteger generation = ++SBCPUGameGeneration;
    BOOL landscape = SBCPUGameOverlayWindow.bounds.size.width > SBCPUGameOverlayWindow.bounds.size.height;
    CGAffineTransform out = landscape ? CGAffineTransformMakeTranslation(-95.0, 0) : CGAffineTransformMakeTranslation(0, -72.0);
    [UIView animateWithDuration:0.30 animations:^{
        SBCPUGamePill.alpha = 0.0;
        SBCPUGamePill.transform = out;
    } completion:^(BOOL finished) {
        (void)finished;
        if (generation == SBCPUGameGeneration) {
            SBCPUGamePill.hidden = YES;
            SBCPUGamePill.transform = CGAffineTransformIdentity;
        }
    }];
}

static void SBCPUShowGamePillFromDictionary(NSDictionary *data) {
    if (![data isKindOfClass:[NSDictionary class]]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        SBCPUEnsureGameOverlay();
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!SBCPUGamePill || !SBCPUGameOverlayWindow) return;

            NSString *bundle = [data[@"bundleID"] isKindOfClass:[NSString class]] ? data[@"bundleID"] : @"";
            NSString *title = [data[@"title"] isKindOfClass:[NSString class]] ? data[@"title"] : @"新消息";
            NSNumber *count = [data[@"count"] isKindOfClass:[NSNumber class]] ? data[@"count"] : @1;

            NSString *app = @"消息";
            NSString *icon = @"◆";
            UIColor *iconColor = UIColor.whiteColor;
            if ([bundle isEqualToString:@"com.tencent.xin"]) { app = @"微信"; icon = @"●"; iconColor = UIColor.systemGreenColor; }
            else if ([bundle.lowercaseString containsString:@"qq"]) { app = @"QQ"; icon = @"◆"; iconColor = UIColor.systemBlueColor; }
            else if ([bundle isEqualToString:@"com.tencent.tim"]) { app = @"TIM"; icon = @"◆"; iconColor = [UIColor colorWithRed:0.15 green:0.55 blue:1 alpha:1]; }

            SBCPUGameIcon.text = icon;
            SBCPUGameIcon.textColor = iconColor;
            SBCPUGameApp.text = [NSString stringWithFormat:@"%@ · %@", app, title.length ? title : @"新消息"];
            SBCPUGameCount.text = [NSString stringWithFormat:@"%@", count];

            SBCPUApplyGamePillLayout();
            BOOL landscape = SBCPUGameOverlayWindow.bounds.size.width > SBCPUGameOverlayWindow.bounds.size.height;
            SBCPUGamePill.hidden = NO;
            SBCPUGamePill.alpha = 0.0;
            SBCPUGamePill.transform = landscape ? CGAffineTransformMakeTranslation(-95.0, 0) : CGAffineTransformMakeTranslation(0, -72.0);
            SBCPUGameVisible = YES;
            NSUInteger generation = ++SBCPUGameGeneration;
            [UIView animateWithDuration:0.32 delay:0 options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState animations:^{
                SBCPUGamePill.alpha = 1.0;
                SBCPUGamePill.transform = CGAffineTransformIdentity;
            } completion:nil];

            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (generation == SBCPUGameGeneration) SBCPUHideGamePillAnimated();
            });
        });
    });
}

static void SBCPUReadAndShowGameBanner(void) {
    NSDictionary *data = [NSDictionary dictionaryWithContentsOfFile:kGameBannerPath];
    if (data) SBCPUShowGamePillFromDictionary(data);
}

static void SBCPURegisterGameBannerNotification(void) {
    static int token = 0;
    notify_register_dispatch(kGameBannerNotify, &token, dispatch_get_main_queue(), ^(int t) {
        (void)t;
        SBCPUReadAndShowGameBanner();
    });
}

__attribute__((constructor)) static void SBCPUGameOverlayInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Do not create an overlay for the SpringBoard process itself.
        NSString *bundle = NSBundle.mainBundle.bundleIdentifier ?: @"";
        if ([bundle isEqualToString:@"com.apple.springboard"]) return;

        SBCPURegisterGameBannerNotification();
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            (void)note;
            SBCPUEnsureGameOverlay();
        }];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIDeviceOrientationDidChangeNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            (void)note;
            SBCPUApplyGamePillLayout();
        }];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            SBCPUEnsureGameOverlay();
            SBCPUReadAndShowGameBanner();
        });
    });
}
