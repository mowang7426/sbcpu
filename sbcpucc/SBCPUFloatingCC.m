#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <ControlCenterUIKit/CCUIContentModule.h>
#import <ControlCenterUIKit/CCUIContentModuleContext.h>
#import <ControlCenterUIKit/CCUIToggleModule.h>

static CFStringRef const kSBCPUPrefAppID = CFSTR("com.yourname.sbcpufloating");
static CFStringRef const kSBCPUEnabledKey = CFSTR("isEnabled");
static NSString * const kSBCPUChangedNotification = @"com.yourname.sbcpufloating.prefschanged";

static BOOL SBCPUIsEnabled(void) {
    CFPreferencesAppSynchronize(kSBCPUPrefAppID);
    CFPropertyListRef value = CFPreferencesCopyValue(kSBCPUEnabledKey, kSBCPUPrefAppID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    BOOL enabled = YES;
    if (value) {
        if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
            enabled = CFBooleanGetValue((CFBooleanRef)value);
        } else if (CFGetTypeID(value) == CFNumberGetTypeID()) {
            int v = 0;
            CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &v);
            enabled = (v != 0);
        }
        CFRelease(value);
    }
    return enabled;
}

static void SBCPUSetEnabled(BOOL enabled) {
    CFPreferencesSetValue(kSBCPUEnabledKey, enabled ? kCFBooleanTrue : kCFBooleanFalse, kSBCPUPrefAppID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPreferencesAppSynchronize(kSBCPUPrefAppID);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                          CFSTR("com.yourname.sbcpufloating.prefschanged"),
                                          NULL, NULL, YES);
}

@interface SBCPUFloatingCC : NSObject <CCUIContentModule, CCUIToggleModule>
@property(nonatomic, retain) CCUIContentModuleContext *contentModuleContext;
@end

@implementation SBCPUFloatingCC

- (UIImage *)iconGlyph {
    UIImage *image = [UIImage imageNamed:@"SBCPUFloatingCCIcon"];
    if (image) return image;
    if (@available(iOS 13.0, *)) {
        return [UIImage systemImageNamed:@"gauge.with.dots.needle.67percent"];
    }
    return nil;
}

- (UIColor *)selectedColor {
    if (@available(iOS 13.0, *)) return [UIColor systemGreenColor];
    return [UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:1.0];
}

- (BOOL)isSelected {
    return SBCPUIsEnabled();
}

- (void)setSelected:(BOOL)selected {
    SBCPUSetEnabled(selected);
    if ([self.contentModuleContext respondsToSelector:@selector(updateState)]) {
        [self.contentModuleContext updateState];
    }
}

- (void)buttonTapped:(id)sender {
    [self setSelected:!self.isSelected];
}

@end
