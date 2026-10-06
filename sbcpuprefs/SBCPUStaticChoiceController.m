#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <notify.h>
@interface SBCPUStaticChoiceController : PSListController { NSString *_key; NSArray *_titles; NSArray *_values; NSString *_unit; } @end
@implementation SBCPUStaticChoiceController
- (instancetype)initWithSpecifier:(PSSpecifier *)s { self=[super init]; if(self){_key=[[s propertyForKey:@"choiceKey"] copy]; _titles=[[s propertyForKey:@"choiceTitles"] copy]; _values=[[s propertyForKey:@"choiceValues"] copy]; _unit=[[s propertyForKey:@"choiceUnit"] copy]; self.title=[s propertyForKey:@"label"];} return self; }
- (NSArray *)specifiers { if(!_specifiers){NSMutableArray *a=[NSMutableArray array]; CFPropertyListRef raw=CFPreferencesCopyValue((__bridge CFStringRef)_key,CFSTR("com.yourname.sbcpufloating"),kCFPreferencesCurrentUser,kCFPreferencesAnyHost); double cur=raw?[(id)CFBridgingRelease(raw) doubleValue]:[_values.firstObject doubleValue]; for(NSUInteger i=0;i<_values.count;i++){PSSpecifier *s=[PSSpecifier preferenceSpecifierNamed:[NSString stringWithFormat:@"%@%@",_titles[i],_unit?:@""] target:self set:NULL get:NULL detail:nil cell:PSButtonCell edit:nil];[s setProperty:_values[i] forKey:@"choiceValue"];[s setProperty:@(fabs([_values[i] doubleValue]-cur)<.001) forKey:@"choiceSelected"];[a addObject:s];}_specifiers=a;}return _specifiers;}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)p {NSNumber *v=[[self specifierAtIndex:p.row] propertyForKey:@"choiceValue"];CFPreferencesSetValue((__bridge CFStringRef)_key,(__bridge CFPropertyListRef)v,CFSTR("com.yourname.sbcpufloating"),kCFPreferencesCurrentUser,kCFPreferencesAnyHost);CFPreferencesSynchronize(CFSTR("com.yourname.sbcpufloating"),kCFPreferencesCurrentUser,kCFPreferencesAnyHost);notify_post("com.yourname.sbcpufloating.prefschanged");[self.navigationController popViewControllerAnimated:YES];}
@end
