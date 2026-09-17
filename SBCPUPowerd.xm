// SBCPUPowerd.xm — safe fast-charge helper
//
// This tweak intentionally does NOT touch the decision whether charging is
// allowed. CH0C/CH0I and the 80/70 hysteresis live exclusively in
// SBCPUChargeDaemon. powerd is limited to current/power-limit properties used
// by the optional "force fast charge" feature, and never spoofs battery state.

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <IOKit/IOKitLib.h>
#import <notify.h>
#import <dlfcn.h>
#import <substrate.h>

static CFStringRef const kSBCPUPrefAppID = CFSTR("com.yourname.sbcpufloating");
static CFStringRef const kSBCPUSettingsChanged = CFSTR("com.yourname.sbcpufloating/settingsChanged");
static CFStringRef const kSBCPUPowerdReady = CFSTR("powerdHookReady");
static CFStringRef const kSBCPUPowerdReadyNotification = CFSTR("com.yourname.sbcpufloating/powerdHookReady");

static BOOL gForceFastCharge = NO;
static BOOL gHookInstalled = NO;

typedef kern_return_t (*IORegistryEntrySetCFPropertyFn)(io_registry_entry_t, CFStringRef, CFTypeRef);
typedef kern_return_t (*IOServiceSetCFPropertyFn)(io_service_t, CFStringRef, CFTypeRef);

static IORegistryEntrySetCFPropertyFn orig_IORegistryEntrySetCFProperty = NULL;
static IOServiceSetCFPropertyFn orig_IOServiceSetCFProperty = NULL;

static BOOL readBoolPref(CFStringRef key, BOOL fallback) {
    CFPreferencesAppSynchronize(kSBCPUPrefAppID);
    CFPropertyListRef v = CFPreferencesCopyValue(key, kSBCPUPrefAppID,
                                                   kCFPreferencesCurrentUser,
                                                   kCFPreferencesAnyHost);
    if (!v) return fallback;
    BOOL result = fallback;
    if (CFGetTypeID(v) == CFBooleanGetTypeID()) {
        result = CFBooleanGetValue((CFBooleanRef)v);
    } else if (CFGetTypeID(v) == CFNumberGetTypeID()) {
        int n = 0;
        if (CFNumberGetValue((CFNumberRef)v, kCFNumberIntType, &n)) result = (n != 0);
    }
    CFRelease(v);
    return result;
}

// Only current/power limiting knobs belong here. In particular, never block
// ChargeInhibit/ChargeBlocked/ChargeLimit/FullyCharged or thermal safety keys.
static BOOL isFastChargeProperty(CFStringRef propertyName) {
    if (!propertyName) return NO;
    NSString *s = (__bridge NSString *)propertyName;
    static NSArray<NSString *> *names;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        names = @[
            @"ChargeCurrentLimit",
            @"MaxChargeCurrent",
            @"AdapterPowerLimit",
            @"AdapterCurrentLimit",
            @"ChargingPowerLimit",
            @"ChargingCurrentLimit",
            @"USBPDCurrentLimit",
            @"USBPDPowerLimit"
        ];
    });
    for (NSString *name in names) {
        if ([s caseInsensitiveCompare:name] == NSOrderedSame ||
            [s rangeOfString:name options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

static kern_return_t hook_IORegistryEntrySetCFProperty(io_registry_entry_t entry,
                                                         CFStringRef propertyName,
                                                         CFTypeRef property) {
    if (gForceFastCharge && isFastChargeProperty(propertyName)) {
        return KERN_SUCCESS;
    }
    return orig_IORegistryEntrySetCFProperty
        ? orig_IORegistryEntrySetCFProperty(entry, propertyName, property)
        : KERN_FAILURE;
}

static kern_return_t hook_IOServiceSetCFProperty(io_service_t service,
                                                  CFStringRef propertyName,
                                                  CFTypeRef property) {
    if (gForceFastCharge && isFastChargeProperty(propertyName)) {
        return KERN_SUCCESS;
    }
    return orig_IOServiceSetCFProperty
        ? orig_IOServiceSetCFProperty(service, propertyName, property)
        : KERN_FAILURE;
}

static void updateChargeState(void) {
    BOOL enabled = readBoolPref(CFSTR("forceFastChargeEnable"), NO);
    if (enabled == gForceFastCharge) return;
    gForceFastCharge = enabled;
    NSLog(@"[SBCPUPowerd] fast-charge current-limit override: %@",
          enabled ? @"ON" : @"OFF");
}

static void installIOKitHooks(void) {
    void *handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW | RTLD_GLOBAL);
    if (!handle) {
        NSLog(@"[SBCPUPowerd] IOKit load failed");
        return;
    }

    void *p1 = dlsym(handle, "IORegistryEntrySetCFProperty");
    if (p1 && !orig_IORegistryEntrySetCFProperty) {
        MSHookFunction(p1, (void *)hook_IORegistryEntrySetCFProperty,
                       (void **)&orig_IORegistryEntrySetCFProperty);
    }

    void *p2 = dlsym(handle, "IOServiceSetCFProperty");
    if (p2 && !orig_IOServiceSetCFProperty) {
        MSHookFunction(p2, (void *)hook_IOServiceSetCFProperty,
                       (void **)&orig_IOServiceSetCFProperty);
    }

    gHookInstalled = (orig_IORegistryEntrySetCFProperty != NULL ||
                      orig_IOServiceSetCFProperty != NULL);
}

static void settingsChanged(CFNotificationCenterRef center,
                             void *observer,
                             CFNotificationName name,
                             const void *object,
                             CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    if (gHookInstalled) updateChargeState();
}

%ctor {
    @autoreleasepool {
        NSString *process = [NSProcessInfo processInfo].processName;
        if (![process isEqualToString:@"powerd"]) return;

        NSLog(@"[SBCPUPowerd] safe fast-charge helper starting");
        installIOKitHooks();
        if (!gHookInstalled) {
            NSLog(@"[SBCPUPowerd] no IOKit setter hooks installed");
            return;
        }

        CFPreferencesSetValue(kSBCPUPowerdReady, kCFBooleanTrue, kSBCPUPrefAppID,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        CFPreferencesAppSynchronize(kSBCPUPrefAppID);
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                              kSBCPUPowerdReadyNotification,
                                              NULL, NULL, YES);
        updateChargeState();

        CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();
        if (center) {
            CFNotificationCenterAddObserver(center, NULL, settingsChanged,
                                             kSBCPUSettingsChanged, NULL,
                                             CFNotificationSuspensionBehaviorDeliverImmediately);
        }

        dispatch_source_t timer = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
            dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        if (timer) {
            dispatch_source_set_timer(timer,
                                      dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                                      2 * NSEC_PER_SEC,
                                      300 * NSEC_PER_MSEC);
            dispatch_source_set_event_handler(timer, ^{
                if (gHookInstalled) updateChargeState();
            });
            dispatch_resume(timer);
        }
    }
}
