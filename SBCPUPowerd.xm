
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <IOKit/IOKitLib.h>
#import <notify.h>
#import <dlfcn.h>
#import <substrate.h>

// SBCPUFloating preference domain，与 SpringBoard 设置页保持一致。
static CFStringRef const kSBCPUPrefAppID = CFSTR("com.yourname.sbcpufloating");
static CFStringRef const kSBCPUSettingsChanged = CFSTR("com.yourname.sbcpufloating/settingsChanged");
static CFStringRef const kSBCPUPowerdReady = CFSTR("powerdHookReady");
static CFStringRef const kSBCPUPowerdReadyNotification = CFSTR("com.yourname.sbcpufloating/powerdHookReady");

static BOOL gForceFastCharge = NO;
static BOOL gOriginalChargeLimitSaved = NO;
static int gOriginalChargeLimit = 100;
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
    
    // 🔥 [激进升级] 扩充拦截词库，加入涓流、步进和底层热限制
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
            @"USBPDPowerLimit",
            @"Trickle",              // 拦截涓流充电
            @"StepCharging",         // 拦截步进式充电降流
            @"AICLLimit",            // 拦截适配器防抖降流
            @"USBChargeCurrent",     // 拦截USB默认限流
            @"ChargingVoltageLimit",  // 拦截恒压限制
            @"ChargeInhibit",        // 拦截充电抑制
            @"ForceDischarge",       // 拦截强制放电
            @"BatteryChargeOverride",// 拦截电池充电覆盖
            @"MinChargeCurrent",     // 拦截最小充电电流限制
            @"SafeChargeCurrent",    // 拦截安全充电电流限制
            @"ChargingCurrent",      // 拦截充电电流设置
            @"ChargeCurrent",        // 拦截充电电流
            @"BatterySafeCharge",    // 拦截电池安全充电
            @"ThermalChargeLimit",   // 拦截热充电限制
            @"ChargeVoltageLimit",   // 拦截充电电压限制
            @"MaxChargingCurrent",   // 拦截最大充电电流
            @"AppleSmartBatteryChargeLimit" // 拦截苹果智能电池充电限制
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
// 🔥 新增：用于拦截系统读取电池属性
typedef CFTypeRef (*IORegistryEntryCreateCFPropertyFn)(io_registry_entry_t, CFStringRef, CFAllocatorRef, IOOptionBits);

static IORegistryEntrySetCFPropertyFn orig_IORegistryEntrySetCFProperty = NULL;
static IOServiceSetCFPropertyFn orig_IOServiceSetCFProperty = NULL;
static IORegistryEntryCreateCFPropertyFn orig_IORegistryEntryCreateCFProperty = NULL;

static void setChargeLimitUsingOriginal(int value) {
    if (!orig_IORegistryEntrySetCFProperty) return;
    io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault,
                                                         IOServiceMatching("AppleSmartBattery"));
    if (!service) return;

    CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &value);
    if (number) {
        orig_IORegistryEntrySetCFProperty(service, CFSTR("ChargeLimit"), number);
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
        // 直接索要最高上限
        setChargeLimitUsingOriginal(100);
    } else {
        if (gOriginalChargeLimitSaved) {
            setChargeLimitUsingOriginal(gOriginalChargeLimit);
        }
        gOriginalChargeLimitSaved = NO;
    }
}

