#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <notify.h>

// ============================================================
// SBCPUGameOverlay V2.9.5.8
// 真正挂到游戏自己的 UIWindow 上，跟随游戏 UI 一起旋转。
// 不再创建独立 UIWindow，避免 iOS 17 + 系统竖屏锁定时出现
// “黑色横向大胶囊 / 文字倒置 / 横屏尺寸仍按竖屏计算”的问题。
// ============================================================

static UIView *SBCPUGamePill = nil;
static UILabel *SBCPUGameIcon = nil;
static UILabel *SBCPUGameApp = nil;
static UILabel *SBCPUGameCount = nil;
static UIWindow *SBCPUGameHostWindow = nil;
static NSUInteger SBCPUGameGeneration = 0;
static BOOL SBCPUGameVisible = NO;

static NSString * const kGameBannerPath = @"/var/mobile/Library/Preferences/com.yourname.sbcpufloating.gamebanner.plist";
static const char *kGameBannerNotify = "com.yourname.sbcpufloating.gamebanner";

static UIWindow *SBCPUFindGameHostWindow(void) {
    UIApplication *app = UIApplication.sharedApplication;
    UIWindow *candidate = nil;

    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            if (ws.activationState != UISceneActivationStateForegroundActive &&
                ws.activationState != UISceneActivationStateForegroundInactive) continue;

            // 优先真正的 key window。
            for (UIWindow *w in ws.windows) {
                if (!w.hidden && w.alpha > 0.01 && w.isKeyWindow && w.windowLevel == UIWindowLevelNormal) {
                    return w;
                }
            }
            // 再找正常级别、可见且面积最大的游戏窗口。
            for (UIWindow *w in ws.windows) {
                if (w.hidden || w.alpha <= 0.01) continue;
                if (w.windowLevel != UIWindowLevelNormal) continue;
                if (!candidate || (w.bounds.size.width * w.bounds.size.height > candidate.bounds.size.width * candidate.bounds.size.height)) {
                    candidate = w;
                }
            }
        }
    }

    if (!candidate) {
        for (UIWindow *w in app.windows) {
            if (w.hidden || w.alpha <= 0.01) continue;
            if (w.windowLevel != UIWindowLevelNormal) continue;
            if (w.isKeyWindow) return w;
            if (!candidate || (w.bounds.size.width * w.bounds.size.height > candidate.bounds.size.width * candidate.bounds.size.height)) {
                candidate = w;
            }
        }
    }
    return candidate;
}

static BOOL SBCPUGameIsLandscape(void) {
    if (SBCPUGameHostWindow) {
        CGRect b = SBCPUGameHostWindow.bounds;
        if (b.size.width > b.size.height + 20.0) return YES;
        if (b.size.height > b.size.width + 20.0) return NO;
    }

    if (@available(iOS 13.0, *)) {
        UIInterfaceOrientation o = SBCPUGameHostWindow.windowScene.interfaceOrientation;
        if (o == UIInterfaceOrientationLandscapeLeft || o == UIInterfaceOrientationLandscapeRight) return YES;
        if (o == UIInterfaceOrientationPortrait || o == UIInterfaceOrientationPortraitUpsideDown) return NO;
    }
    return NO;
}

