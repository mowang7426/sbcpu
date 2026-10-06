#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <notify.h>
@interface SBCPUChoiceBase : PSListController
+ (NSString *)choiceKey; + (NSArray *)choiceTitles; + (NSArray *)choiceValues; + (NSString *)choiceUnit;
@end
@implementation SBCPUChoiceBase
+ (NSString *)choiceKey { return @""; } + (NSArray *)choiceTitles { return @[]; } + (NSArray *)choiceValues { return @[]; } + (NSString *)choiceUnit { return @""; }
- (NSArray *)specifiers { if (!_specifiers) { NSMutableArray *a=[NSMutableArray array]; NSArray *v=[[self class] choiceValues]; NSArray *t=[[self class] choiceTitles]; NSString *u=[[self class] choiceUnit]; CFPropertyListRef raw=CFPreferencesCopyValue((__bridge CFStringRef)[[self class] choiceKey],CFSTR("com.yourname.sbcpufloating"),kCFPreferencesCurrentUser,kCFPreferencesAnyHost); double cur=raw?[(id)CFBridgingRelease(raw) doubleValue]:[v.firstObject doubleValue]; for(NSUInteger i=0;i<v.count;i++){ NSString *label=[NSString stringWithFormat:@"%@%@",t[i],u]; PSSpecifier *s=[PSSpecifier preferenceSpecifierNamed:label target:self set:NULL get:NULL detail:nil cell:PSButtonCell edit:nil]; [s setProperty:v[i] forKey:@"choiceValue"]; [s setProperty:@(fabs([v[i] doubleValue]-cur)<0.001) forKey:@"choiceSelected"]; [a addObject:s]; } _specifiers=a; } return _specifiers; }
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path { PSSpecifier *s=[self specifierAtIndex:path.row]; NSNumber *v=[s propertyForKey:@"choiceValue"]; CFPreferencesSetValue((__bridge CFStringRef)[[self class] choiceKey],(__bridge CFPropertyListRef)v,CFSTR("com.yourname.sbcpufloating"),kCFPreferencesCurrentUser,kCFPreferencesAnyHost); CFPreferencesSynchronize(CFSTR("com.yourname.sbcpufloating"),kCFPreferencesCurrentUser,kCFPreferencesAnyHost); notify_post("com.yourname.sbcpufloating.prefschanged"); [self.navigationController popViewControllerAnimated:YES]; }
@end
#define CHOICE_CLASS(N,K,T,V,U) @interface N : SBCPUChoiceBase @end @implementation N + (NSString *)choiceKey{return K;} + (NSArray *)choiceTitles{return T;} + (NSArray *)choiceValues{return V;} + (NSString *)choiceUnit{return U;} @end
CHOICE_CLASS(SBCPUAlphaChoiceController,@"floatingAlpha",@[@"20%",@"40%",@"60%",@"70%",@"85%",@"100%"],@[@0.2,@0.4,@0.6,@0.7,@0.85,@1.0],@"")
CHOICE_CLASS(SBCPUScaleChoiceController,@"floatingScale",@[@"0.4",@"0.6",@"0.8",@"1.0",@"1.2",@"1.4",@"1.6"],@[@0.4,@0.6,@0.8,@1.0,@1.2,@1.4,@1.6],@" 倍")
CHOICE_CLASS(SBCPUFontChoiceController,@"floatingFontSize",@[@"8",@"9",@"10",@"11",@"12",@"13",@"14",@"15"],@[@8,@9,@10,@11,@12,@13,@14,@15],@" pt")
CHOICE_CLASS(SBCPURadiusChoiceController,@"floatingCornerRadius",@[@"4",@"8",@"12",@"16",@"20",@"24",@"28",@"32",@"35"],@[@4,@8,@12,@16,@20,@24,@28,@32,@35],@" pt")
CHOICE_CLASS(SBCPURefreshChoiceController,@"floatingValueRefreshInterval",@[@"1",@"2"],@[@1.0,@2.0],@" 秒")
CHOICE_CLASS(SBCPUCollapseDelayController,@"autoCollapseDelay",@[@"2",@"3",@"4",@"5",@"8",@"10"],@[@2,@3,@4,@5,@8,@10],@" 秒")
CHOICE_CLASS(SBCPUCollapsedModeController,@"collapsedDisplayMode",@[@"CPU 使用率",@"FPS 帧率",@"电池温度",@"电池电流",@"电池电量"],@[@0,@1,@2,@3,@4],@"")
CHOICE_CLASS(SBCPULogoutCPUController,@"logoutCPUThreshold",@[@"50",@"75",@"100",@"125",@"150",@"175",@"200"],@[@50,@75,@100,@125,@150,@175,@200],@"%")
CHOICE_CLASS(SBCPULogoutDurationController,@"logoutDuration",@[@"30",@"60",@"120",@"300"],@[@30,@60,@120,@300],@" 秒")
CHOICE_CLASS(SBCPUDockModeController,@"dockMode",@[@"自动吸附",@"左侧",@"右侧",@"顶部",@"底部"],@[@0,@1,@2,@3,@4],@"")
CHOICE_CLASS(SBCPUNotificationDurationController,@"notificationDuration",@[@"3",@"5",@"8",@"10"],@[@3,@5,@8,@10],@" 秒")
CHOICE_CLASS(SBCPUCardOpacityController,@"glassCardOpacity",@[@"20%",@"40%",@"60%",@"80%",@"100%"],@[@0.2,@0.4,@0.6,@0.8,@1.0],@"")
CHOICE_CLASS(SBCPUBlurController,@"glassBlurRadius",@[@"0",@"25",@"50",@"75",@"100"],@[@0,@25,@50,@75,@100],@"")
CHOICE_CLASS(SBCUDimOpacityController,@"glassDimOpacity",@[@"40%",@"60%",@"80%",@"90%",@"100%"],@[@0.4,@0.6,@0.8,@0.9,@1.0],@"")
