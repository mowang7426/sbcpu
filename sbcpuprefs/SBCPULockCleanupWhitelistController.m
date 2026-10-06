#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <notify.h>
@interface SBCPULockCleanupWhitelistController : PSListController @end
@implementation SBCPULockCleanupWhitelistController
- (NSArray *)specifiers { if(!_specifiers){NSMutableArray *a=[NSMutableArray array];[a addObject:[PSSpecifier emptyGroupSpecifier]];CFPropertyListRef v=CFPreferencesCopyValue(CFSTR("lockCleanupWhitelist"),CFSTR("com.yourname.sbcpufloating"),kCFPreferencesCurrentUser,kCFPreferencesAnyHost);NSArray *items=(v&&CFGetTypeID(v)==CFArrayGetTypeID())?CFBridgingRelease(v):@[];if(!items.count)[a addObject:[PSSpecifier preferenceSpecifierNamed:@"暂无白名单应用" target:nil set:NULL get:NULL detail:nil cell:PSStaticTextCell edit:nil]];else for(NSString *item in items)if([item isKindOfClass:NSString.class])[a addObject:[PSSpecifier preferenceSpecifierNamed:item target:nil set:NULL get:NULL detail:nil cell:PSStaticTextCell edit:nil]];_specifiers=a;}return _specifiers;}
- (void)viewDidLoad{[super viewDidLoad];self.title=@"锁屏清理白名单";}
@end
