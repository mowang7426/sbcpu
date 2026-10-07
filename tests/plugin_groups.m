#import <Foundation/Foundation.h>
#import <stdio.h>
#import <stdlib.h>
#import "../sbcpuprefs/SBCPUPluginGroups.h"

static void Require(BOOL condition, NSString *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

int main(void) {
    @autoreleasepool {
        Require(SBCPUPluginDisplayGroups(@[]).count == 0, @"Empty scan must show no groups");
        Require(SBCPUPluginDisplayGroups(nil).count == 0, @"Nil scan must show no groups");
        NSDictionary *theme10 = @{@"name": @"Plugin10", @"category": @"主题美化"};
        NSDictionary *theme2 = @{@"name": @"Plugin2", @"category": @"主题美化", @"injectedBundles": @[@"SpringBoard"]};
        NSArray *records = @[
            theme10, @{@"name": @"CPU", @"category": @"系统监控"}, theme2, theme2,
            @{@"name": @"Missing"}, @{@"name": @"Empty", @"category": @" \n"},
            @{@"name": @"Invalid", @"category": @42},
            @{@"name": @"Future", @"category": @"自定义类型"},
            @{@"name": @"Trimmed", @"category": @" 系统监控\n"}
        ];
        NSMutableArray *input = [records mutableCopy];
        [input addObject:@"malformed record"];
        [input addObject:[NSNull null]];
        NSArray *before = [input copy];
        NSArray<NSDictionary *> *groups = SBCPUPluginDisplayGroups(input);
        Require(groups.count == 4, @"Only populated categories should be shown");
        Require([groups[0][@"category"] isEqual:@"系统监控"], @"Known category priority");
        Require([groups[1][@"category"] isEqual:@"主题美化"], @"Known categories precede future categories");
        Require([groups[2][@"category"] isEqual:@"自定义类型"], @"Future category must be preserved");
        Require([groups.lastObject[@"category"] isEqual:@"其他"], @"Other must always be last");
        NSArray *theme = groups[1][@"plugins"];
        Require(theme.count == 3, @"Never deduplicate same-name plugin records");
        Require(theme[0] == theme2 && theme[1] == theme2 && theme[2] == theme10, @"Natural name order and full record identity");
        Require([groups[0][@"plugins"] count] == 2, @"Trim category whitespace");
        Require([groups.lastObject[@"plugins"] count] == 3, @"Missing, blank and non-string category fallback");
        NSMutableArray *flattened = [NSMutableArray array];
        for (NSDictionary *group in groups) [flattened addObjectsFromArray:group[@"plugins"]];
        Require(flattened.count == records.count, @"Every valid record must appear once");
        NSCountedSet *expected = [[NSCountedSet alloc] initWithArray:records];
        NSCountedSet *actual = [[NSCountedSet alloc] initWithArray:flattened];
        for (id record in expected) Require([actual countForObject:record] == [expected countForObject:record], @"Record multiplicity must be preserved");
        Require([input isEqual:before], @"Grouping must not mutate scan results");
        Require([SBCPUPluginDisplayName(@{@"name": [NSNull null]}) isEqual:@"未知插件"], @"Invalid name fallback");
        printf("plugin grouping regression tests passed\n");
    }
    return 0;
}
