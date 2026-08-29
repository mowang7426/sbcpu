#import "SBCPUFloatingCCModuleViewController.h"
#import <notify.h>
#import <Foundation/Foundation.h>
#import <roothide.h>

static const char *kSBCPUCCPrefPath = "/var/mobile/Library/Preferences/com.yourname.sbcpufloating.plist";
static const char *kSBCPUCCChangedNotification = "com.yourname.sbcpufloating.prefschanged";

static NSString *CCS(const char *s) { return s ? [NSString stringWithUTF8String:s] : @""; }

static NSString *SBCPUCCResolvedPrefPath(void) {
    NSString *raw = CCS(kSBCPUCCPrefPath);
    const char *jb = jbroot(kSBCPUCCPrefPath);
    if (jb && strlen(jb) > 0) {
        NSString *p = CCS(jb);
        if ([[NSFileManager defaultManager] fileExistsAtPath:p]) return p;
        if ([p containsString:@".jbroot-"]) return p;
    }
    NSString *varjb = [CCS("/var/jb") stringByAppendingPathComponent:[raw substringFromIndex:1]];
    if ([[NSFileManager defaultManager] fileExistsAtPath:varjb]) return varjb;
    return raw;
}

static BOOL SBCPUCCReadEnabled(void) {
    NSString *path = SBCPUCCResolvedPrefPath();
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:path];
    id v = d[CCS("isEnabled")];
    return v ? [v boolValue] : YES;
}

static void SBCPUCCWriteEnabled(BOOL enabled) {
    NSString *path = SBCPUCCResolvedPrefPath();
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:path];
    if (!d) d = [NSMutableDictionary dictionary];
    d[CCS("isEnabled")] = @(enabled);
    NSString *dir = [path stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    [d writeToFile:path atomically:YES];
    int token = 0;
    if (notify_register_check(kSBCPUCCChangedNotification, &token) == NOTIFY_STATUS_OK) {
        notify_post(kSBCPUCCChangedNotification);
        notify_cancel(token);
    }
}

@implementation SBCPUFloatingCCModuleViewController {
    UIImageView *_compactGlyphOverlay;
    BOOL _compactGlyphApplied;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // Keep the Control Center presentation consistent with CPUthermal's working implementation.
        if ([self respondsToSelector:@selector(setUseTallLayout:)]) [self setUseTallLayout:NO];
        if ([self respondsToSelector:@selector(setUseTrailingCheckmarkLayout:)]) [self setUseTrailingCheckmarkLayout:NO];
        if ([self respondsToSelector:@selector(setHideGlyphInHeader:)]) [self setHideGlyphInHeader:NO];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = CCS("SBCPUFloating");

    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightSemibold];
    UIImage *glyph = [UIImage systemImageNamed:CCS("speedometer") withConfiguration:cfg];
    if (!glyph) glyph = [UIImage systemImageNamed:CCS("gauge.with.dots.needle.67percent") withConfiguration:cfg];
    if ([self respondsToSelector:@selector(setGlyphImage:)]) [self setGlyphImage:glyph];
    if ([self respondsToSelector:@selector(setSelectedGlyphColor:)]) [self setSelectedGlyphColor:[UIColor systemGreenColor]];

    _compactGlyphOverlay = [UIImageView new];
    _compactGlyphOverlay.contentMode = UIViewContentModeScaleAspectFit;
    _compactGlyphOverlay.userInteractionEnabled = NO;
    [self.view addSubview:_compactGlyphOverlay];
    [self refreshState];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshState];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect b = self.view.bounds;
    BOOL compact = CGRectGetWidth(b) < 150.0 && CGRectGetHeight(b) < 150.0;
    _compactGlyphOverlay.hidden = !compact;
    if (compact) {
        self.title = CCS("");
        if (!_compactGlyphApplied && [self respondsToSelector:@selector(setGlyphImage:)]) {
            [self setGlyphImage:[[UIImage alloc] init]];
            _compactGlyphApplied = YES;
        }
        CGFloat icon = MIN(48.0, MIN(CGRectGetWidth(b) * 0.55, CGRectGetHeight(b) * 0.55));
        _compactGlyphOverlay.frame = CGRectIntegral(CGRectMake((CGRectGetWidth(b)-icon)/2.0, (CGRectGetHeight(b)-icon)/2.0, icon, icon));
        BOOL enabled = SBCPUCCReadEnabled();
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:42 weight:UIImageSymbolWeightSemibold];
        UIImage *base = [UIImage systemImageNamed:CCS("speedometer") withConfiguration:cfg];
        if (!base) base = [UIImage systemImageNamed:CCS("gauge.with.dots.needle.67percent") withConfiguration:cfg];
        _compactGlyphOverlay.image = [base imageWithTintColor:(enabled ? [UIColor systemGreenColor] : [UIColor systemGrayColor]) renderingMode:UIImageRenderingModeAlwaysOriginal];
        [self.view bringSubviewToFront:_compactGlyphOverlay];
    } else if (_compactGlyphApplied) {
        self.title = CCS("SBCPUFloating");
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightSemibold];
        UIImage *glyph = [UIImage systemImageNamed:CCS("speedometer") withConfiguration:cfg];
        if (!glyph) glyph = [UIImage systemImageNamed:CCS("gauge.with.dots.needle.67percent") withConfiguration:cfg];
        if ([self respondsToSelector:@selector(setGlyphImage:)]) [self setGlyphImage:glyph];
        _compactGlyphApplied = NO;
    }
}

- (BOOL)isSelected {
    return SBCPUCCReadEnabled();
}

- (CGFloat)preferredExpandedContentHeight { return 120.0; }
- (CGFloat)preferredExpandedContentWidth { return 320.0; }
- (BOOL)providesOwnPlatter { return NO; }
- (BOOL)shouldBeginTransitionToExpandedContentModule { return YES; }

- (void)refreshState {
    BOOL enabled = SBCPUCCReadEnabled();
    __weak typeof(self) weakSelf = self;
    CCUIMenuModuleItem *item = [[CCUIMenuModuleItem alloc] initWithTitle:CCS("SBCPUFloating") identifier:CCS("sbcpu-toggle") handler:^{
        BOOL now = SBCPUCCReadEnabled();
        SBCPUCCWriteEnabled(!now);
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf refreshState]; });
    }];
    [item setSubtitle:enabled ? CCS("浮窗已开启 · 点击关闭") : CCS("浮窗已关闭 · 点击开启")];
    [item setSelected:enabled];
    if (enabled && [item respondsToSelector:@selector(setSelectedGlyphColor:)]) [item setSelectedGlyphColor:[UIColor systemGreenColor]];
    if ([self respondsToSelector:@selector(setMenuItems:)]) self.menuItems = @[item];
    if ([self respondsToSelector:@selector(setVisibleMenuItems:)]) [self setVisibleMenuItems:1];
    if ([self respondsToSelector:@selector(setMinimumMenuItems:)]) [self setMinimumMenuItems:1];
    if ([self respondsToSelector:@selector(setSelected:)]) [self setSelected:enabled];
    if ([self respondsToSelector:@selector(setSelectedGlyphColor:)]) [self setSelectedGlyphColor:enabled ? [UIColor systemGreenColor] : [UIColor systemGrayColor]];
    [self.view setNeedsLayout];
}

- (void)willTransitionToExpandedContentMode:(BOOL)animated {
    [super willTransitionToExpandedContentMode:animated];
    [self refreshState];
}
@end
