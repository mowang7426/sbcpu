#import "SBCPUFloatingCCModuleViewController.h"
#import <Foundation/Foundation.h>
#import <notify.h>

// Control Center 进程只负责读写一个简单的 CFPreferences 开关。
// 不调用 SpringBoard 对象、不访问 RootHide 路径、不创建悬浮窗。
static CFStringRef kSBCPUFloatingCCPrefAppID = CFSTR("com.yourname.sbcpufloating");
static CFStringRef kSBCPUFloatingCCPrefEnabledKey = CFSTR("isEnabled");
static const char *kSBCPUFloatingCCNotifyName = "com.yourname.sbcpufloating.prefschanged";

static NSString *SBCPUCCString(const char *value) {
    return value ? [NSString stringWithUTF8String:value] : [NSString stringWithUTF8String:"" ];
}

static BOOL SBCPUFloatingReadEnabled(void) {
    CFPropertyListRef value = CFPreferencesCopyValue(
        kSBCPUFloatingCCPrefEnabledKey,
        kSBCPUFloatingCCPrefAppID,
        kCFPreferencesCurrentUser,
        kCFPreferencesAnyHost);

    if (!value) return YES;

    BOOL enabled = YES;
    if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
        enabled = CFBooleanGetValue((CFBooleanRef)value);
    } else if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        int n = 0;
        if (CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &n)) {
            enabled = (n != 0);
        }
    }
    CFRelease(value);
    return enabled;
}

static void SBCPUFloatingWriteEnabled(BOOL enabled) {
    CFPreferencesSetValue(
        kSBCPUFloatingCCPrefEnabledKey,
        enabled ? kCFBooleanTrue : kCFBooleanFalse,
        kSBCPUFloatingCCPrefAppID,
        kCFPreferencesCurrentUser,
        kCFPreferencesAnyHost);
    CFPreferencesAppSynchronize(kSBCPUFloatingCCPrefAppID);
    notify_post(kSBCPUFloatingCCNotifyName);
}

@interface SBCPUFloatingCCModuleViewController ()
@property(nonatomic, strong) UIImageView *glyphOverlay;
@property(nonatomic, assign) BOOL compactGlyphApplied;
- (void)setupMenu;
- (void)updateState;
@end

@implementation SBCPUFloatingCCModuleViewController

- (instancetype)init {
    self = [super init];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = SBCPUCCString("SBCPUFloating");

    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:24.0 weight:UIImageSymbolWeightSemibold];
    UIImage *glyph = [UIImage systemImageNamed:SBCPUCCString("gauge.with.dots.needle.67percent") withConfiguration:config];
    if (!glyph) glyph = [UIImage systemImageNamed:SBCPUCCString("speedometer") withConfiguration:config];
    if (!glyph) glyph = [UIImage systemImageNamed:SBCPUCCString("cpu") withConfiguration:config];
    if ([self respondsToSelector:@selector(setGlyphImage:)]) [self setGlyphImage:glyph];

    if ([self respondsToSelector:@selector(setUseTallLayout:)]) [self setUseTallLayout:NO];
    if ([self respondsToSelector:@selector(setHideGlyphInHeader:)]) [self setHideGlyphInHeader:NO];
    if ([self respondsToSelector:@selector(setUseTrailingCheckmarkLayout:)]) [self setUseTrailingCheckmarkLayout:YES];
    if ([self respondsToSelector:@selector(setShouldProvideOwnPlatter:)]) [self setShouldProvideOwnPlatter:NO];

    self.glyphOverlay = [[UIImageView alloc] initWithFrame:CGRectZero];
    self.glyphOverlay.contentMode = UIViewContentModeScaleAspectFit;
    self.glyphOverlay.userInteractionEnabled = NO;
    self.glyphOverlay.accessibilityElementsHidden = YES;
    [self.view addSubview:self.glyphOverlay];

    [self setupMenu];
    [self updateState];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self updateState];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    CGRect bounds = self.view.bounds;
    BOOL compact = CGRectGetWidth(bounds) < 150.0 && CGRectGetHeight(bounds) < 150.0;
    self.glyphOverlay.hidden = !compact;

    if (compact) {
        self.title = SBCPUCCString("");
        if (!self.compactGlyphApplied && [self respondsToSelector:@selector(setGlyphImage:)]) {
            [self setGlyphImage:[[UIImage alloc] init]];
            self.compactGlyphApplied = YES;
        }

        CGFloat icon = MIN(48.0, MIN(CGRectGetWidth(bounds) * 0.55, CGRectGetHeight(bounds) * 0.55));
        self.glyphOverlay.frame = CGRectIntegral(CGRectMake(
            (CGRectGetWidth(bounds) - icon) / 2.0,
            (CGRectGetHeight(bounds) - icon) / 2.0,
            icon,
            icon));
        [self.view bringSubviewToFront:self.glyphOverlay];
    } else if (self.compactGlyphApplied) {
        self.compactGlyphApplied = NO;
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:24.0 weight:UIImageSymbolWeightSemibold];
        UIImage *glyph = [UIImage systemImageNamed:SBCPUCCString("gauge.with.dots.needle.67percent") withConfiguration:config];
        if (!glyph) glyph = [UIImage systemImageNamed:SBCPUCCString("speedometer") withConfiguration:config];
        if (!glyph) glyph = [UIImage systemImageNamed:SBCPUCCString("cpu") withConfiguration:config];
        if ([self respondsToSelector:@selector(setGlyphImage:)]) [self setGlyphImage:glyph];
        [self updateState];
    }
}

