#ifndef SBCPU_THERMAL_DIAGNOSTICS_H
#define SBCPU_THERMAL_DIAGNOSTICS_H
#import <Foundation/Foundation.h>
#include <stdint.h>
#include <math.h>

// Pure reader policy; deliberately does not import the migrating preference reader.
static inline NSNumber *SBCDParseHeartbeat(NSData *data) {
    if (!data.length || data.length > 64) return nil;
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    text = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!text.length) return nil;
    uint64_t value = 0;
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if (c < '0' || c > '9' || value > (UINT64_MAX - (c - '0')) / 10) return nil;
        value = value * 10 + c - '0';
    }
    return value ? @(value) : nil;
}
static inline NSString *SBCDHeartbeatState(NSNumber *value, NSTimeInterval now) {
    if (!value) return @"missing";
    double seconds = value.doubleValue / 1000.0;
    if (!isfinite(seconds) || seconds <= 0) return @"malformed";
    if (seconds > now) return @"future";
    return now - seconds <= 15.0 ? @"recent" : @"stale";
}
static inline NSString *SBCDConfigValue(NSDictionary *prefs, NSString *key, BOOL readable) {
    if (!readable) return @"未知（配置不可读；不采用默认值冒充已保存）";
    id value = prefs[key];
    BOOL mode = [key isEqualToString:@"powerMode"];
    if (value && !(mode ? [value isKindOfClass:NSString.class] : [value isKindOfClass:NSNumber.class]))
        return @"未知（配置值类型异常）";
    if (mode) {
        NSString *text = value ?: @"fullPower";
        NSDictionary *names = @{@"fullPower": @"满频", @"lowPower": @"低功耗", @"extremeFull": @"极限满频"};
        return names[text] ? [names[text] stringByAppendingString:value ? @"（已保存）" : @"（缺省）"] : @"未知（模式值异常）";
    }
    BOOL defaultOn = ![@[@"thermalPreventDimmingEnabled", @"thermalBlockNotifPopup"] containsObject:key];
    return [NSString stringWithFormat:@"%@（%@）", (value ? [value boolValue] : defaultOn) ? @"开启" : @"关闭", value ? @"已保存" : @"缺省"];
}
// This is only a contradiction in cached reports, never proof of reload failure.
static inline BOOL SBCDConfigConflict(NSDictionary *prefs, BOOL readable, NSNumber *protection) {
    id master = prefs[@"thermalEngineEnabled"];
    return readable && [master isKindOfClass:NSNumber.class] && ![master boolValue] && protection.unsignedLongLongValue == 1;
}
#endif
