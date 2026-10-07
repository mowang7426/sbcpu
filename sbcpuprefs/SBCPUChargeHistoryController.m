#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

@interface SBCPUChargeHistoryController : PSListController
@property(nonatomic,copy) NSArray<NSDictionary *> *sessions;
@end

@implementation SBCPUChargeHistoryController

- (void)showSessionDetails:(PSSpecifier *)specifier {
    NSDictionary *session = [specifier propertyForKey:@"SBCPUChargeSession"];
    if (![session isKindOfClass:[NSDictionary class]]) return;
    NSTimeInterval duration = [session[@"duration"] doubleValue];
    NSString *message = [NSString stringWithFormat:@"时长：%.0f 分钟\n电量：%@%% → %@%%\n充入电量：%.0f mAh\n输入能量：%.2f Wh\n电池吸收能量：%.2f Wh\n峰值输入功率：%.1f W\n峰值电池功率：%.1f W\n峰值电池温度：%@\n充电方式：%@\n热降频：%@ 秒", duration / 60.0, session[@"startPercent"] ?: @0, session[@"endPercent"] ?: @0, [session[@"batteryMah"] doubleValue], [session[@"inputWh"] doubleValue], [session[@"batteryWh"] doubleValue], [session[@"peakInputW"] doubleValue], [session[@"peakBattW"] doubleValue], session[@"peakTemp"] == [NSNull null] ? @"未知" : [NSString stringWithFormat:@"%.1f°C", [session[@"peakTemp"] doubleValue]], [session[@"wireless"] boolValue] ? @"无线" : @"有线", session[@"throttledSeconds"] ?: @0];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"充电详情" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"充电历史";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"清空" style:UIBarButtonItemStylePlain target:self action:@selector(clearAll)];
    [self reloadHistory];
}

- (void)clearAll {
    if (!self.sessions.count) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"暂无记录" message:@"还没有可清空的充电历史。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"清空充电历史" message:[NSString stringWithFormat:@"确定删除全部 %lu 条记录？此操作不可恢复。", (unsigned long)self.sessions.count] preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"全部清空" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        (void)action;
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.sbcpu.floating.charge-history.clear"), NULL, NULL, YES);
        [[NSFileManager defaultManager] removeItemAtPath:@"/var/mobile/Library/Preferences/com.sbcpu.floating.charge-sessions.json" error:nil];
        self.sessions = @[];
        self->_specifiers = nil;
        [self reloadSpecifiers];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
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
                PSSpecifier *row = [PSSpecifier preferenceSpecifierNamed:label target:self set:NULL get:NULL detail:Nil cell:PSButtonCell edit:nil];
                [row setProperty:session forKey:@"SBCPUChargeSession"];
                [row setButtonAction:@selector(showSessionDetails:)];
                [items addObject:row];
            }
        }
        _specifiers = items;
    }
    return _specifiers;
}
@end
