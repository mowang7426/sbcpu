#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import "headers/ControlCenterUIKit/CCUIContentModuleCompat.h"

static CFStringRef const kSBCPUAppID = CFSTR("com.yourname.sbcpufloating");
static CFStringRef const kSBCPUChangedNotification = CFSTR("com.yourname.sbcpufloating.prefschanged");

static BOOL SBCPUGetEnabled(void) {
    CFPreferencesAppSynchronize(kSBCPUAppID);
    CFTypeRef value = CFPreferencesCopyValue(CFSTR("isEnabled"),
                                               kSBCPUAppID,
                                               kCFPreferencesCurrentUser,
                                               kCFPreferencesAnyHost);
    BOOL enabled = YES;
    if (value) {
        if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
            enabled = CFBooleanGetValue((CFBooleanRef)value);
        }
        CFRelease(value);
    }
    return enabled;
}

static void SBCPUSetEnabled(BOOL enabled) {
    CFPreferencesSetValue(CFSTR("isEnabled"),
                          enabled ? kCFBooleanTrue : kCFBooleanFalse,
                          kSBCPUAppID,
                          kCFPreferencesCurrentUser,
                          kCFPreferencesAnyHost);
    CFPreferencesSynchronize(kSBCPUAppID,
                             kCFPreferencesCurrentUser,
                             kCFPreferencesAnyHost);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                          kSBCPUChangedNotification,
                                          NULL, NULL, YES);
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
    _button.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [_button addTarget:self action:@selector(togglePressed:) forControlEvents:UIControlEventTouchUpInside];

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    _titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    _titleLabel.numberOfLines = 2;
    _titleLabel.userInteractionEnabled = NO;

    [self.view addSubview:_button];
    [self.view addSubview:_titleLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_button.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:5],
        [_button.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-5],
        [_button.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:5],
        [_button.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-5],
        [_titleLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_titleLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [_titleLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:8],
        [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-8]
    ]];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(refreshState)
                                                 name:UIApplicationWillEnterForegroundNotification
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(refreshState)
                                                 name:@"SBCPUFloatingCCRefresh"
                                               object:nil];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self refreshState];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshState];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)refreshState {
    _enabled = SBCPUGetEnabled();
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_button.backgroundColor = self->_enabled
            ? [UIColor colorWithRed:0.15 green:0.72 blue:0.34 alpha:1.0]
            : [UIColor colorWithWhite:0.50 alpha:0.28];
        self->_button.tintColor = UIColor.whiteColor;
        self->_titleLabel.textColor = UIColor.whiteColor;
        self->_titleLabel.text = self->_enabled ? @"SB CPU\n开启" : @"SB CPU\n关闭";
    });
}

- (void)togglePressed:(id)sender {
    BOOL newValue = !SBCPUGetEnabled();
    SBCPUSetEnabled(newValue);
    _enabled = newValue;
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
