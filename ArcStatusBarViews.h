//
//  ArcStatusBarViews.h
//  自定义极简状态栏视图: 点阵信号 / 弧形WiFi / 线性电池
//
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 点阵信号: 4 个圆点, 按信号强度点亮
@interface ASBDotSignalView : UIView
@property (nonatomic, assign) NSInteger bars; // 0 ~ 4
- (void)setBars:(NSInteger)bars animated:(BOOL)animated;
- (void)setInkColor:(UIColor *)color;
@end

/// 弧形 WiFi: 圆弧 + 中心点, 弧长随信号强度变化
@interface ASBArcWifiView : UIView
@property (nonatomic, assign) NSInteger bars; // 0 ~ 3
- (void)setBars:(NSInteger)bars animated:(BOOL)animated;
- (void)setInkColor:(UIColor *)color;
@end

/// 线性电池: 细竖线 + 电量填充 + 顶部小端子
@interface ASBLineBatteryView : UIView
@property (nonatomic, assign) CGFloat capacity; // 0.0 ~ 1.0
- (void)setCapacity:(CGFloat)capacity animated:(BOOL)animated;
- (void)setInkColor:(UIColor *)color;
@end

/// 一次性的"点阵 -> 弧形"形变动画 (模仿视频中的加载效果)
@interface ASBAnimator : NSObject
+ (void)playIntroOnSignal:(ASBDotSignalView *)signal
                     wifi:(ASBArcWifiView *)wifi
                  battery:(ASBLineBatteryView *)battery;
@end

NS_ASSUME_NONNULL_END
