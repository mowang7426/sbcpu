
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
// 智能停充（powerd 进程内执行，避免被 SpringBoard 设置覆盖）
static BOOL gSmartChargeEnable = NO;
static int gSmartChargeUpperLimit = 80;
static int gSmartChargeLowerLimit = 70;
static BOOL gSmartChargeStopped = NO;
static BOOL gSmartChargeActive = NO; // 智能停充激活标志：停充时hook读取返回停充状态
static int gOriginalChargeLimit = 100;
static BOOL gHookInstalled = NO;

static int readIntPref(CFStringRef key, int fallback) {
    CFPreferencesAppSynchronize(kSBCPUPrefAppID);
    CFPropertyListRef v = CFPreferencesCopyValue(key, kSBCPUPrefAppID,
                                                   kCFPreferencesCurrentUser,
                                                   kCFPreferencesAnyHost);
    if (!v) return fallback;
    int result = fallback;
    if (CFGetTypeID(v) == CFNumberGetTypeID()) {
        CFNumberGetValue((CFNumberRef)v, kCFNumberIntType, &result);
    }
    CFRelease(v);
    return result;
}
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

// 智能停充：参考 CPUthermal BatteryTempBypass.xm 实现
// 同时操作 AppleSmartBatteryManager + AppleSmartBattery，设置4个充电抑制属性
static void applySmartChargeState(BOOL stopped) {
    gSmartChargeActive = stopped; // 设置停充激活标志，hook读取时返回停充状态
    CFTypeRef boolVal = stopped ? kCFBooleanTrue : kCFBooleanFalse;
    NSDictionary *props = @{
        @"ChargeInhibit": @(stopped),
        @"ChargeBlocked": @(stopped),
        @"ChargingPaused": @(stopped),
        @"PredictiveChargingInhibit": @(stopped)
    };

    // 1. 操作 AppleSmartBatteryManager（充电管理器，核心）
    io_service_t manager = IOServiceGetMatchingService(kIOMasterPortDefault,
                                                         IOServiceMatching("AppleSmartBatteryManager"));
    if (manager != IO_OBJECT_NULL) {
        if (orig_IORegistryEntrySetCFProperty) {
            orig_IORegistryEntrySetCFProperty(manager, CFSTR("ChargeInhibit"), boolVal);
            orig_IORegistryEntrySetCFProperty(manager, CFSTR("ChargeBlocked"), boolVal);
            orig_IORegistryEntrySetCFProperty(manager, CFSTR("ChargingPaused"), boolVal);
        }
        IOObjectRelease(manager);
    }

    // 2. 操作 AppleSmartBattery（电池服务）
    io_service_t battery = IOServiceGetMatchingService(kIOMasterPortDefault,
                                                         IOServiceMatching("AppleSmartBattery"));
    if (battery != IO_OBJECT_NULL) {
        // 批量写入（复数API，更可靠）
        IORegistryEntrySetCFProperties(battery, (__bridge CFTypeRef)props);
        IOObjectRelease(battery);
    }

    // 3. ChargeLimit 单独设置
    if (orig_IORegistryEntrySetCFProperty) {
        io_service_t bat2 = IOServiceGetMatchingService(kIOMasterPortDefault,
                                                          IOServiceMatching("AppleSmartBattery"));
        if (bat2 != IO_OBJECT_NULL) {
            int limit = stopped ? (int)gSmartChargeUpperLimit : 100;
            CFNumberRef num = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &limit);
            if (num) {
                orig_IORegistryEntrySetCFProperty(bat2, CFSTR("ChargeLimit"), num);
                CFRelease(num);
            }
            IOObjectRelease(bat2);
        }
    }
}

// 智能停充：读取真实电量百分比（用 orig 函数，避免被伪装）
static int getRealBatteryPercentPowerd(void) {
    if (!orig_IORegistryEntryCreateCFProperty) return -1;
    io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault,
                                                         IOServiceMatching("AppleSmartBattery"));
    if (!service) return -1;
    int percent = -1, curCap = 0, maxCap = 0;
    CFTypeRef curVal = orig_IORegistryEntryCreateCFProperty(service, CFSTR("AppleRawCurrentCapacity"), kCFAllocatorDefault, 0);
    if (!curVal) curVal = orig_IORegistryEntryCreateCFProperty(service, CFSTR("CurrentCapacity"), kCFAllocatorDefault, 0);
    if (curVal && CFGetTypeID(curVal) == CFNumberGetTypeID()) CFNumberGetValue((CFNumberRef)curVal, kCFNumberIntType, &curCap);
    if (curVal) CFRelease(curVal);
    CFTypeRef maxVal = orig_IORegistryEntryCreateCFProperty(service, CFSTR("AppleRawMaxCapacity"), kCFAllocatorDefault, 0);
    if (!maxVal) maxVal = orig_IORegistryEntryCreateCFProperty(service, CFSTR("MaxCapacity"), kCFAllocatorDefault, 0);
    if (!maxVal) maxVal = orig_IORegistryEntryCreateCFProperty(service, CFSTR("NominalChargeCapacity"), kCFAllocatorDefault, 0);
    if (maxVal && CFGetTypeID(maxVal) == CFNumberGetTypeID()) CFNumberGetValue((CFNumberRef)maxVal, kCFNumberIntType, &maxCap);
    if (maxVal) CFRelease(maxVal);
    if (maxCap > 0 && curCap > 0) percent = (int)(curCap * 100.0 / maxCap);
    else if (curCap > 0 && curCap <= 100) percent = curCap;
    IOObjectRelease(service);
    return percent;
}

