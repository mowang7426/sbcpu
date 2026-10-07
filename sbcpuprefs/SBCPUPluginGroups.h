#import <Foundation/Foundation.h>

// Display grouping only: preserve each scan record and never infer conflicts here.
static inline NSString *SBCPUPluginDisplayCategory(NSDictionary *plugin) {
    id value = plugin[@"category"];
    NSString *category = [value isKindOfClass:[NSString class]] ?
        [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : @"";
    return category.length ? category : @"其他";
}

static inline NSString *SBCPUPluginDisplayName(NSDictionary *plugin) {
    id value = plugin[@"name"];
    return [value isKindOfClass:[NSString class]] && [value length] ? value : @"未知插件";
}

static inline NSArray<NSDictionary *> *SBCPUPluginDisplayGroups(NSArray *plugins) {
    NSMutableDictionary<NSString *, NSMutableArray<NSDictionary *> *> *byCategory = [NSMutableDictionary dictionary];
    for (id entry in plugins) {
        if (![entry isKindOfClass:[NSDictionary class]]) continue;
        NSString *category = SBCPUPluginDisplayCategory(entry);
        if (!byCategory[category]) byCategory[category] = [NSMutableArray array];
        [byCategory[category] addObject:entry];
    }
    NSArray<NSString *> *preferredOrder = @[@"系统监控", @"充电管理", @"控制中心", @"主题美化", @"桌面",
        @"手势增强", @"通知中心", @"锁屏", @"浮窗", @"键盘", @"剪贴板", @"相机", @"截屏录屏",
        @"音乐音量", @"网络代理", @"应用修改", @"越狱工具"];
    NSArray<NSString *> *categories = [[byCategory allKeys] sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        if ([a isEqualToString:@"其他"]) return [b isEqualToString:@"其他"] ? NSOrderedSame : NSOrderedDescending;
        if ([b isEqualToString:@"其他"]) return NSOrderedAscending;
        NSUInteger first = [preferredOrder indexOfObject:a], second = [preferredOrder indexOfObject:b];
        if (first < second) return NSOrderedAscending;
        if (first > second) return NSOrderedDescending;
        return [a localizedStandardCompare:b];
    }];
    NSMutableArray<NSDictionary *> *groups = [NSMutableArray array];
    for (NSString *category in categories) {
        NSArray *members = [byCategory[category] sortedArrayWithOptions:NSSortStable usingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [SBCPUPluginDisplayName(a) localizedStandardCompare:SBCPUPluginDisplayName(b)];
        }];
        [groups addObject:@{@"category": category, @"plugins": members}];
    }
    return groups;
}
