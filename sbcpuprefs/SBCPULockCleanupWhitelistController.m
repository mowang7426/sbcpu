#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
@interface SBCPULockCleanupWhitelistController : PSListController @end
@implementation SBCPULockCleanupWhitelistController
- (NSArray *)specifiers { if (!_specifiers) _specifiers=[self loadSpecifiersFromPlistName:@"LockCleanupWhitelist" target:self]; return _specifiers; }
- (void)viewDidLoad { [super viewDidLoad]; self.title=@"锁屏清理白名单"; }
@end
