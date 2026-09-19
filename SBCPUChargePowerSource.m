// SBCPUChargePowerSource.m — IOPMPowerSource 事件监听实现
// iOS 标准模式：IONotificationPort + CFRunLoopSource 挂到 daemon 主 run loop。
// （IONotificationPortSetDispatchQueue 是 macOS API，iOS SDK 无声明）
// 事件驱动：不做每秒轮询；daemon 启动时主动触发一次当前电量判断。

#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include "SBCPUChargePowerSource.h"
#include "SBCPUChargeProtocol.h"

static SBCPUPowerEventCallback gCallback = NULL;
static IONotificationPortRef gNotifyPort = NULL;
static io_iterator_t gNotifyIter = MACH_PORT_NULL;
static CFRunLoopSourceRef gRunLoopSource = NULL;
static bool gMonitoring = false;

static double read_battery_temperature(io_service_t service) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(service, CFSTR("Temperature"), kCFAllocatorDefault, 0);
    double temperature = -1.0;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID()) {
        int raw = 0;
        CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &raw);
        if (raw > 1000) temperature = raw / 100.0;
        else if (raw > 200) temperature = raw / 10.0 - 273.15;
        else if (raw > 0) temperature = raw;
    }
    if (value) CFRelease(value);
    return temperature;
}

// 读电量百分比（0-100），失败返回 -1
int sb_power_read_percent(void) {
    io_service_t service = IOServiceGetMatchingService(0, IOServiceMatching("IOPMPowerSource"));
    if (service == IO_OBJECT_NULL) return -1;
    CFNumberRef cap = IORegistryEntryCreateCFProperty(service, CFSTR("CurrentCapacity"), kCFAllocatorDefault, 0);
    int val = -1;
    if (cap) {
        CFNumberGetValue(cap, kCFNumberIntType, &val);
        CFRelease(cap);
    }
    IOObjectRelease(service);
    return val;
}

bool sb_power_external_connected(void) {
    io_service_t service = IOServiceGetMatchingService(0, IOServiceMatching("IOPMPowerSource"));
    if (service == IO_OBJECT_NULL) return false;
    CFBooleanRef ext = IORegistryEntryCreateCFProperty(service, CFSTR("ExternalConnected"), kCFAllocatorDefault, 0);
    bool ok = false;
    if (ext && CFGetTypeID(ext) == CFBooleanGetTypeID())
        ok = CFBooleanGetValue(ext);
    if (ext) CFRelease(ext);
    IOObjectRelease(service);
    return ok;
}

// 无线充电检测：IOService "AppleSmartBattery" 的 AdapterInfo 端口字段 == 2
bool sb_power_wireless(void) {
    io_service_t service = IOServiceGetMatchingService(0, IOServiceMatching("AppleSmartBattery"));
    if (service == IO_OBJECT_NULL) return false;
    CFNumberRef info = IORegistryEntryCreateCFProperty(service, CFSTR("AdapterInfo"), kCFAllocatorDefault, 0);
    int val = -1;
    if (info) {
        CFNumberGetValue(info, kCFNumberIntType, &val);
        CFRelease(info);
    }
    IOObjectRelease(service);
    // AdapterInfo: 高字节端口号（2 = 无线充电）
    if (val < 0) return false;
    int port = (val >> 16) & 0xFF;
    return port == 2;
}

static void handle_service(io_service_t service) {
    if (!gCallback) return;
    int pct = -1;
    CFNumberRef cap = IORegistryEntryCreateCFProperty(service, CFSTR("CurrentCapacity"), kCFAllocatorDefault, 0);
    if (cap) {
        CFNumberGetValue(cap, kCFNumberIntType, &pct);
        CFRelease(cap);
    }
    if (pct < 0 || pct > 100) return;
    bool charging = false;
    CFBooleanRef ext = IORegistryEntryCreateCFProperty(service, CFSTR("ExternalConnected"), kCFAllocatorDefault, 0);
    if (ext) {
        if (CFGetTypeID(ext) == CFBooleanGetTypeID()) charging = CFBooleanGetValue(ext);
        CFRelease(ext);
    }
    gCallback(pct, charging, sb_power_wireless(), read_battery_temperature(service));
}

