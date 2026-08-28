static kern_return_t hook_IORegistryEntrySetCFProperty(io_registry_entry_t entry, CFStringRef propertyName, CFTypeRef property) {
    if (!propertyName) return orig_IORegistryEntrySetCFProperty(entry, propertyName, property);

    NSInteger mode = getRealTimeMitigationMode();
    BOOL blockDimming = getRealTimeBlockDimming();
    BOOL forceFastCharge = getRealTimeForceFastCharge();
    NSString *propStr = (__bridge NSString *)propertyName;
    
    // 拦截系统降亮度
    if (blockDimming) {
        if ([propStr containsString:@"max-brightness"] ||
            [propStr containsString:@"brightness-limit"] ||
            [propStr containsString:@"IOMFB_brightness_limit"] ||
            [propStr containsString:@"ThermalMitigation"] ||
            [propStr containsString:@"ThermalLimit"]) {
            return KERN_SUCCESS; 
        }
    }

    // 🔥 修复版强制快充：不丢弃指令，而是强行篡改数值为最大值！
    if (forceFastCharge) {
        // 1. 拦截电流限制，强行改写为 3000mA (3A)
        if ([propStr isEqualToString:@"ChargeCurrentLimit"] || 
            [propStr isEqualToString:@"ThermalMaxChargeCurrent"] ||
            [propStr isEqualToString:@"MaxChargeCurrent"] ||
            [propStr isEqualToString:@"ThermalChargingLimit"]) {
            
            int maxCurrent = 3500; // 强行设定 3.5A 最大电流
            CFNumberRef numRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &maxCurrent);
            kern_return_t res = orig_IORegistryEntrySetCFProperty(entry, propertyName, numRef);
            CFRelease(numRef);
            return res;
        }
        
        // 2. 拦截适配器功率限制，强行改写为 35 瓦
        if ([propStr isEqualToString:@"AdapterPowerLimit"] ||
            [propStr isEqualToString:@"AdapterCurrentLimit"]) {
            
            int maxPower = 35; // 强行设定 35W 功率上限
            CFNumberRef numRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &maxPower);
            kern_return_t res = orig_IORegistryEntrySetCFProperty(entry, propertyName, numRef);
            CFRelease(numRef);
            return res;
        }
    }

    if (mode == 1) { 
        if ([propStr isEqualToString:@"p-state-cap"] || [propStr isEqualToString:@"CPU_Ceiling"] || [propStr isEqualToString:@"CPU_Floor"]) {
            int val = 2;
            CFNumberRef numRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &val);
            kern_return_t res = orig_IORegistryEntrySetCFProperty(entry, propertyName, numRef);
            CFRelease(numRef);
            return res;
        }
    } 
    else if (mode == 2) { 
        if ([propStr isEqualToString:@"p-state-cap"] || [propStr isEqualToString:@"CPU_Ceiling"]) {
            int val = 15;
            CFNumberRef numRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &val);
            kern_return_t res = orig_IORegistryEntrySetCFProperty(entry, propertyName, numRef);
            CFRelease(numRef);
            return res;
        }
    }

    // 原路放行其他指令
    return orig_IORegistryEntrySetCFProperty(entry, propertyName, property);
}