// 智能停充：检测是否正在充电（用 orig 函数）
static BOOL isChargingPowerd(void) {
    if (!orig_IORegistryEntryCreateCFProperty) return NO;
    io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault,
                                                         IOServiceMatching("AppleSmartBattery"));
    if (!service) return NO;
    BOOL charging = NO;
    CFTypeRef val = orig_IORegistryEntryCreateCFProperty(service, CFSTR("IsCharging"), kCFAllocatorDefault, 0);
    if (val && CFGetTypeID(val) == CFBooleanGetTypeID()) charging = CFBooleanGetValue((CFBooleanRef)val);
    if (val) CFRelease(val);
    IOObjectRelease(service);
    return charging;
}

// 智能停充：把停充状态写入偏好，供 Tweak.xm 读取显示
static void writeSmartChargeStoppedState(BOOL stopped) {
    CFPreferencesSetValue(CFSTR("smartChargeStopped"), stopped ? kCFBooleanTrue : kCFBooleanFalse,
                          kSBCPUPrefAppID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPreferencesAppSynchronize(kSBCPUPrefAppID);
}

static void updateChargeState(void) {
    // === 智能停充逻辑（powerd 进程内执行，每次都检测）===
    BOOL scEnable = readBoolPref(CFSTR("smartChargeEnable"), NO);
    int scUpper = readIntPref(CFSTR("smartChargeUpperLimit"), 80);
    int scLower = readIntPref(CFSTR("smartChargeLowerLimit"), 70);
    gSmartChargeEnable = scEnable;
    gSmartChargeUpperLimit = scUpper;
    gSmartChargeLowerLimit = scLower;

    if (scEnable) {
        int percent = getRealBatteryPercentPowerd();
        BOOL charging = isChargingPowerd();
        if (charging && percent >= 0) {
            if (!gSmartChargeStopped && percent >= scUpper) {
                applySmartChargeState(YES);
                gSmartChargeStopped = YES;
                writeSmartChargeStoppedState(YES);
                NSLog(@"[SBCPUPowerd] 智能停充触发: %d%% >= %d%%", percent, scUpper);
            } else if (gSmartChargeStopped && percent <= scLower) {
                applySmartChargeState(NO);
                gSmartChargeStopped = NO;
                writeSmartChargeStoppedState(NO);
                NSLog(@"[SBCPUPowerd] 智能停充恢复: %d%% <= %d%%", percent, scLower);
            }
        } else if (!charging && gSmartChargeStopped) {
            applySmartChargeState(NO);
            gSmartChargeStopped = NO;
            writeSmartChargeStoppedState(NO);
        }
    } else if (gSmartChargeStopped) {
        applySmartChargeState(NO);
        gSmartChargeStopped = NO;
        writeSmartChargeStoppedState(NO);
    }

    // 关键：停充状态下每2秒重新设置一次抑制位，抵消powerd周期性清除
    if (gSmartChargeStopped) {
        applySmartChargeState(YES);
    }

    // 停充时跳过快充逻辑，避免冲突
    if (gSmartChargeStopped) return;

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

// 🔥 [极致激进版] 欺骗系统读取操作：温度/容量/电压/循环/健康度全伪装
static CFTypeRef hook_IORegistryEntryCreateCFProperty(io_registry_entry_t entry,
                                                      CFStringRef key,
                                                      CFAllocatorRef allocator,
                                                      IOOptionBits options) {
    CFTypeRef result = orig_IORegistryEntryCreateCFProperty(entry, key, allocator, options);

    // 🔥 智能停充激活时：hook读取返回停充状态，让powerd自己认为应该停止充电
    if (gSmartChargeActive && key && result) {
        NSString *keyStr = (__bridge NSString *)key;
        // 充电抑制属性返回 true
        if ([keyStr isEqualToString:@"ChargeInhibit"] ||
            [keyStr isEqualToString:@"ChargeBlocked"] ||
            [keyStr isEqualToString:@"ChargingPaused"] ||
            [keyStr isEqualToString:@"PredictiveChargingInhibit"]) {
            if (CFGetTypeID(result) == CFBooleanGetTypeID()) {
                CFRelease(result);
                return CFRetain(kCFBooleanTrue);
            }
        }
        // 最大充电电流返回 0（即使充电也没有电流）
        if ([keyStr isEqualToString:@"MaxChargeCurrent"] ||
            [keyStr isEqualToString:@"ChargeCurrentLimit"] ||
            [keyStr isEqualToString:@"ChargingCurrent"] ||
            [keyStr isEqualToString:@"ChargeCurrent"] ||
            [keyStr isEqualToString:@"MaxChargingCurrent"] ||
            [keyStr isEqualToString:@"ThermalMaxChargeCurrent"]) {
            if (CFGetTypeID(result) == CFNumberGetTypeID()) {
                int zero = 0;
                CFNumberRef fakeNum = CFNumberCreate(allocator, kCFNumberIntType, &zero);
                CFRelease(result);
                return fakeNum;
            }
        }
        // 已充满返回 true
        if ([keyStr isEqualToString:@"FullyCharged"]) {
            if (CFGetTypeID(result) == CFBooleanGetTypeID()) {
                CFRelease(result);
                return CFRetain(kCFBooleanTrue);
            }
        }
        // 外部可充电返回 false
        if ([keyStr isEqualToString:@"ExternalChargeCapable"]) {
            if (CFGetTypeID(result) == CFBooleanGetTypeID()) {
                CFRelease(result);
                return CFRetain(kCFBooleanFalse);
            }
        }
        return result;
    }

    if (gForceFastCharge && !gSmartChargeStopped && key && result) {
        NSString *keyStr = (__bridge NSString *)key;

        // 1. 伪装电池温度永远 25°C（单位 0.1度=250），废掉高温降流
        if ([keyStr isEqualToString:@"Temperature"] || [keyStr isEqualToString:@"BatteryTemperature"]) {
            if (CFGetTypeID(result) == CFNumberGetTypeID()) {
                int fakeTemp = 250;
                CFNumberRef fakeNum = CFNumberCreate(allocator, kCFNumberIntType, &fakeTemp);
                CFRelease(result);
                return fakeNum;
            }
        }

        // 2. 伪装当前容量：真实电量 >50% 就伪装成 45%（基于百分比计算，兼容 mAh 单位）
        if ([keyStr isEqualToString:@"CurrentCapacity"] || [keyStr isEqualToString:@"AppleRawCurrentCapacity"]) {
            if (CFGetTypeID(result) == CFNumberGetTypeID()) {
                int realCap = 0;
                if (CFNumberGetValue((CFNumberRef)result, kCFNumberIntType, &realCap)) {
                    // 尝试读取 MaxCapacity 计算百分比
                    int maxCap = 0;
                    CFTypeRef maxVal = orig_IORegistryEntryCreateCFProperty(entry, CFSTR("AppleRawMaxCapacity"), kCFAllocatorDefault, 0);
                    if (!maxVal) maxVal = orig_IORegistryEntryCreateCFProperty(entry, CFSTR("MaxCapacity"), kCFAllocatorDefault, 0);
                    if (maxVal && CFGetTypeID(maxVal) == CFNumberGetTypeID()) {
                        CFNumberGetValue((CFNumberRef)maxVal, kCFNumberIntType, &maxCap);
                    }
                    if (maxVal) CFRelease(maxVal);

                    if (maxCap > 0) {
                        // mAh 单位：计算百分比
                        int percent = (int)(realCap * 100.0 / maxCap);
                        if (percent > 50) {
                            int fakeCap = (int)(maxCap * 0.45); // 伪装成 45%
                            CFNumberRef fakeNum = CFNumberCreate(allocator, kCFNumberIntType, &fakeCap);
                            CFRelease(result);
                            return fakeNum;
                        }
                    } else {
                        // 百分比单位：直接比较
                        if (realCap > 50) {
                            int fakeCap = 45;
                            CFNumberRef fakeNum = CFNumberCreate(allocator, kCFNumberIntType, &fakeCap);
                            CFRelease(result);
                            return fakeNum;
                        }
                    }
                }
            }
        }

        // 3. 伪装电压：>4000mV 伪装成 3900mV，让系统认为还没到恒压涓流阶段
        if ([keyStr isEqualToString:@"Voltage"] || [keyStr isEqualToString:@"BatteryVoltage"]) {
            if (CFGetTypeID(result) == CFNumberGetTypeID()) {
                int realVolt = 0;
                if (CFNumberGetValue((CFNumberRef)result, kCFNumberIntType, &realVolt)) {
                    if (realVolt > 4000) {
                        int fakeVolt = 3900;
                        CFNumberRef fakeNum = CFNumberCreate(allocator, kCFNumberIntType, &fakeVolt);
                        CFRelease(result);
                        return fakeNum;
                    }
                }
            }
        }

        // 4. 伪装循环次数为 0，让系统认为电池全新，不会因老化降流
        if ([keyStr isEqualToString:@"CycleCount"] || [keyStr isEqualToString:@"AppleRawCycleCount"]) {
            if (CFGetTypeID(result) == CFNumberGetTypeID()) {
                int fakeCycle = 0;
                CFNumberRef fakeNum = CFNumberCreate(allocator, kCFNumberIntType, &fakeCycle);
                CFRelease(result);
                return fakeNum;
            }
        }

        // 5. 伪装最大容量 = 设计容量，让系统认为健康度 100%
        if ([keyStr isEqualToString:@"AppleRawMaxCapacity"] || [keyStr isEqualToString:@"MaxCapacity"] || [keyStr isEqualToString:@"NominalChargeCapacity"]) {
            if (CFGetTypeID(result) == CFNumberGetTypeID()) {
                int realMax = 0;
                if (CFNumberGetValue((CFNumberRef)result, kCFNumberIntType, &realMax)) {
                    // 读取设计容量
                    int designCap = 0;
                    CFTypeRef designVal = orig_IORegistryEntryCreateCFProperty(entry, CFSTR("DesignCapacity"), kCFAllocatorDefault, 0);
                    if (designVal && CFGetTypeID(designVal) == CFNumberGetTypeID()) {
                        CFNumberGetValue((CFNumberRef)designVal, kCFNumberIntType, &designCap);
                    }
                    if (designVal) CFRelease(designVal);
                    if (designCap > 0 && realMax < designCap) {
                        CFNumberRef fakeNum = CFNumberCreate(allocator, kCFNumberIntType, &designCap);
                        CFRelease(result);
                        return fakeNum;
                    }
                }
            }
        }

        // 6. 伪装未充满：永远 NO
        if ([keyStr isEqualToString:@"FullyCharged"]) {
            if (CFGetTypeID(result) == CFBooleanGetTypeID()) {
                CFRelease(result);
                return kCFBooleanFalse;
            }
        }

        // 7. 伪装非临界/非警告
        if ([keyStr isEqualToString:@"AtCriticalLevel"] || [keyStr isEqualToString:@"AtWarnLevel"]) {
            if (CFGetTypeID(result) == CFBooleanGetTypeID()) {
                CFRelease(result);
                return kCFBooleanFalse;
            }
        }

        // 8. 伪装外部可充电 = YES
        if ([keyStr isEqualToString:@"ExternalChargeCapable"]) {
            if (CFGetTypeID(result) == CFBooleanGetTypeID()) {
                CFRelease(result);
                return kCFBooleanTrue;
            }
        }
    }
    return result;
}

static kern_return_t hook_IORegistryEntrySetCFProperty(io_registry_entry_t entry,
                                                         CFStringRef propertyName,
                                                         CFTypeRef property) {
    if (gForceFastCharge && isProtectedChargeProperty(propertyName)) {
        return KERN_SUCCESS;
    }
    // 智能停充已停充时，拦截 powerd 对所有停充相关属性的覆盖
    if (gSmartChargeStopped && propertyName) {
        NSString *s = (__bridge NSString *)propertyName;
        if ([s isEqualToString:@"ChargeLimit"] || [s isEqualToString:@"ChargeInhibit"] ||
            [s isEqualToString:@"ChargeBlocked"] || [s isEqualToString:@"ChargingPaused"] ||
            [s isEqualToString:@"PredictiveChargingInhibit"] ||
            [s isEqualToString:@"ExternalChargeCapable"] ||
            [s isEqualToString:@"BatteryChargeOverride"] ||
            [s isEqualToString:@"MaxChargeCurrent"] ||
            [s isEqualToString:@"ChargeCurrentLimit"] ||
            [s isEqualToString:@"ChargingCurrent"] ||
            [s isEqualToString:@"ChargeCurrent"] ||
            [s isEqualToString:@"MaxChargingCurrent"] ||
            [s isEqualToString:@"FullyCharged"]) {
            return KERN_SUCCESS;
        }
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