static void SBCPUApplyGamePillLayout(void) {
    if (!SBCPUGamePill || !SBCPUGameHostWindow) return;

    CGRect b = SBCPUGameHostWindow.bounds;
    if (b.size.width < 100.0 || b.size.height < 100.0) return;

    BOOL landscape = SBCPUGameIsLandscape();

    if (landscape) {
        // ========================================================
        // 横屏：做成“贴左边缘的窄侧边胶囊”。
        // 重点：不旋转整个容器，只旋转里面的文字内容。
        // 尺寸按 iOS point 计算，避免旧版 82x420/630 造成过宽过长。
        // ========================================================
        CGFloat width = 50.0;
        CGFloat height = MIN(245.0, MAX(205.0, b.size.height - 120.0));
        if (height > b.size.height - 20.0) height = MAX(180.0, b.size.height - 20.0);

        CGFloat x = 0.0;
        CGFloat y = MAX(10.0, (b.size.height - height) * 0.5);

        SBCPUGamePill.transform = CGAffineTransformIdentity;
        SBCPUGamePill.bounds = CGRectMake(0, 0, width, height);
        SBCPUGamePill.center = CGPointMake(x + width * 0.5, y + height * 0.5);
        SBCPUGamePill.layer.cornerRadius = width * 0.5;

        // 蓝色菱形：保持原有视觉语言，放在侧边胶囊下半区。
        SBCPUGameIcon.transform = CGAffineTransformMakeRotation((CGFloat)-M_PI_2);
        SBCPUGameIcon.bounds = CGRectMake(0, 0, 26.0, 26.0);
        SBCPUGameIcon.center = CGPointMake(width * 0.5, height - 47.0);

        // 应用名/通知标题：先按横向文字布局，再整体逆时针 90°。
        // 旋转后的实际显示区域约为 20 x 150~175，正好位于窄胶囊中央。
        SBCPUGameApp.transform = CGAffineTransformMakeRotation((CGFloat)-M_PI_2);
        CGFloat textWidth = MIN(175.0, MAX(135.0, height - 62.0));
        SBCPUGameApp.bounds = CGRectMake(0, 0, textWidth, 18.0);
        SBCPUGameApp.center = CGPointMake(width * 0.5, height * 0.5 + 2.0);
        SBCPUGameApp.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
        SBCPUGameApp.adjustsFontSizeToFitWidth = YES;
        SBCPUGameApp.minimumScaleFactor = 0.70;

        // 数字：竖向显示，靠近底部。
        SBCPUGameCount.transform = CGAffineTransformMakeRotation((CGFloat)-M_PI_2);
        SBCPUGameCount.bounds = CGRectMake(0, 0, 28.0, 24.0);
        SBCPUGameCount.center = CGPointMake(width * 0.5, height - 20.0);
        SBCPUGameCount.font = [UIFont systemFontOfSize:18.0 weight:UIFontWeightBold];

    } else {
        // 竖屏：顶部小胶囊，保持原来的正常阅读方向。
        CGFloat width = MIN(390.0, b.size.width - 28.0);
        CGFloat height = 60.0;
        CGFloat x = (b.size.width - width) * 0.5;
        CGFloat y = MAX(12.0, b.origin.y);

        SBCPUGamePill.transform = CGAffineTransformIdentity;
        SBCPUGamePill.bounds = CGRectMake(0, 0, width, height);
        SBCPUGamePill.center = CGPointMake(x + width * 0.5, y + height * 0.5 + 6.0);
        SBCPUGamePill.layer.cornerRadius = height * 0.5;

        SBCPUGameIcon.transform = CGAffineTransformIdentity;
        SBCPUGameApp.transform = CGAffineTransformIdentity;
        SBCPUGameCount.transform = CGAffineTransformIdentity;

        SBCPUGameIcon.frame = CGRectMake(14, 15, 28, 28);
        SBCPUGameApp.frame = CGRectMake(48, 12, MAX(40.0, width - 90.0), 22);
        SBCPUGameCount.frame = CGRectMake(width - 40, 15, 28, 28);
        SBCPUGameApp.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
        SBCPUGameCount.font = [UIFont systemFontOfSize:21.0 weight:UIFontWeightBold];
    }

    [SBCPUGamePill.superview bringSubviewToFront:SBCPUGamePill];
}

static void SBCPUAttachGamePillToHostWindow(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *host = SBCPUFindGameHostWindow();
        if (!host) return;

        if (SBCPUGameHostWindow != host) {
            [SBCPUGamePill removeFromSuperview];
            SBCPUGameHostWindow = host;
            if (SBCPUGamePill) [host addSubview:SBCPUGamePill];
        } else if (SBCPUGamePill.superview != host) {
            [SBCPUGamePill removeFromSuperview];
            [host addSubview:SBCPUGamePill];
        }

        SBCPUApplyGamePillLayout();
    });
}

static void SBCPUCreateGamePillIfNeeded(void) {
    if (SBCPUGamePill) return;

    SBCPUGamePill = [[UIView alloc] initWithFrame:CGRectZero];
    SBCPUGamePill.backgroundColor = [UIColor colorWithWhite:0.01 alpha:0.96];
    SBCPUGamePill.layer.masksToBounds = YES;
    SBCPUGamePill.userInteractionEnabled = NO;
    SBCPUGamePill.accessibilityElementsHidden = YES;

    SBCPUGameIcon = [[UILabel alloc] initWithFrame:CGRectZero];
    SBCPUGameIcon.textAlignment = NSTextAlignmentCenter;
    SBCPUGameIcon.font = [UIFont systemFontOfSize:19.0 weight:UIFontWeightBold];
    SBCPUGameIcon.userInteractionEnabled = NO;
    [SBCPUGamePill addSubview:SBCPUGameIcon];

    SBCPUGameApp = [[UILabel alloc] initWithFrame:CGRectZero];
    SBCPUGameApp.textAlignment = NSTextAlignmentCenter;
    SBCPUGameApp.textColor = [UIColor colorWithWhite:1.0 alpha:0.92];
    SBCPUGameApp.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
    SBCPUGameApp.numberOfLines = 1;
    SBCPUGameApp.lineBreakMode = NSLineBreakByTruncatingTail;
    SBCPUGameApp.userInteractionEnabled = NO;
    [SBCPUGamePill addSubview:SBCPUGameApp];

    SBCPUGameCount = [[UILabel alloc] initWithFrame:CGRectZero];
    SBCPUGameCount.textAlignment = NSTextAlignmentCenter;
    SBCPUGameCount.textColor = UIColor.whiteColor;
    SBCPUGameCount.font = [UIFont systemFontOfSize:21.0 weight:UIFontWeightBold];
    SBCPUGameCount.userInteractionEnabled = NO;
    [SBCPUGamePill addSubview:SBCPUGameCount];
}

