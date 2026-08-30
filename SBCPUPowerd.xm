#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <IOKit/IOKitLib.h>
#import <notify.h>
#import <dlfcn.h>
#import <substrate.h>

// SBCPUFloating preference domain，与 SpringBoard 设置页保持一致。
static CFStringRef const kSBCPUPrefAppID = CFSTR("com.yourname.sbcpufloating");
static CFStringRef const kSBCPUSettingsChanged = CFSTR("com.yourname.sbcpufloating/settingsChanged");

static BOOL gForceFastCharge = NO;
static BOOL gOriginalChargeLimitSaved = NO;
static int gOriginalChargeLimit = 100;
static int gLastAppliedChargeLimit = -1;
static int gNotifyToken = -1;
static BOOL gHookInstalled = NO;

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

static BOOL isProtectedChargeProperty(CFStringRef propertyName) {
    if (!propertyName) return NO;
    NSString *s = (__bridge NSString *)propertyName;
    // 只拦截 powerd 的充电降流/功率限制属性；不拦截无关 IOKit 属性。
    static NSArray<NSString *> *names;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        names = @[
            @"ChargeCurrentLimit",
            @"ThermalMaxChargeCurrent",
            @"MaxChargeCurrent",
            @"AdapterPowerLimit",
            @"AdapterCurrentLimit",
            @"ThermalChargingLimit",
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

typedef kern_return_t (*IORegistryEntrySetCFPropertyFn)(io_registry_entry_t, CFStringRef, CFTypeRef);
typedef kern_return_t (*IOServiceSetCFPropertyFn)(io_service_t, CFStringRef, CFTypeRef);

static IORegistryEntrySetCFPropertyFn orig_IORegistryEntrySetCFProperty = NULL;
static IOServiceSetCFPropertyFn orig_IOServiceSetCFProperty = NULL;

static void setChargeLimitUsingOriginal(int value) {
    if (!orig_IORegistryEntrySetCFProperty) return;
    io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault,
                                                         IOServiceMatching("AppleSmartBattery"));
    if (!service) return;

    CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &value);
    if (number) {
        kern_return_t kr = orig_IORegistryEntrySetCFProperty(service, CFSTR("ChargeLimit"), number);
        if (kr == KERN_SUCCESS) gLastAppliedChargeLimit = value;
        CFRelease(number);
    }
    IOObjectRelease(service);
}

static void updateChargeState(void) {
    BOOL enabled = readBoolPref(CFSTR("forceFastChargeEnable"), NO);
    if (enabled == gForceFastCharge) return;

    gForceFastCharge = enabled;
    NSLog(@"[SBCPUPowerd] 强制满血快充状态: %@", enabled ? @"开启" : @"关闭");

    if (enabled) {
        // 记录当前 ChargeLimit，只记录一次；然后将上限提升到 100。
        if (!gOriginalChargeLimitSaved && orig_IORegistryEntrySetCFProperty) {
            io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault,
                                                                 IOServiceMatching("AppleSmartBattery"));
            if (service) {
                CFTypeRef old = IORegistryEntryCreateCFProperty(service, CFSTR("ChargeLimit"),
                                                                 kCFAllocatorDefault, 0);
                if (old && CFGetTypeID(old) == CFNumberGetTypeID()) {
                    int n = 100;
                    if (CFNumberGetValue((CFNumberRef)old, kCFNumberIntType, &n)) {
                        gOriginalChargeLimit = n;
                        gOriginalChargeLimitSaved = YES;
                    }
                }
                if (old) CFRelease(old);
                IOObjectRelease(service);
            }
        }
        setChargeLimitUsingOriginal(100);
    } else {
        if (gOriginalChargeLimitSaved) {
            setChargeLimitUsingOriginal(gOriginalChargeLimit);
        }
        gOriginalChargeLimitSaved = NO;
        gLastAppliedChargeLimit = -1;
    }
}

static kern_return_t hook_IORegistryEntrySetCFProperty(io_registry_entry_t entry,
                                                         CFStringRef propertyName,
                                                         CFTypeRef property) {
    if (gForceFastCharge && isProtectedChargeProperty(propertyName)) {
        NSLog(@"[SBCPUPowerd] 拦截 powerd 充电降流: %@", (__bridge NSString *)propertyName);
        return KERN_SUCCESS;
    }
    return orig_IORegistryEntrySetCFProperty
        ? orig_IORegistryEntrySetCFProperty(entry, propertyName, property)
        : KERN_FAILURE;
}

static kern_return_t hook_IOServiceSetCFProperty(io_service_t service,
                                                  CFStringRef propertyName,
                                                  CFTypeRef property) {
    if (gForceFastCharge && isProtectedChargeProperty(propertyName)) {
        NSLog(@"[SBCPUPowerd] 拦截 powerd 充电服务降流: %@", (__bridge NSString *)propertyName);
        return KERN_SUCCESS;
    }
    return orig_IOServiceSetCFProperty
        ? orig_IOServiceSetCFProperty(service, propertyName, property)
        : KERN_FAILURE;
}

static void installIOKitHooks(void) {
    void *handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW | RTLD_GLOBAL);
    if (!handle) {
        NSLog(@"[SBCPUPowerd] IOKit 加载失败");
        return;
    }

    void *p1 = dlsym(handle, "IORegistryEntrySetCFProperty");
    if (p1 && !orig_IORegistryEntrySetCFProperty) {
        MSHookFunction(p1, (void *)hook_IORegistryEntrySetCFProperty,
                       (void **)&orig_IORegistryEntrySetCFProperty);
        if (orig_IORegistryEntrySetCFProperty) {
            NSLog(@"[SBCPUPowerd] IORegistryEntrySetCFProperty Hook 已安装");
        }
    }

    void *p2 = dlsym(handle, "IOServiceSetCFProperty");
    if (p2 && !orig_IOServiceSetCFProperty) {
        MSHookFunction(p2, (void *)hook_IOServiceSetCFProperty,
                       (void **)&orig_IOServiceSetCFProperty);
        if (orig_IOServiceSetCFProperty) {
            NSLog(@"[SBCPUPowerd] IOServiceSetCFProperty Hook 已安装");
        }
    }

    gHookInstalled = (orig_IORegistryEntrySetCFProperty != NULL || orig_IOServiceSetCFProperty != NULL);
}

static void settingsChanged(CFNotificationCenterRef center,
                             void *observer,
                             CFNotificationName name,
                             const void *object,
                             CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gHookInstalled) updateChargeState();
    });
}

%ctor {
    @autoreleasepool {
        NSString *process = [NSProcessInfo processInfo].processName;
        if (![process isEqualToString:@"powerd"]) return;

        NSLog(@"[SBCPUPowerd] V3.1.14 powerd 满血充电核心启动");
        installIOKitHooks();
        updateChargeState();

        CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();
        if (center) {
            CFNotificationCenterAddObserver(center, NULL, settingsChanged,
                                             kSBCPUSettingsChanged, NULL,
                                             CFNotificationSuspensionBehaviorDeliverImmediately);
        }

        // powerd 可能在设置变化时没有及时收到 Darwin 通知；低频兜底检查，避免影响正常电源管理。
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                           dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
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
