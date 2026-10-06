#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <notify.h>
@interface SBCPUValuePickerController : PSListController { PSSpecifier *_sourceSpecifier; NSString *_key; NSArray *_values; NSString *_unit; } @end
@implementation SBCPUValuePickerController
- (instancetype)initWithSpecifier:(PSSpecifier *)specifier { self=[super initWithStyle:UITableViewStyleGrouped]; if(self){[self configure:specifier];} return self; }
- (void)configure:(PSSpecifier *)s { _sourceSpecifier=s; _key=[[s propertyForKey:@"key"] copy]; _values=[[s propertyForKey:@"validValues"] copy]; _unit=[[s propertyForKey:@"unit"] copy]; self.title=[s propertyForKey:@"label"]; }
- (void)setSpecifier:(PSSpecifier *)s { [self configure:s]; [super setSpecifier:s]; }
- (id)currentValue { CFPropertyListRef v=CFPreferencesCopyValue((__bridge CFStringRef)_key,CFSTR("com.yourname.sbcpufloating"),kCFPreferencesCurrentUser,kCFPreferencesAnyHost); return v?CFBridgingRelease(v):([_sourceSpecifier propertyForKey:@"default"]?:@0); }
- (NSArray *)specifiers { if(!_specifiers){NSMutableArray *a=[NSMutableArray array]; NSNumber *cur=[self currentValue]; for(NSNumber *n in _values){NSString *text=[NSString stringWithFormat:@"%@%@",[self textFor:n],_unit?:@""]; PSSpecifier *s=[PSSpecifier preferenceSpecifierNamed:text target:self set:@selector(setValue:specifier:) get:@selector(getValue:) detail:nil cell:PSRadioCell edit:nil]; [s setProperty:n forKey:@"value"]; [s setProperty:@(fabs(n.doubleValue-cur.doubleValue)<0.001) forKey:@"checked"]; [a addObject:s];} _specifiers=a;} return _specifiers; }
- (NSString *)textFor:(NSNumber *)n { if([_key isEqualToString:@"floatingAlpha"]||[_key isEqualToString:@"glassCardOpacity"]||[_key isEqualToString:@"glassDimOpacity"]) return [NSString stringWithFormat:@"%.0f%%",n.doubleValue*100]; if([_key isEqualToString:@"floatingScale"]) return [NSString stringWithFormat:@"%.1f",n.doubleValue]; return [NSString stringWithFormat:@"%.0f",n.doubleValue]; }
- (id)getValue:(PSSpecifier *)s { NSNumber *n=[s propertyForKey:@"value"]; return @([self currentValue].doubleValue==n.doubleValue); }
- (void)setValue:(id)value specifier:(PSSpecifier *)s { NSNumber *n=[s propertyForKey:@"value"]; if(!n)return; CFPreferencesSetValue((__bridge CFStringRef)_key,(__bridge CFPropertyListRef)n,CFSTR("com.yourname.sbcpufloating"),kCFPreferencesCurrentUser,kCFPreferencesAnyHost); CFPreferencesSynchronize(CFSTR("com.yourname.sbcpufloating"),kCFPreferencesCurrentUser,kCFPreferencesAnyHost); notify_post("com.yourname.sbcpufloating.prefschanged"); [self reloadSpecifiers]; }
@end