static void SBCPUHideGamePillAnimated(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!SBCPUGamePill || !SBCPUGameVisible) return;
        SBCPUGameVisible = NO;
        NSUInteger generation = ++SBCPUGameGeneration;
        BOOL landscape = SBCPUGameIsLandscape();
        CGAffineTransform out = landscape ? CGAffineTransformMakeTranslation(-105.0, 0) : CGAffineTransformMakeTranslation(0, -75.0);

        [UIView animateWithDuration:0.30 delay:0 options:UIViewAnimationOptionCurveEaseIn | UIViewAnimationOptionBeginFromCurrentState animations:^{
            SBCPUGamePill.alpha = 0.0;
            SBCPUGamePill.transform = CGAffineTransformConcat(out, CGAffineTransformIdentity);
        } completion:^(BOOL finished) {
            (void)finished;
            if (generation == SBCPUGameGeneration) {
                SBCPUGamePill.hidden = YES;
                SBCPUGamePill.transform = CGAffineTransformIdentity;
            }
        }];
    });
}

static void SBCPUShowGamePillFromDictionary(NSDictionary *data) {
    if (![data isKindOfClass:[NSDictionary class]]) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        SBCPUCreateGamePillIfNeeded();
        SBCPUAttachGamePillToHostWindow();

        dispatch_async(dispatch_get_main_queue(), ^{
            if (!SBCPUGamePill || !SBCPUGameHostWindow) return;

            NSString *bundle = [data[@"bundleID"] isKindOfClass:[NSString class]] ? data[@"bundleID"] : @"";
            NSString *title = [data[@"title"] isKindOfClass:[NSString class]] ? data[@"title"] : @"新消息";
            NSNumber *count = [data[@"count"] isKindOfClass:[NSNumber class]] ? data[@"count"] : @1;

            NSString *app = @"消息";
            NSString *icon = @"◆";
            UIColor *iconColor = UIColor.whiteColor;
            if ([bundle isEqualToString:@"com.tencent.xin"]) {
                app = @"微信";
                icon = @"●";
                iconColor = UIColor.systemGreenColor;
            } else if ([bundle.lowercaseString containsString:@"qq"]) {
                app = @"QQ";
                icon = @"◆";
                iconColor = UIColor.systemBlueColor;
            } else if ([bundle isEqualToString:@"com.tencent.tim"]) {
                app = @"TIM";
                icon = @"◆";
                iconColor = [UIColor colorWithRed:0.15 green:0.55 blue:1.0 alpha:1.0];
            }

            SBCPUGameIcon.text = icon;
            SBCPUGameIcon.textColor = iconColor;
            SBCPUGameApp.text = [NSString stringWithFormat:@"%@ · %@", app, title.length ? title : @"新消息"];
            SBCPUGameCount.text = [NSString stringWithFormat:@"%@", count];

            SBCPUApplyGamePillLayout();
            BOOL landscape = SBCPUGameIsLandscape();
            SBCPUGamePill.hidden = NO;
            SBCPUGamePill.alpha = 0.0;
            SBCPUGamePill.transform = landscape ? CGAffineTransformMakeTranslation(-105.0, 0) : CGAffineTransformMakeTranslation(0, -75.0);
            SBCPUGameVisible = YES;
            NSUInteger generation = ++SBCPUGameGeneration;

            [UIView animateWithDuration:0.34 delay:0 options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState animations:^{
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
        NSString *bundle = NSBundle.mainBundle.bundleIdentifier ?: @"";
        if ([bundle isEqualToString:@"com.apple.springboard"]) return;

        SBCPURegisterGameBannerNotification();

        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            (void)note;
            SBCPUAttachGamePillToHostWindow();
        }];
        [nc addObserverForName:UIWindowDidBecomeKeyNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            (void)note;
            SBCPUAttachGamePillToHostWindow();
            if (SBCPUGameVisible) SBCPUApplyGamePillLayout();
        }];
        [nc addObserverForName:UIDeviceOrientationDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            (void)note;
            SBCPUAttachGamePillToHostWindow();
            if (SBCPUGameVisible) SBCPUApplyGamePillLayout();
        }];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            SBCPUCreateGamePillIfNeeded();
            SBCPUAttachGamePillToHostWindow();
            SBCPUReadAndShowGameBanner();
        });
    });
}
