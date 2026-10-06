#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <notify.h>
@interface SBCPUChoiceBase : PSListController @end
@implementation SBCPUChoiceBase
- (NSString *)choiceKey{return @"";} - (NSArray *)choiceTitles{return @[];} - (NSArray *)choiceValues{return @[];} - (NSString *)choiceUnit{return @"";}
- (NSArray *)specifiers { if(!_specifiers){NSMutableArray *a=[NSMutableArray array]; NSArray *v=[self choiceValues],*t=[self choiceTitles]; CFPropertyListRef raw=CFPreferencesCopyValue((__bridge CFStringRef)[self choiceKey],CFSTR("com.yourname.sbcpufloating"),kCFPreferencesCurrentUser,kCFPreferencesAnyHost); double cur=raw?[(id)CFBridgingRelease(raw) doubleValue]:[v.firstObject doubleValue]; for(NSUInteger i=0;i<v.count;i++){ PSSpecifier *s=[PSSpecifier preferenceSpecifierNamed:[NSString stringWithFormat:@"%@%@",t[i],[self choiceUnit]] target:self set:NULL get:NULL detail:nil cell:PSButtonCell edit:nil]; [s setProperty:v[i] forKey:@"choiceValue"]; [s setProperty:@(fabs([v[i] doubleValue]-cur)<0.001) forKey:@"choiceSelected"]; [a addObject:s]; } _specifiers=a;} return _specifiers; }
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)p {
    [t deselectRowAtIndexPath:p animated:YES];
    PSSpecifier *s = [self specifierAtIndexPath:p];
    NSNumber *v = [s propertyForKey:@"choiceValue"];
    if (![v isKindOfClass:[NSNumber class]]) return;
    CFStringRef key = (__bridge CFStringRef)[self choiceKey];
    CFPreferencesSetValue(key, (__bridge CFPropertyListRef)v, CFSTR("com.yourname.sbcpufloating"), kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPreferencesSynchronize(CFSTR("com.yourname.sbcpufloating"), kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    notify_post("com.yourname.sbcpufloating.prefschanged");
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    PSSpecifier *s = [self specifierAtIndexPath:indexPath];
    cell.accessoryType = [[s propertyForKey:@"choiceSelected"] boolValue] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
}

@end
@interface SBCPUAlphaChoiceController: SBCPUChoiceBase @end
@implementation SBCPUAlphaChoiceController
- (NSString *)choiceKey{return @"floatingAlpha";} - (NSArray *)choiceTitles{return @[@"20%",@"40%",@"60%",@"70%",@"85%",@"100%"];} - (NSArray *)choiceValues{return @[@0.2,@0.4,@0.6,@0.7,@0.85,@1.0];} - (NSString *)choiceUnit{return @"";}
@end
@interface SBCPUScaleChoiceController: SBCPUChoiceBase @end
@implementation SBCPUScaleChoiceController
- (NSString *)choiceKey{return @"floatingScale";} - (NSArray *)choiceTitles{return @[@"0.4",@"0.6",@"0.8",@"1.0",@"1.2",@"1.4",@"1.6"];} - (NSArray *)choiceValues{return @[@0.4,@0.6,@0.8,@1.0,@1.2,@1.4,@1.6];} - (NSString *)choiceUnit{return @" 倍";}
@end
@interface SBCPUFontChoiceController: SBCPUChoiceBase @end
@implementation SBCPUFontChoiceController
- (NSString *)choiceKey{return @"floatingFontSize";} - (NSArray *)choiceTitles{return @[@"8",@"9",@"10",@"11",@"12",@"13",@"14",@"15"];} - (NSArray *)choiceValues{return @[@8,@9,@10,@11,@12,@13,@14,@15];} - (NSString *)choiceUnit{return @" pt";}
@end
@interface SBCPURadiusChoiceController: SBCPUChoiceBase @end
@implementation SBCPURadiusChoiceController
- (NSString *)choiceKey{return @"floatingCornerRadius";} - (NSArray *)choiceTitles{return @[@"4",@"8",@"12",@"16",@"20",@"24",@"28",@"32",@"35"];} - (NSArray *)choiceValues{return @[@4,@8,@12,@16,@20,@24,@28,@32,@35];} - (NSString *)choiceUnit{return @" pt";}
@end
@interface SBCPURefreshChoiceController: SBCPUChoiceBase @end
@implementation SBCPURefreshChoiceController
- (NSString *)choiceKey{return @"floatingValueRefreshInterval";} - (NSArray *)choiceTitles{return @[@"1",@"2"];} - (NSArray *)choiceValues{return @[@1.0,@2.0];} - (NSString *)choiceUnit{return @" 秒";}
@end
@interface SBCPUCollapseDelayController: SBCPUChoiceBase @end
@implementation SBCPUCollapseDelayController
- (NSString *)choiceKey{return @"autoCollapseDelay";} - (NSArray *)choiceTitles{return @[@"2",@"3",@"4",@"5",@"8",@"10"];} - (NSArray *)choiceValues{return @[@2,@3,@4,@5,@8,@10];} - (NSString *)choiceUnit{return @" 秒";}
@end
@interface SBCPUCollapsedModeController: SBCPUChoiceBase @end
@implementation SBCPUCollapsedModeController
- (NSString *)choiceKey{return @"collapsedDisplayMode";} - (NSArray *)choiceTitles{return @[@"CPU 使用率",@"FPS 帧率",@"电池温度",@"电池电流",@"电池电量"];} - (NSArray *)choiceValues{return @[@0,@1,@2,@3,@4];} - (NSString *)choiceUnit{return @"";}
@end
@interface SBCPULogoutCPUController: SBCPUChoiceBase @end
@implementation SBCPULogoutCPUController
- (NSString *)choiceKey{return @"logoutCPUThreshold";} - (NSArray *)choiceTitles{return @[@"50",@"75",@"100",@"125",@"150",@"175",@"200"];} - (NSArray *)choiceValues{return @[@50,@75,@100,@125,@150,@175,@200];} - (NSString *)choiceUnit{return @"%";}
@end
@interface SBCPULogoutDurationController: SBCPUChoiceBase @end
@implementation SBCPULogoutDurationController
- (NSString *)choiceKey{return @"logoutDuration";} - (NSArray *)choiceTitles{return @[@"30",@"60",@"120",@"300"];} - (NSArray *)choiceValues{return @[@30,@60,@120,@300];} - (NSString *)choiceUnit{return @" 秒";}
@end
@interface SBCPUDockModeController: SBCPUChoiceBase @end
@implementation SBCPUDockModeController
- (NSString *)choiceKey{return @"dockMode";} - (NSArray *)choiceTitles{return @[@"自动吸附",@"左侧",@"右侧",@"顶部",@"底部"];} - (NSArray *)choiceValues{return @[@0,@1,@2,@3,@4];} - (NSString *)choiceUnit{return @"";}
@end
@interface SBCPUNotificationDurationController: SBCPUChoiceBase @end
@implementation SBCPUNotificationDurationController
- (NSString *)choiceKey{return @"notificationDuration";} - (NSArray *)choiceTitles{return @[@"3",@"5",@"8",@"10"];} - (NSArray *)choiceValues{return @[@3,@5,@8,@10];} - (NSString *)choiceUnit{return @" 秒";}
@end
@interface SBCPUCardOpacityController: SBCPUChoiceBase @end
@implementation SBCPUCardOpacityController
- (NSString *)choiceKey{return @"glassCardOpacity";} - (NSArray *)choiceTitles{return @[@"20%",@"40%",@"60%",@"80%",@"100%"];} - (NSArray *)choiceValues{return @[@0.2,@0.4,@0.6,@0.8,@1.0];} - (NSString *)choiceUnit{return @"";}
@end
@interface SBCPUBlurController: SBCPUChoiceBase @end
@implementation SBCPUBlurController
- (NSString *)choiceKey{return @"glassBlurRadius";} - (NSArray *)choiceTitles{return @[@"0",@"25",@"50",@"75",@"100"];} - (NSArray *)choiceValues{return @[@0,@25,@50,@75,@100];} - (NSString *)choiceUnit{return @"";}
@end
@interface SBCUDimOpacityController: SBCPUChoiceBase @end
@implementation SBCUDimOpacityController
- (NSString *)choiceKey{return @"glassDimOpacity";} - (NSArray *)choiceTitles{return @[@"40%",@"60%",@"80%",@"90%",@"100%"];} - (NSArray *)choiceValues{return @[@0.4,@0.6,@0.8,@0.9,@1.0];} - (NSString *)choiceUnit{return @"";}
@end