- (BOOL)shouldBeginTransitionToExpandedContentModule {
    return YES;
}

- (void)willTransitionToExpandedContentMode:(BOOL)animated {
    [super willTransitionToExpandedContentMode:animated];
    [self updateState];
}

- (CGFloat)preferredExpandedContentHeight {
    return 150.0;
}

- (CGFloat)preferredExpandedContentWidth {
    CGFloat width = 300.0;
    CGFloat screenWidth = CGRectGetWidth([UIScreen mainScreen].bounds);
    if (screenWidth > 0.0) width = MIN(width, screenWidth - 60.0);
    return MAX(width, 220.0);
}

- (BOOL)providesOwnPlatter {
    return NO;
}

- (BOOL)isSelected {
    return SBCPUFloatingReadEnabled();
}

- (void)setupMenu {
    __weak typeof(self) weakSelf = self;
    CCUIMenuModuleItem *item = [[CCUIMenuModuleItem alloc]
        initWithTitle:SBCPUCCString("SBCPUFloating")
        identifier:SBCPUCCString("sbcpufloating-toggle")
        handler:^{
            SBCPUFloatingCCModuleViewController *strongSelf = weakSelf;
            if (strongSelf) [strongSelf buttonTapped:nil forEvent:nil];
        }];

    if (!item) {
        self.menuItems = @[];
        return;
    }

    if ([item respondsToSelector:@selector(setSubtitle:)]) {
        [item setSubtitle:SBCPUCCString("点击开启 / 关闭悬浮窗")];
    }
    if ([item respondsToSelector:@selector(setSelected:)]) {
        [item setSelected:SBCPUFloatingReadEnabled()];
    }

    self.menuItems = @[item];
    if ([self respondsToSelector:@selector(setMinimumMenuItems:)]) [self setMinimumMenuItems:1];
    if ([self respondsToSelector:@selector(setVisibleMenuItems:)]) [self setVisibleMenuItems:1];
}

- (void)refreshState {
    [self updateState];
}

- (void)updateState {
    BOOL enabled = SBCPUFloatingReadEnabled();

    BOOL compact = CGRectGetWidth(self.view.bounds) < 150.0 && CGRectGetHeight(self.view.bounds) < 150.0;
    if (!compact) {
        self.title = enabled ? SBCPUCCString("SBCPUFloating") : SBCPUCCString("SBCPUFloating 已关闭");
    }

    if ([self respondsToSelector:@selector(setSelected:)]) {
        [self setSelected:enabled];
    }
    if ([self respondsToSelector:@selector(setSelectedGlyphColor:)]) {
        [self setSelectedGlyphColor:enabled ? [UIColor systemGreenColor] : [UIColor systemGrayColor]];
    }

    for (CCUIMenuModuleItem *item in self.menuItems) {
        if ([item respondsToSelector:@selector(setSelected:)]) [item setSelected:enabled];
        if ([item respondsToSelector:@selector(setSubtitle:)]) {
            [item setSubtitle:enabled ? SBCPUCCString("浮窗当前已开启") : SBCPUCCString("浮窗当前已关闭")];
        }
        if ([item respondsToSelector:@selector(setSelectedGlyphColor:)]) {
            [item setSelectedGlyphColor:enabled ? [UIColor systemGreenColor] : [UIColor systemGrayColor]];
        }
    }

    UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration configurationWithPointSize:42.0 weight:UIImageSymbolWeightSemibold];
    UIImage *baseGlyph = [UIImage systemImageNamed:SBCPUCCString("gauge.with.dots.needle.67percent") withConfiguration:configuration];
    if (!baseGlyph) baseGlyph = [UIImage systemImageNamed:SBCPUCCString("speedometer") withConfiguration:configuration];
    if (!baseGlyph) baseGlyph = [UIImage systemImageNamed:SBCPUCCString("cpu") withConfiguration:configuration];
    if (baseGlyph) {
        self.glyphOverlay.image = [baseGlyph imageWithTintColor:(enabled ? [UIColor systemGreenColor] : [UIColor systemGrayColor])
                                                  renderingMode:UIImageRenderingModeAlwaysOriginal];
    }
}

- (void)buttonTapped:(id)arg forEvent:(id)event {
    (void)arg;
    (void)event;

    // 关键安全修复：点击 CC 时只做“读写一个布尔偏好 + Darwin 通知”。
    // 不调用任何 SpringBoard 类、不触碰悬浮窗、不调用 120Hz/温控/快充代码。
    BOOL enabled = !SBCPUFloatingReadEnabled();
    SBCPUFloatingWriteEnabled(enabled);
    [self updateState];
}

@end