// 🔥 [激进升级] 欺骗系统读取操作 (温度伪装)
static CFTypeRef hook_IORegistryEntryCreateCFProperty(io_registry_entry_t entry, 
                                                      CFStringRef key, 
                                                      CFAllocatorRef allocator, 
                                                      IOOptionBits options) {
    CFTypeRef result = orig_IORegistryEntryCreateCFProperty(entry, key, allocator, options);
    
    if (gForceFastCharge && key && result) {
        NSString *keyStr = (__bridge NSString *)key;
        
        // 伪装电池温度永远在 25°C (AppleSmartBattery 中温度单位通常为 0.1度，即 250)
        // 这将彻底废掉 thermalmonitord 基于电池温度的降频保护
        if ([keyStr isEqualToString:@"Temperature"] || [keyStr isEqualToString:@"BatteryTemperature"]) {
            if (CFGetTypeID(result) == CFNumberGetTypeID()) {
                int fakeTemp = 250;
                CFNumberRef fakeNum = CFNumberCreate(allocator, kCFNumberIntType, &fakeTemp);
                CFRelease(result);
                return fakeNum;
            }
        }

        // 🔥 伪装当前容量：真实电量 >75% 时伪装成 70%，让 powerd 认为还在快速充电阶段，避免 80% 后涓流
        if ([keyStr isEqualToString:@"CurrentCapacity"] || [keyStr isEqualToString:@"AppleRawCurrentCapacity"]) {
            if (CFGetTypeID(result) == CFNumberGetTypeID()) {
                int realCap = 0;
                if (CFNumberGetValue((CFNumberRef)result, kCFNumberIntType, &realCap)) {
                    if (realCap > 75) {
                        int fakeCap = 70; // 伪装成 70%，永远不到 80% 涓流阈值
                        CFNumberRef fakeNum = CFNumberCreate(allocator, kCFNumberIntType, &fakeCap);
                        CFRelease(result);
                        return fakeNum;
                    }
                }
            }
        }

        // 🔥 伪装未充满：永远返回 NO，让系统认为电池还没充满，继续充电
        if ([keyStr isEqualToString:@"FullyCharged"]) {
            if (CFGetTypeID(result) == CFBooleanGetTypeID()) {
                CFRelease(result);
                return kCFBooleanFalse;
            }
        }

        // 🔥 伪装非临界/非警告电量，避免系统因为电量状态触发降流
        if ([keyStr isEqualToString:@"AtCriticalLevel"] || [keyStr isEqualToString:@"AtWarnLevel"]) {
            if (CFGetTypeID(result) == CFBooleanGetTypeID()) {
                CFRelease(result);
                return kCFBooleanFalse;
            }
        }
    }
    return result;
}

static kern_return_t hook_IORegistryEntrySetCFProperty(io_registry_entry_t entry,
                                                         CFStringRef propertyName,
                                                         CFTypeRef property) {
    if (gForceFastCharge && isProtectedChargeProperty(propertyName)) {
        // NSLog(@"[SBCPUPowerd] 拦截 powerd 充电降流: %@", (__bridge NSString *)propertyName);
        return KERN_SUCCESS; // 直接吞掉指令
    }
    return orig_IORegistryEntrySetCFProperty
        ? orig_IORegistryEntrySetCFProperty(entry, propertyName, property)
        : KERN_FAILURE;
}

static kern_return_t hook_IOServiceSetCFProperty(io_service_t service,
                                                  CFStringRef propertyName,
                                                  CFTypeRef property) {
    if (gForceFastCharge && isProtectedChargeProperty(propertyName)) {
        // NSLog(@"[SBCPUPowerd] 拦截 powerd 充电服务降流: %@", (__bridge NSString *)propertyName);
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
    }

    void *p2 = dlsym(handle, "IOServiceSetCFProperty");
    if (p2 && !orig_IOServiceSetCFProperty) {
        MSHookFunction(p2, (void *)hook_IOServiceSetCFProperty,
                       (void **)&orig_IOServiceSetCFProperty);
    }

    // 🔥 挂钩属性读取接口，实现硬件欺骗
    void *p3 = dlsym(handle, "IORegistryEntryCreateCFProperty");
    if (p3 && !orig_IORegistryEntryCreateCFProperty) {
        MSHookFunction(p3, (void *)hook_IORegistryEntryCreateCFProperty,
                       (void **)&orig_IORegistryEntryCreateCFProperty);
    }

    gHookInstalled = (orig_IORegistryEntrySetCFProperty != NULL || orig_IOServiceSetCFProperty != NULL);
}

static void settingsChanged(CFNotificationCenterRef center,
                             void *observer,
                             CFNotificationName name,
                             const void *object,
                             CFDictionaryRef userInfo) {
    (void)center;
    (void)observer;
    (void)name;
    (void)object;
    (void)userInfo;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gHookInstalled) updateChargeState();
    });
}

%ctor {
    @autoreleasepool {
        NSString *process = [NSProcessInfo processInfo].processName;
        if (![process isEqualToString:@"powerd"]) return;

        NSLog(@"[SBCPUPowerd] V4.0.0 极致满血版核心启动");
        installIOKitHooks();
        if (gHookInstalled) {
            CFPreferencesSetValue(kSBCPUPowerdReady, kCFBooleanTrue, kSBCPUPrefAppID,
                                  kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
            CFPreferencesAppSynchronize(kSBCPUPrefAppID);
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                                  kSBCPUPowerdReadyNotification,
                                                  NULL, NULL, YES);
            NSLog(@"[SBCPUPowerd] powerd Hook 已就绪");
        }
        updateChargeState();

        CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();
        if (center) {
            CFNotificationCenterAddObserver(center, NULL, settingsChanged,
                                             kSBCPUSettingsChanged, NULL,
                                             CFNotificationSuspensionBehaviorDeliverImmediately);
        }

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

