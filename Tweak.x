//
//  Tweak.x
//  ArcStatusBar — 极简点阵状态栏
//
//  原理: iOS 13+ 状态栏是 _UIStatusBar 架构, 各图标为 _UIStatusBar*View 子类。
//  这里 hook 蜂窝信号 / WiFi / 电池三个 item view, 隐藏原生图标,
//  叠加自定义的 "4点信号 + 弧形WiFi + 线性电池", 并保留原生数据同步。
//
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "ArcStatusBarViews.h"

static const void *kSigKey  = &kSigKey;
static const void *kWifiKey = &kWifiKey;
static const void *kBatKey  = &kBatKey;

// 私有类声明: 让编译器知道这些状态栏 item 类是 UIView 子类,
// 否则无法访问 self.bounds / self.frame / self.tintColor 等属性
// (不声明会报 "forward class object" 错误)
@interface _UIStatusBarCellularSignalView : UIView @end
@interface _UIStatusBarWifiSignalView : UIView @end
@interface _UIStatusBarBatteryView : UIView @end

// 记录最近一次创建的实例, 供 SpringBoard 启动动画使用
static ASBDotSignalView  *gSigView;
static ASBArcWifiView    *gWifiView;
static ASBLineBatteryView *gBatView;

static UIColor *ASBInk(UIView *host) {
    return host.tintColor ?: [UIColor blackColor];
}

// 把自定义视图挂到 item view 上, 并隐藏原生图标
static void ASBInstall(UIView *host, UIView *custom, const void *key) {
    UIView *old = objc_getAssociatedObject(host, key);
    if (old && old != custom) {
        [old removeFromSuperview];
    }
    if (custom.superview != host) {
        custom.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [host addSubview:custom];
        objc_setAssociatedObject(host, key, custom, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    custom.frame = host.bounds;
    // 隐藏原生图标层 (保留布局, 只隐藏显示)
    for (UIView *sub in host.subviews) {
        if (sub != custom) sub.alpha = 0.0;
    }
}

#pragma mark - 蜂窝信号: 4 点阵

%hook _UIStatusBarCellularSignalView

- (void)layoutSubviews {
    %orig;
    ASBDotSignalView *v = objc_getAssociatedObject(self, kSigKey);
    if (!v) {
        v = [[ASBDotSignalView alloc] initWithFrame:self.bounds];
        ASBInstall(self, v, kSigKey);
        gSigView = v;
    }
    v.frame = self.bounds;
    [v setInkColor:ASBInk(self)];
    NSInteger bars = 3;
    NSNumber *n = [self valueForKey:@"_signalStrengthBars"];
    if (n) bars = MAX(0, MIN(4, n.integerValue));
    [v setBars:bars animated:NO];
}

%end

#pragma mark - WiFi: 弧形 + 中心点

%hook _UIStatusBarWifiSignalView

- (void)layoutSubviews {
    %orig;
    ASBArcWifiView *v = objc_getAssociatedObject(self, kWifiKey);
    if (!v) {
        v = [[ASBArcWifiView alloc] initWithFrame:self.bounds];
        ASBInstall(self, v, kWifiKey);
        gWifiView = v;
    }
    v.frame = self.bounds;
    [v setInkColor:ASBInk(self)];
    NSInteger bars = 3;
    NSNumber *n = [self valueForKey:@"_signalStrengthBars"];
    if (n) bars = MAX(0, MIN(3, n.integerValue));
    [v setBars:bars animated:NO];
}

%end

#pragma mark - 电池: 线性竖条

%hook _UIStatusBarBatteryView

- (void)layoutSubviews {
    %orig;
    ASBLineBatteryView *v = objc_getAssociatedObject(self, kBatKey);
    if (!v) {
        v = [[ASBLineBatteryView alloc] initWithFrame:self.bounds];
        ASBInstall(self, v, kBatKey);
        gBatView = v;
    }
    v.frame = self.bounds;
    [v setInkColor:ASBInk(self)];
    CGFloat cap = 0.8;
    NSNumber *n = [self valueForKey:@"capacity"];
    if (n) cap = MAX(0.0, MIN(1.0, n.doubleValue));
    [v setCapacity:cap animated:NO];
}

%end

#pragma mark - 启动动画 (仅 SpringBoard)

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (gSigView && gWifiView && gBatView) {
            [ASBAnimator playIntroOnSignal:gSigView wifi:gWifiView battery:gBatView];
        }
    });
}

%end
