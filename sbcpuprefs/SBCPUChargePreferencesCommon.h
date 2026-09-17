#import <Foundation/Foundation.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

@interface SBCPUChargePreferencesCommon : NSObject
+ (id)valueForKey:(NSString *)key defaultValue:(id)defaultValue;
+ (void)setValue:(id)value forKey:(NSString *)key;
+ (void)redecideDaemon;
+ (BOOL)daemonRunning;
+ (NSString *)daemonStatusText;
@end
