#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

@interface SBCPUChargeHistoryController : PSListController
@end

@implementation SBCPUChargeHistoryController
- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *result = [NSMutableArray array];
        [result addObject:[PSSpecifier emptyGroupSpecifier]];
        NSData *data = [NSData dataWithContentsOfFile:@"/var/mobile/Library/Preferences/com.sbcpu.floating.charge-sessions.json"];
        id records = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![records isKindOfClass:[NSArray class]] || ![(NSArray *)records count]) {
            [result addObject:[PSSpecifier preferenceSpecifierNamed:@"暂无充电记录" target:nil set:NULL get:NULL detail:nil cell:PSStaticTextCell edit:nil]];
        } else {
            for (NSDictionary *record in (NSArray *)records) {
                if (![record isKindOfClass:[NSDictionary class]]) continue;
                NSString *title = [NSString stringWithFormat:@"%ld%% → %ld%%",
                                   [record[@"startPercent"] integerValue], [record[@"endPercent"] integerValue]];
                [result addObject:[PSSpecifier preferenceSpecifierNamed:title target:nil set:NULL get:NULL detail:nil cell:PSStaticTextCell edit:nil]];
            }
        }
        _specifiers = result;
    }
    return _specifiers;
}
- (void)viewDidLoad { [super viewDidLoad]; self.title = @"充电历史"; }
@end