static void service_interest_cb(void *refcon, io_service_t service, uint32_t messageType, void *messageArgument) {
    (void)refcon; (void)messageArgument;
    // kIOPMMessageBatteryStatusHasChanged 等任何电池/电源事件都触发一次决策
    if (service == IO_OBJECT_NULL) return;
    handle_service(service);
}

static void match_cb(void *refcon, io_iterator_t iterator) {
    (void)refcon;
    io_service_t service;
    while ((service = IOIteratorNext(iterator))) {
        // 给每台电源设备挂 interest 通知（不强制转换，保持原生 4 参数签名）
        io_object_t notif = 0;
        kern_return_t kr = IOServiceAddInterestNotification(gNotifyPort, service,
            kIOGeneralInterest, service_interest_cb,
            NULL, &notif);
        if (kr != KERN_SUCCESS) {
            NSLog(@"[SBCPUChargePowerSource] IOServiceAddInterestNotification failed: 0x%08x", (unsigned)kr);
        }
        handle_service(service);
        IOObjectRelease(service);
    }
}

void sb_power_subscribe(SBCPUPowerEventCallback cb) {
    gCallback = cb;
    if (gMonitoring) return;

    gNotifyPort = IONotificationPortCreate(kIOMasterPortDefault);
    if (!gNotifyPort) {
        NSLog(@"[SBCPUChargePowerSource] IONotificationPortCreate failed");
        return;
    }

    kern_return_t kr = IOServiceAddMatchingNotification(gNotifyPort,
        kIOFirstMatchNotification,
        IOServiceMatching("IOPMPowerSource"),
        (IOServiceMatchingCallback)match_cb, NULL, &gNotifyIter);
    if (kr != KERN_SUCCESS) {
        NSLog(@"[SBCPUChargePowerSource] IOServiceAddMatchingNotification failed: 0x%08x", (unsigned)kr);
        IONotificationPortDestroy(gNotifyPort);
        gNotifyPort = NULL;
        return;
    }
    NSLog(@"[SBCPUChargePowerSource] IOPMPowerSource notification registered OK");
    // 立即处理当前已存在的电源设备（含首次电量）
    match_cb(NULL, gNotifyIter);
    gMonitoring = true;
}

// 把通知源挂到指定 run loop（daemon 主 run loop）；返回 source 供 CFRunLoopAddSource
CFRunLoopSourceRef sb_power_runloop_source(void) {
    if (gNotifyPort) {
        gRunLoopSource = IONotificationPortGetRunLoopSource(gNotifyPort);
    }
    if (!gRunLoopSource) {
        NSLog(@"[SBCPUChargePowerSource] runloop source unavailable (port=%p); will use poll watchdog",
              (void *)gNotifyPort);
    }
    return gRunLoopSource;
}

void sb_power_poll_once(void) {
    io_service_t service = IOServiceGetMatchingService(0, IOServiceMatching("IOPMPowerSource"));
    if (service == IO_OBJECT_NULL) return;
    int pct = -1;
    CFNumberRef cap = IORegistryEntryCreateCFProperty(service, CFSTR("CurrentCapacity"), kCFAllocatorDefault, 0);
    if (cap) { CFNumberGetValue(cap, kCFNumberIntType, &pct); CFRelease(cap); }
    bool charging = false;
    CFBooleanRef ext = IORegistryEntryCreateCFProperty(service, CFSTR("ExternalConnected"), kCFAllocatorDefault, 0);
    if (ext && CFGetTypeID(ext) == CFBooleanGetTypeID()) charging = CFBooleanGetValue(ext);
    if (ext) CFRelease(ext);
    double temperature = read_battery_temperature(service);
    IOObjectRelease(service);
    if (pct >= 0 && gCallback) gCallback(pct, charging, sb_power_wireless(), temperature);
}
