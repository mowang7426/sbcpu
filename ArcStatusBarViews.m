//
//  ArcStatusBarViews.m
//  极简状态栏视图实现: 用 CAShapeLayer 绘制, 支持状态变化动画
//
#import "ArcStatusBarViews.h"

@implementation ASBDotSignalView {
    NSMutableArray<CAShapeLayer *> *_dots;
    UIColor *_inkColor;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _inkColor = [UIColor blackColor];
        _bars = 3;
        self.userInteractionEnabled = NO;
        self.contentMode = UIViewContentModeRedraw;
        _dots = [NSMutableArray arrayWithCapacity:4];
        for (int i = 0; i < 4; i++) {
            CAShapeLayer *dot = [CAShapeLayer layer];
            dot.fillColor = _inkColor.CGColor;
            dot.opacity = 0.0f;
            dot.contentsScale = [UIScreen mainScreen].scale;
            [self.layer addSublayer:dot];
            [_dots addObject:dot];
        }
    }
    return self;
}

- (void)setInkColor:(UIColor *)color {
    _inkColor = color ?: [UIColor blackColor];
    for (CAShapeLayer *d in _dots) d.fillColor = _inkColor.CGColor;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat h = CGRectGetHeight(self.bounds);
    if (h <= 0) return;
    CGFloat d   = MAX(2.0, h * 0.26);          // 点直径
    CGFloat gap = d * 1.05;
    CGFloat total = d * 4 + gap * 3;
    CGFloat x0 = (CGRectGetWidth(self.bounds) - total) / 2.0;
    CGFloat cy = h / 2.0;
    for (int i = 0; i < 4; i++) {
        CAShapeLayer *dot = _dots[i];
        CGRect r = CGRectMake(x0 + i * (d + gap), cy - d / 2.0, d, d);
        dot.path = [UIBezierPath bezierPathWithOvalInRect:r].CGPath;
    }
}

- (void)setBars:(NSInteger)bars animated:(BOOL)animated {
    _bars = MAX(0, MIN(4, bars));
    for (int i = 0; i < 4; i++) {
        CAShapeLayer *dot = _dots[i];
        CGFloat target = (i < _bars) ? 1.0f : 0.15f;
        if (animated) {
            CGFloat from = dot.presentationLayer ? dot.presentationLayer.opacity : dot.opacity;
            CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"opacity"];
            a.fromValue = @(from);
            a.toValue   = @(target);
            a.duration  = 0.22;
            a.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
            [dot addAnimation:a forKey:@"asb_op"];
        }
        dot.opacity = (float)target;
    }
}
@end

#pragma mark - 弧形 WiFi

@implementation ASBArcWifiView {
    CAShapeLayer *_arc;
    CAShapeLayer *_centerDot;
    UIColor *_inkColor;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _inkColor = [UIColor blackColor];
        _bars = 3;
        self.userInteractionEnabled = NO;

        _arc = [CAShapeLayer layer];
        _arc.fillColor = [UIColor clearColor].CGColor;
        _arc.strokeColor = _inkColor.CGColor;
        _arc.lineWidth = 1.6;
        _arc.lineCap = kCALineCapRound;
        _arc.strokeEnd = 0.0f;
        _arc.contentsScale = [UIScreen mainScreen].scale;
        [self.layer addSublayer:_arc];

        _centerDot = [CAShapeLayer layer];
        _centerDot.fillColor = _inkColor.CGColor;
        _centerDot.opacity = 0.0f;
        _centerDot.contentsScale = [UIScreen mainScreen].scale;
        [self.layer addSublayer:_centerDot];
    }
    return self;
}

- (void)setInkColor:(UIColor *)color {
    _inkColor = color ?: [UIColor blackColor];
    _arc.strokeColor = _inkColor.CGColor;
    _centerDot.fillColor = _inkColor.CGColor;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = CGRectGetWidth(self.bounds);
    CGFloat h = CGRectGetHeight(self.bounds);
    if (w <= 0 || h <= 0) return;

    CGFloat r = h * 0.44;
    CGPoint c = CGPointMake(w / 2.0, h * 0.70);
    // 开口朝下的弧形 (约 216°), 与视频中 "C 形弧 + 中心点" 一致
    CGFloat start = M_PI * 0.80;
    CGFloat end   = M_PI * 0.20;
    UIBezierPath *p = [UIBezierPath bezierPathWithArcCenter:c
                                                     radius:r
                                                 startAngle:start
                                                   endAngle:end
                                                  clockwise:YES];
    _arc.path = p.CGPath;

    CGFloat d = 1.8;
    _centerDot.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(c.x - d/2, c.y - d/2, d, d)].CGPath;
}

