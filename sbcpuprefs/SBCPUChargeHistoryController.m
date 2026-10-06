#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

@interface SBCPUChargeHistoryController : PSListController
@property(nonatomic,copy) NSArray<NSDictionary *> *sessions;
@end

@implementation SBCPUChargeHistoryController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"充电历史";
    [self reloadHistory];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadHistory];
}

- (void)reloadHistory {
    NSData *data = [NSData dataWithContentsOfFile:@"/var/mobile/Library/Preferences/com.sbcpu.floating.charge-sessions.json"];
    id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    self.sessions = [value isKindOfClass:[NSArray class]] ? value : @[];
    _specifiers = nil;
    [self reloadSpecifiers];
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *items = [NSMutableArray array];
        [items addObject:[PSSpecifier groupSpecifierWithName:@"充电会话"]];
        if (!self.sessions.count) {
            [items addObject:[PSSpecifier preferenceSpecifierNamed:@"暂无已归档记录" target:nil set:NULL get:NULL detail:Nil cell:PSStaticTextCell edit:nil]];
            [items addObject:[PSSpecifier preferenceSpecifierNamed:@"充电期间会采样，拔下充电器后才会归档。记录功能需要 SpringBoard 中的 SBCPU 浮窗处于运行状态。" target:nil set:NULL get:NULL detail:Nil cell:PSStaticTextCell edit:nil]];
        } else {
            NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
            formatter.dateFormat = @"yyyy-MM-dd HH:mm";
            for (NSDictionary *session in self.sessions) {
                NSTimeInterval start = [session[@"start"] doubleValue];
                NSDate *date = [NSDate dateWithTimeIntervalSinceReferenceDate:start];
                NSInteger from = [session[@"startPercent"] integerValue];
                NSInteger to = [session[@"endPercent"] integerValue];
                double duration = [session[@"duration"] doubleValue];
                NSString *durationText = duration < 3600 ? [NSString stringWithFormat:@"%ld 分钟", (long)(duration / 60)] : [NSString stringWithFormat:@"%ld 小时 %ld 分钟", (long)(duration / 3600), (long)(((NSInteger)duration % 3600) / 60)];
                NSString *label = [NSString stringWithFormat:@"%@  ·  %@\n电量 %ld%% → %ld%%，输入 %.2f Wh，峰值 %.1f W%@", [formatter stringFromDate:date], durationText, (long)from, (long)to, [session[@"inputWh"] doubleValue], [session[@"peakInputW"] doubleValue], [session[@"wireless"] boolValue] ? @" · 无线" : @""];
                PSSpecifier *row = [PSSpecifier preferenceSpecifierNamed:label target:nil set:NULL get:NULL detail:Nil cell:PSStaticTextCell edit:nil];
                [items addObject:row];
            }
        }
        _specifiers = items;
    }
    return _specifiers;
}
@end
