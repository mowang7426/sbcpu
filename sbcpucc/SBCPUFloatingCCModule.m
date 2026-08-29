#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>

// ControlCenterUIKit private API declarations.  The actual framework is supplied by iOS.
@interface CCUIContentModuleContext : NSObject
- (void)dismissModule;
@end

@protocol CCUIContentModule <NSObject>
@required
- (UIViewController *)contentViewController;
- (UIViewController *)backgroundViewController;
@optional
- (instancetype)initWithContext:(CCUIContentModuleContext *)context;
@end

@interface CCUIButtonModuleViewController : UIViewController
@property(nonatomic,readonly) CCUIContentModuleContext *contentModuleContext;
@property(nonatomic,readonly) UIView *buttonView;
- (void)setSelected:(BOOL)selected;
- (BOOL)isSelected;
- (void)buttonTapped:(id)sender;
@end

static NSString * const kSBCPUPrefAppID = @"com.yourname.sbcpufloating";
static CFStringRef const kSBCPUEnabledKey = CFSTR("isEnabled");
static CFStringRef const kSBCPUPrefChanged = CFSTR("com.yourname.sbcpufloating.prefschanged");

static BOOL SBCPUGetEnabled(void) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kSBCPUPrefAppID);
    CFPropertyListRef value = CFPreferencesCopyValue(kSBCPUEnabledKey,
                                                      (__bridge CFStringRef)kSBCPUPrefAppID,
                                                      kCFPreferencesCurrentUser,
                                                      kCFPreferencesAnyHost);
    if (!value) return YES;
    BOOL enabled = YES;
    if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
        enabled = CFBooleanGetValue((CFBooleanRef)value);
    }
    CFRelease(value);
    return enabled;
}

static void SBCPUSetEnabled(BOOL enabled) {
    CFPreferencesSetValue(kSBCPUEnabledKey,
                           enabled ? kCFBooleanTrue : kCFBooleanFalse,
                           (__bridge CFStringRef)kSBCPUPrefAppID,
                           kCFPreferencesCurrentUser,
                           kCFPreferencesAnyHost);
    CFPreferencesSynchronize((__bridge CFStringRef)kSBCPUPrefAppID,
                             kCFPreferencesCurrentUser,
                             kCFPreferencesAnyHost);

    // Same Darwin notification already consumed by the main SpringBoard tweak.
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                          kSBCPUPrefChanged,
                                          NULL,
                                          NULL,
                                          YES);
}

static void SBCPUSetViewSelected(CCUIButtonModuleViewController *vc) {
    if (!vc) return;
    [vc setSelected:SBCPUGetEnabled()];
}

@interface SBCPUFloatingCCViewController : CCUIButtonModuleViewController
@end

static void SBCPUCCPreferenceChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    (void)center; (void)name; (void)object; (void)userInfo;
    SBCPUFloatingCCViewController *vc = (__bridge SBCPUFloatingCCViewController *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{
        SBCPUSetViewSelected(vc);
    });
}

@implementation SBCPUFloatingCCViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    SBCPUSetViewSelected(self);

    // Keep the module synchronized with the preference bundle / tweak.
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                     (__bridge const void *)(self),
                                     SBCPUCCPreferenceChanged,
                                     kSBCPUPrefChanged,
                                     NULL,
                                     CFNotificationSuspensionBehaviorDeliverImmediately);
}

- (void)dealloc {
    CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        (__bridge const void *)(self),
                                        kSBCPUPrefChanged,
                                        NULL);
}

- (void)buttonTapped:(id)sender {
    (void)sender;
    BOOL enabled = !SBCPUGetEnabled();
    SBCPUSetEnabled(enabled);
    [self setSelected:enabled];
}

@end

@interface SBCPUFloatingCCModule : NSObject <CCUIContentModule>
@property(nonatomic,retain) SBCPUFloatingCCViewController *contentViewController;
@property(nonatomic,retain) UIViewController *backgroundViewController;
@end

@implementation SBCPUFloatingCCModule

- (instancetype)initWithContext:(CCUIContentModuleContext *)context {
    self = [super init];
    if (self) {
        _contentViewController = [[SBCPUFloatingCCViewController alloc] init];
        _backgroundViewController = nil;
        (void)context;
    }
    return self;
}

- (UIViewController *)contentViewController {
    return _contentViewController;
}

- (UIViewController *)backgroundViewController {
    return _backgroundViewController;
}

@end
