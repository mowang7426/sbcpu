#import "SBCPUFloatingCCModuleViewController.h"
#import <Foundation/Foundation.h>
#import <notify.h>

// Control Center 模块单独使用 CFPreferences 读写，与 SBCPUFloating 的
// LoadPreferences()/setBoolPref() 使用同一套偏好域，避免在 Control Center
// 进程中调用 RootHide 路径扫描、文件迁移等复杂逻辑。
static CFStringRef kSBCPUFloatingCCPrefAppID = CFSTR("com.yourname.sbcpufloating");
static CFStringRef kSBCPUFloatingCCPrefEnabledKey = CFSTR("isEnabled");
static CFStringRef kSBCPUFloatingCCNotify = CFSTR("com.yourname.sbcpufloating.prefschanged");

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
        CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &n);
        enabled = (n != 0);
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
    notify_post("com.yourname.sbcpufloating.prefschanged");
}

@interface SBCPUFloatingCCModuleViewController ()
@property(nonatomic,strong) UIImageView *glyphOverlay;
@property(nonatomic,assign) BOOL compactGlyphApplied;
- (void)updateState;
- (void)toggleFloating;
@end

@implementation SBCPUFloatingCCModuleViewController

- (instancetype)init {
    self = [super init];
    if (self) {
        [self updateState];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = S("SBCPUFloating");

    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:24.0 weight:UIImageSymbolWeightSemibold];
    UIImage *glyph = [UIImage systemImageNamed:S("gauge.with.dots.needle.67percent") withConfiguration:config];
    if (!glyph) glyph = [UIImage systemImageNamed:S("speedometer") withConfiguration:config];
    if (!glyph) glyph = [UIImage systemImageNamed:S("cpu") withConfiguration:config];
    if ([self respondsToSelector:@selector(setGlyphImage:)]) [self setGlyphImage:glyph];

    if ([self respondsToSelector:@selector(setUseTallLayout:)]) [self setUseTallLayout:NO];
    if ([self respondsToSelector:@selector(setHideGlyphInHeader:)]) [self setHideGlyphInHeader:NO];
    if ([self respondsToSelector:@selector(setUseTrailingCheckmarkLayout:)]) [self setUseTrailingCheckmarkLayout:YES];
    if ([self respondsToSelector:@selector(setShouldProvideOwnPlatter:)]) [self setShouldProvideOwnPlatter:NO];

    _glyphOverlay = [UIImageView new];
    _glyphOverlay.contentMode = UIViewContentModeScaleAspectFit;
    _glyphOverlay.userInteractionEnabled = NO;
    [self.view addSubview:_glyphOverlay];

    [self setupMenu];
    [self updateState];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshState];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect bounds = self.view.bounds;
    BOOL compact = CGRectGetWidth(bounds) < 150.0 && CGRectGetHeight(bounds) < 150.0;
    self.glyphOverlay.hidden = !compact;

    if (compact) {
        self.title = S("");
        if (!self.compactGlyphApplied && [self respondsToSelector:@selector(setGlyphImage:)]) {
            [self setGlyphImage:[[UIImage alloc] init]];
            self.compactGlyphApplied = YES;
        }
        CGFloat icon = MIN(48.0, MIN(CGRectGetWidth(bounds) * 0.55, CGRectGetHeight(bounds) * 0.55));
        self.glyphOverlay.frame = CGRectIntegral(CGRectMake((CGRectGetWidth(bounds)-icon)/2.0,
                                                              (CGRectGetHeight(bounds)-icon)/2.0,
                                                              icon, icon));
        [self.view bringSubviewToFront:self.glyphOverlay];
    } else if (self.compactGlyphApplied) {
        self.compactGlyphApplied = NO;
        [self restoreHeaderGlyph];
        [self updateState];
    }
}

