#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <notify.h>
#define MAKE_CHOICE(NAME,KEY,TITLES,VALUES,UNIT) \
@interface NAME : PSListController @end \
@implementation NAME \
- (NSArray *)specifiers { if (!_specifiers) { NSMutableArray *a=[NSMutableArray array]; NSArray *titles=TITLES; NSArray *values=VALUES; CFPropertyListRef raw=CFPreferencesCopyValue(CFSTR(KEY),CFSTR("com.yourname.sbcpufloating"),kCFPreferencesCurrentUser,kCFPreferencesAnyHost); double current=raw?[(id)CFBridgingRelease(raw) doubleValue]:[values[0] doubleValue]; for (NSUInteger i=0;i<values.count;i++) { NSString *title=[NSString stringWithFormat:@"%@%@",titles[i],UNIT]; PSSpecifier *s=[PSSpecifier preferenceSpecifierNamed:title target:self set:NULL get:NULL detail:nil cell:PSButtonCell edit:nil]; [s setProperty:values[i] forKey:@"choiceValue"]; [s setProperty:@(fabs([values[i] doubleValue]-current)<0.001) forKey:@"choiceSelected"]; [a addObject:s]; } _specifiers=a; } return _specifiers; } \
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path { PSSpecifier *s=[self specifierAtIndex:path.row]; NSNumber *v=[s propertyForKey:@"choiceValue"]; CFPreferencesSetValue(CFSTR(KEY),(__bridge CFPropertyListRef)v,CFSTR("com.yourname.sbcpufloating"),kCFPreferencesCurrentUser,kCFPreferencesAnyHost); CFPreferencesSynchronize(CFSTR("com.yourname.sbcpufloating"),kCFPreferencesCurrentUser,kCFPreferencesAnyHost); notify_post("com.yourname.sbcpufloating.prefschanged"); [self.navigationController popViewControllerAnimated:YES]; } \
@end
MAKE_CHOICE(SBCPUAlphaChoiceController,"floatingAlpha",@[@"20%",@"40%",@"60%",@"70%",@"85%",@"100%"],@[@0.2,@0.4,@0.6,@0.7,@0.85,@1.0],@"")
MAKE_CHOICE(SBCPUScaleChoiceController,"floatingScale",@[@"0.4",@"0.6",@"0.8",@"1.0",@"1.2",@"1.4",@"1.6"],@[@0.4,@0.6,@0.8,@1.0,@1.2,@1.4,@1.6],@" 倍")
MAKE_CHOICE(SBCPUFontChoiceController,"floatingFontSize",@[@"8",@"9",@"10",@"11",@"12",@"13",@"14",@"15"],@[@8,@9,@10,@11,@12,@13,@14,@15],@" pt")
MAKE_CHOICE(SBCPURadiusChoiceController,"floatingCornerRadius",@[@"4",@"8",@"12",@"16",@"20",@"24",@"28",@"32",@"35"],@[@4,@8,@12,@16,@20,@24,@28,@32,@35],@" pt")
MAKE_CHOICE(SBCPURefreshChoiceController,"floatingValueRefreshInterval",@[@"1","2"],@[@1.0,@2.0],@" 秒")
MAKE_CHOICE(SBCPUCollapseDelayController,"autoCollapseDelay",@[@"2","3","4","5","8","10"],@[@2,@3,@4,@5,@8,@10],@" 秒")
MAKE_CHOICE(SBCPUCollapsedModeController,"collapsedDisplayMode",@[@"CPU 使用率",@"FPS 帧率",@"电池温度",@"电池电流",@"电池电量"],@[@0,@1,@2,@3,@4],@"")
MAKE_CHOICE(SBCPULogoutCPUController,"logoutCPUThreshold",@[@"50","75","100","125","150","175","200"],@[@50,@75,@100,@125,@150,@175,@200],@"%")
MAKE_CHOICE(SBCPULogoutDurationController,"logoutDuration",@[@"30","60","120","300"],@[@30,@60,@120,@300],@" 秒")
MAKE_CHOICE(SBCPUDockModeController,"dockMode",@[@"自动吸附",@"左侧",@"右侧",@"顶部",@"底部"],@[@0,@1,@2,@3,@4],@"")
MAKE_CHOICE(SBCPUNotificationDurationController,"notificationDuration",@[@"3","5","8","10"],@[@3,@5,@8,@10],@" 秒")
MAKE_CHOICE(SBCPUDockReturnController,"statusDockReturnDelay",@[@"1","2","3","4","5","6","7","8","9","10","11","12","13","14","15","16","17","18","19","20","21","22","23","24","25","26","27","28","29","30"],@[@1,@2,@3,@4,@5,@6,@7,@8,@9,@10,@11,@12,@13,@14,@15,@16,@17,@18,@19,@20,@21,@22,@23,@24,@25,@26,@27,@28,@29,@30],@" 秒")
MAKE_CHOICE(SBCPUCardOpacityController,"glassCardOpacity",@[@"20%",@"40%",@"60%",@"80%",@"100%"],@[@0.2,@0.4,@0.6,@0.8,@1.0],@"")
MAKE_CHOICE(SBCPUBlurController,"glassBlurRadius",@[@"0",@"25",@"50",@"75",@"100"],@[@0,@25,@50,@75,@100],@"")
MAKE_CHOICE(SBCUDimOpacityController,"glassDimOpacity",@[@"40%",@"60%",@"80%",@"90%",@"100%"],@[@0.4,@0.6,@0.8,@0.9,@1.0],@"")