- (void)setBars:(NSInteger)bars animated:(BOOL)animated {
    _bars = MAX(0, MIN(3, bars));
    CGFloat frac = (_bars == 0) ? 0.06 : (_bars / 3.0);
    CGFloat from = _arc.presentationLayer ? _arc.presentationLayer.strokeEnd : 0.0f;

    void (^apply)(void) = ^{
        self->_arc.strokeEnd = frac;
        self->_arc.opacity = 1.0f;
        self->_centerDot.opacity = 1.0f;
    };
    if (animated) {
        CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"strokeEnd"];
        a.fromValue = @(from);
        a.toValue   = @(frac);
        a.duration  = 0.28;
        a.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        [_arc addAnimation:a forKey:@"asb_arc"];
        apply();
    } else {
        apply();
    }
}
@end

#pragma mark - 线性电池

@implementation ASBLineBatteryView {
    CAShapeLayer *_body;  // 外壳竖线
    CAShapeLayer *_fill;  // 电量填充
    CAShapeLayer *_cap;   // 顶部端子
    UIColor *_inkColor;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _inkColor = [UIColor blackColor];
        _capacity = 0.8;
        self.userInteractionEnabled = NO;

        _body = [CAShapeLayer layer];
        _body.fillColor = [UIColor clearColor].CGColor;
        _body.strokeColor = _inkColor.CGColor;
        _body.lineWidth = 1.4;
        _body.lineCap = kCALineCapRound;
        _body.contentsScale = [UIScreen mainScreen].scale;
        [self.layer addSublayer:_body];

        _fill = [CAShapeLayer layer];
        _fill.fillColor = _inkColor.CGColor;
        _fill.contentsScale = [UIScreen mainScreen].scale;
        [self.layer addSublayer:_fill];

        _cap = [CAShapeLayer layer];
        _cap.fillColor = _inkColor.CGColor;
        _cap.contentsScale = [UIScreen mainScreen].scale;
        [self.layer addSublayer:_cap];
    }
    return self;
}

- (void)setInkColor:(UIColor *)color {
    _inkColor = color ?: [UIColor blackColor];
    _body.strokeColor = _inkColor.CGColor;
    _fill.fillColor = _inkColor.CGColor;
    _cap.fillColor = _inkColor.CGColor;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = CGRectGetWidth(self.bounds);
    CGFloat h = CGRectGetHeight(self.bounds);
    if (w <= 0 || h <= 0) return;

    CGFloat bodyH = h * 0.78;
    CGFloat bodyW = MAX(2.2, w * 0.22);
    CGFloat x = w / 2.0 - bodyW / 2.0;
    CGFloat y = (h - bodyH) / 2.0;

    // 外壳: 圆角竖线
    UIBezierPath *bp = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(x, y, bodyW, bodyH)
                                                  cornerRadius:bodyW / 2.0];
    _body.path = bp.CGPath;

    // 端子: 顶部小圆角矩形
    CGFloat capW = bodyW * 0.55;
    CGFloat capH = 2.0;
    _cap.path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(w/2 - capW/2, y - capH + 0.5, capW, capH)
                                           cornerRadius:capW/2].CGPath;

    [self _layoutFillWithCapacity:_capacity];
}

- (void)_layoutFillWithCapacity:(CGFloat)cap {
    CGFloat h = CGRectGetHeight(self.bounds);
    if (h <= 0) return;
    CGFloat bodyH = h * 0.78;
    CGFloat bodyW = MAX(2.2, CGRectGetWidth(self.bounds) * 0.22);
    CGFloat x = CGRectGetWidth(self.bounds) / 2.0 - bodyW / 2.0;
    CGFloat y = (h - bodyH) / 2.0;
    CGFloat inset = 0.8;
    CGFloat fillH = MAX(0.0, (bodyH - inset * 2) * MAX(0.0, MIN(1.0, cap)));
    _fill.path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(x + inset, y + bodyH - inset - fillH,
                                                                   bodyW - inset * 2, fillH)
                                            cornerRadius:(bodyW - inset * 2) / 2.0].CGPath;
}

- (void)setCapacity:(CGFloat)capacity animated:(BOOL)animated {
    _capacity = MAX(0.0, MIN(1.0, capacity));
    if (animated) {
        id fromPath = _fill.presentationLayer ? (id)_fill.presentationLayer.path : (id)_fill.path;
        CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"path"];
        a.fromValue = fromPath;
        a.duration = 0.3;
        a.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        [_fill addAnimation:a forKey:@"asb_fill"];
    }
    [self _layoutFillWithCapacity:_capacity];
}
@end

#pragma mark - 一次性形变动画

@implementation ASBAnimator

+ (void)playIntroOnSignal:(ASBDotSignalView *)signal
                     wifi:(ASBArcWifiView *)wifi
                  battery:(ASBLineBatteryView *)battery {
    // 阶段 1 (0s~0.45s): 信号 4 点逐一亮起
    for (NSInteger i = 0; i < 4; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [signal setBars:i + 1 animated:YES];
        });
    }
    // 阶段 2 (0.5s): WiFi 弧线 "画" 出来
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [wifi setBars:3 animated:YES];
    });
    // 阶段 3 (0.8s): 电池从 0 充到当前电量
    CGFloat cap = battery.capacity;
    [battery setCapacity:0 animated:NO];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [battery setCapacity:cap animated:YES];
    });
}

@end