- (void)restoreHeaderGlyph {
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:24.0 weight:UIImageSymbolWeightSemibold];
    UIImage *glyph = [UIImage systemImageNamed:S("gauge.with.dots.needle.67percent") withConfiguration:config];
    if (!glyph) glyph = [UIImage systemImageNamed:S("speedometer") withConfiguration:config];
    if (!glyph) glyph = [UIImage systemImageNamed:S("cpu") withConfiguration:config];
    if ([self respondsToSelector:@selector(setGlyphImage:)]) [self setGlyphImage:glyph];
}

- (BOOL)shouldBeginTransitionToExpandedContentModule {
    return YES;
}

- (void)willTransitionToExpandedContentMode:(BOOL)animated {
    [super willTransitionToExpandedContentMode:animated];
    [self refreshState];
}

- (CGFloat)preferredExpandedContentHeight {
    return 150.0;
}

- (CGFloat)preferredExpandedContentWidth {
    CGFloat width = 300.0;
    CGFloat screenWidth = CGRectGetWidth([UIScreen mainScreen].bounds);
    if (screenWidth > 0) width = MIN(width, screenWidth - 60.0);
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
        initWithTitle:S("SBCPUFloating")
        identifier:S("sbcpufloating-toggle")
        handler:^{ [weakSelf buttonTapped:nil forEvent:nil]; }];

    if ([item respondsToSelector:@selector(setSubtitle:)]) {
        [item setSubtitle:S("点击开启 / 关闭悬浮窗")];
    }
    self.menuItems = item ? @[item] : @[];
    if ([self respondsToSelector:@selector(setMinimumMenuItems:)]) [self setMinimumMenuItems:1];
    if ([self respondsToSelector:@selector(setVisibleMenuItems:)]) [self setVisibleMenuItems:1];
}

- (void)refreshState {
    [self updateState];
}

- (void)updateState {
    BOOL enabled = SBCPUFloatingReadEnabled();
    self.title = enabled ? S("SBCPUFloating") : S("SBCPUFloating 已关闭");

    if ([self respondsToSelector:@selector(setSelected:)]) {
        [self setSelected:enabled];
    }
    if ([self respondsToSelector:@selector(setSelectedGlyphColor:)]) {
        [self setSelectedGlyphColor:enabled ? [UIColor systemGreenColor] : [UIColor systemGrayColor]];
    }

    for (CCUIMenuModuleItem *item in self.menuItems) {
        if ([item respondsToSelector:@selector(setSelected:)]) [item setSelected:enabled];
        if ([item respondsToSelector:@selector(setSubtitle:)]) {
            [item setSubtitle:enabled ? S("浮窗当前已开启") : S("浮窗当前已关闭")];
        }
        if ([item respondsToSelector:@selector(setSelectedGlyphColor:)]) {
            [item setSelectedGlyphColor:enabled ? [UIColor systemGreenColor] : [UIColor systemGrayColor]];
        }
    }

    UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration configurationWithPointSize:42.0 weight:UIImageSymbolWeightSemibold];
    UIImage *baseGlyph = [UIImage systemImageNamed:S("gauge.with.dots.needle.67percent") withConfiguration:configuration];
    if (!baseGlyph) baseGlyph = [UIImage systemImageNamed:S("speedometer") withConfiguration:configuration];
    if (!baseGlyph) baseGlyph = [UIImage systemImageNamed:S("cpu") withConfiguration:configuration];
    UIImage *colored = [baseGlyph imageWithTintColor:(enabled ? [UIColor systemGreenColor] : [UIColor systemGrayColor])
                                       renderingMode:UIImageRenderingModeAlwaysOriginal];
    self.glyphOverlay.image = colored;
}

- (void)buttonTapped:(id)arg forEvent:(id)event {
    (void)arg;
    (void)event;

    // 这是 Control Center 的原生模块点击入口。
    // 只修改 isEnabled，不主动 dismiss、不创建窗口、不调用 RootHide 文件路径逻辑。
    BOOL enabled = !SBCPUFloatingReadEnabled();
    SBCPUFloatingWriteEnabled(enabled);
    [self updateState];
}

- (void)toggleFloating {
    [self buttonTapped:nil forEvent:nil];
}

@end
