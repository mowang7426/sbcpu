#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <notify.h>
@interface SBCPUValuePickerController : PSListController { PSSpecifier *_sourceSpecifier; NSString *_key; NSArray *_values; NSString *_unit; } @end
@implementation SBCPUValuePickerController
- (instancetype)initWithSpecifier:(PSSpecifier *)specifier { self=[super init]; if(self){[self configure:specifier];} return self; }
- (void)configure:(PSSpecifier *)s { _sourceSpecifier=s; _key=[[s propertyForKey:@"key"] copy]; _values=[[s propertyForKey:@"validValues"] copy]; _unit=[[s propertyForKey:@"unit"] copy]; self.title=[s propertyForKey:@"label"]; }
- (void)setSpecifier:(PSSpecifier *)s { [self configure:s]; [super setSpecifier:s]; }
- (id)currentValue { CFPropertyListRef v=CFPreferencesCopyValue((__bridge CFStringRef)_key,CFSTR("com.yourname.sbcpufloating"),kCFPreferencesCurrentUser,kCFPreferencesAnyHost); if(v) return CFBridgingRelease(v); return [_sourceSpecifier propertyForKey:@"default"]?:@0; }
- (NSArray *)specifiers { if(!_specifiers){NSMutableArray *a=[NSMutableArray array]; NSNumber *cur=(NSNumber *)[self currentValue]; for(NSNumber *n in _values){NSString *text=[NSString stringWithFormat:@"%@%@",[self textFor:n],_unit?:@""]; PSSpecifier *s=[PSSpecifier preferenceSpecifierNamed:text target:self set:NULL get:NULL detail:nil cell:PSButtonCell edit:nil]; [s setProperty:n forKey:@"value"]; [s setProperty:@(fabs(n.doubleValue-cur.doubleValue)<0.001) forKey:@"checked"]; [a addObject:s];} _specifiers=a;} return _specifiers; }
- (NSString *)textFor:(NSNumber *)n { if([_key isEqualToString:@"floatingAlpha"]||[_key isEqualToString:@"glassCardOpacity"]||[_key isEqualToString:@"glassDimOpacity"]) return [NSString stringWithFormat:@"%.0f%%",n.doubleValue*100]; if([_key isEqualToString:@"floatingScale"]) return [NSString stringWithFormat:@"%.1f",n.doubleValue]; if([_key isEqualToString:@"collapsedDisplayMode"]) return @[@"CPU 使用率",@"FPS 帧率",@"电池温度",@"电池电流",@"电池电量"][MIN((NSInteger)n.doubleValue,4)]; if([_key isEqualToString:@"dockMode"]) return @[@"自动吸附",@"左侧",@"右侧",@"顶部",@"底部"][MIN((NSInteger)n.doubleValue,4)]; return [NSString stringWithFormat:@"%.0f",n.doubleValue]; }
- (void)selectValue:(PSSpecifier *)s { NSNumber *n=[s propertyForKey:@"value"]; if(!n)return; CFPreferencesSetValue((__bridge CFStringRef)_key,(__bridge CFPropertyListRef)n,CFSTR("com.yourname.sbcpufloating"),kCFPreferencesCurrentUser,kCFPreferencesAnyHost); CFPreferencesSynchronize(CFSTR("com.yourname.sbcpufloating"),kCFPreferencesCurrentUser,kCFPreferencesAnyHost); notify_post("com.yourname.sbcpufloating.prefschanged"); [self.navigationController popViewControllerAnimated:YES]; }
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath { PSSpecifier *s=[self specifierAtIndex:indexPath.row]; [self selectValue:s]; }
@end
