#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <ControlCenterUIKit/CCUIToggleModule.h>

static CFStringRef const kSBCPUPrefAppID = CFSTR("com.yourname.sbcpufloating");
static CFStringRef const kSBCPUChangedNotification = CFSTR("com.yourname.sbcpufloating.prefschanged");

static BOOL SBCPUReadEnabled(void) {
    CFPreferencesAppSynchronize(kSBCPUPrefAppID);

    CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR("isEnabled"), kSBCPUPrefAppID);
    if (!value) {
        return YES;
    }

    BOOL enabled = YES;
    if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
        enabled = CFBooleanGetValue((CFBooleanRef)value);
    } else if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        int v = 1;
        if (CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &v)) {
            enabled = (v != 0);
        }
    }

    CFRelease(value);
    return enabled;
}

static void SBCPUWriteEnabled(BOOL enabled) {
    CFPreferencesSetValue(
        CFSTR("isEnabled"),
        enabled ? kCFBooleanTrue : kCFBooleanFalse,
        kSBCPUPrefAppID,
        kCFPreferencesCurrentUser,
        kCFPreferencesAnyHost
    );
    CFPreferencesAppSynchronize(kSBCPUPrefAppID);

    // 与主 Tweak 使用同一个 Darwin 通知。
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        kSBCPUChangedNotification,
        NULL,
        NULL,
        YES
    );
}

@interface SBCPUFloatingCC : CCUIToggleModule
@end

@implementation SBCPUFloatingCC

- (UIImage *)iconGlyph {
    UIImage *image = [UIImage imageNamed:@"SBCPUFloatingCC" inBundle:[NSBundle bundleForClass:[self class]] compatibleWithTraitCollection:nil];
    if (image) {
        return image;
    }

    if (@available(iOS 13.0, *)) {
        UIImage *fallback = [UIImage systemImageNamed:@"speedometer"];
        if (fallback) {
            return fallback;
        }
    }

    return [UIImage new];
}

- (UIColor *)selectedColor {
    if (@available(iOS 13.0, *)) {
        return [UIColor systemBlueColor];
    }
    return [UIColor blueColor];
}

- (BOOL)isSelected {
    return SBCPUReadEnabled();
}

- (void)setSelected:(BOOL)selected {
    SBCPUWriteEnabled(selected);
}

- (void)refreshState {
    [self setSelected:[self isSelected]];
}

@end
