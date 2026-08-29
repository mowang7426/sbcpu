#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>

//
// Control Center module compatibility declarations.
//
// Do NOT import ControlCenterUIKit headers here. The iPhoneOS 16.5 SDK used by
// this project does not ship those private headers, and importing them makes
// the GitHub Actions build fail before the bundle is compiled.
//
@protocol CCUIContentModule <NSObject>
@required
- (UIViewController *)contentViewController;
@optional
- (UIViewController *)backgroundViewController;
- (void)setContentModuleContext:(id)context;
@end

@interface CCUIContentModuleContext : NSObject
@end

static CFStringRef const kSBCPUAppID = CFSTR("com.yourname.sbcpufloating");
static CFStringRef const kSBCPUEnabledKey = CFSTR("isEnabled");
static CFStringRef const kSBCPUChangedNotification = CFSTR("com.yourname.sbcpufloating.prefschanged");

static BOOL SBCPUGetEnabled(void) {
    CFPreferencesAppSynchronize(kSBCPUAppID);

    CFPropertyListRef value = CFPreferencesCopyValue(
        kSBCPUEnabledKey,
        kSBCPUAppID,
        kCFPreferencesCurrentUser,
        kCFPreferencesAnyHost
    );

    // The original tweak defaults to enabled when the preference does not
    // exist, so the Control Center module follows exactly the same behavior.
    BOOL enabled = YES;

    if (value) {
        if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
            enabled = CFBooleanGetValue((CFBooleanRef)value);
        } else if (CFGetTypeID(value) == CFNumberGetTypeID()) {
            int number = 0;
            if (CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &number)) {
                enabled = (number != 0);
            }
        }
        CFRelease(value);
    }

    return enabled;
}

static void SBCPUSetEnabled(BOOL enabled) {
    CFPreferencesSetValue(
        kSBCPUEnabledKey,
        enabled ? kCFBooleanTrue : kCFBooleanFalse,
        kSBCPUAppID,
        kCFPreferencesCurrentUser,
        kCFPreferencesAnyHost
    );

    CFPreferencesSynchronize(
        kSBCPUAppID,
        kCFPreferencesCurrentUser,
        kCFPreferencesAnyHost
    );

    // Tweak.xm already listens for this Darwin notification and reloads
    // isEnabled immediately, so this is a real on/off switch rather than a
    // cosmetic Control Center button.
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        kSBCPUChangedNotification,
        NULL,
        NULL,
        YES
    );
}

@interface SBCPUFloatingCCViewController : UIViewController
@end

@implementation SBCPUFloatingCCViewController {
    UIButton *_button;
    UILabel *_titleLabel;
    BOOL _enabled;
}

- (void)loadView {
    self.view = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 80, 80)];
    self.view.backgroundColor = [UIColor clearColor];

    _button = [UIButton buttonWithType:UIButtonTypeSystem];
    _button.translatesAutoresizingMaskIntoConstraints = NO;
    _button.layer.cornerRadius = 18.0;
    _button.clipsToBounds = YES;
    _button.titleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    [_button addTarget:self action:@selector(togglePressed:) forControlEvents:UIControlEventTouchUpInside];

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    _titleLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
    _titleLabel.numberOfLines = 2;
    _titleLabel.userInteractionEnabled = NO;

    [self.view addSubview:_button];
    [self.view addSubview:_titleLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_button.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:5.0],
        [_button.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-5.0],
        [_button.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:5.0],
        [_button.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-5.0],
        [_titleLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_titleLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [_titleLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:8.0],
        [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-8.0]
    ]];

    [self refreshState];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self refreshState];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshState];
}

- (void)refreshState {
    BOOL enabled = SBCPUGetEnabled();
    _enabled = enabled;

    dispatch_async(dispatch_get_main_queue(), ^{
        self->_button.backgroundColor = enabled
            ? [UIColor colorWithRed:0.15 green:0.72 blue:0.34 alpha:1.0]
            : [UIColor colorWithWhite:0.50 alpha:0.28];
        self->_button.tintColor = UIColor.whiteColor;
        self->_titleLabel.textColor = UIColor.whiteColor;
        self->_titleLabel.text = enabled ? @"SB CPU\n开启" : @"SB CPU\n关闭";
    });
}

- (void)togglePressed:(id)sender {
    (void)sender;
    BOOL newValue = !SBCPUGetEnabled();
    SBCPUSetEnabled(newValue);
    [self refreshState];
}

@end

@interface SBCPUFloatingCCModule : NSObject <CCUIContentModule>
@property(nonatomic, retain) SBCPUFloatingCCViewController *contentViewController;
@property(nonatomic, retain) UIViewController *backgroundViewController;
@end

@implementation SBCPUFloatingCCModule

- (instancetype)init {
    self = [super init];
    if (self) {
        _contentViewController = [SBCPUFloatingCCViewController new];
        _backgroundViewController = [UIViewController new];
        _backgroundViewController.view.backgroundColor = UIColor.clearColor;
    }
    return self;
}

- (void)setContentModuleContext:(id)context {
    (void)context;
}

@end
