#import <UIKit/UIKit.h>
#import <notify.h>
@interface SBCPULockCleanupWhitelistController : UITableViewController @end
@implementation SBCPULockCleanupWhitelistController { NSMutableArray *_items; }
- (void)loadItems { CFPropertyListRef v=CFPreferencesCopyValue(CFSTR("lockCleanupWhitelist"),CFSTR("com.yourname.sbcpufloating"),kCFPreferencesCurrentUser,kCFPreferencesAnyHost); NSArray *a=(v&&CFGetTypeID(v)==CFArrayGetTypeID())?CFBridgingRelease(v):@[]; if(v && !a) CFRelease(v); _items=[a mutableCopy]?:[NSMutableArray array]; }
- (void)viewDidLoad { [super viewDidLoad]; self.title=@"锁屏清理白名单"; [self loadItems]; self.navigationItem.rightBarButtonItem=self.editButtonItem; }
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return _items.count?:1; }
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)p { UITableViewCell *c=[t dequeueReusableCellWithIdentifier:@"w"]?:[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"w"]; c.textLabel.text=_items.count?_items[p.row]:@"暂无白名单应用"; c.selectionStyle=_items.count?UITableViewCellSelectionStyleDefault:UITableViewCellSelectionStyleNone; return c; }
- (BOOL)tableView:(UITableView *)t canEditRowAtIndexPath:(NSIndexPath *)p { return _items.count>0; }
- (void)tableView:(UITableView *)t commitEditingStyle:(UITableViewCellEditingStyle)s forRowAtIndexPath:(NSIndexPath *)p { if(s==UITableViewCellEditingStyleDelete){[_items removeObjectAtIndex:p.row]; CFPreferencesSetValue(CFSTR("lockCleanupWhitelist"),(__bridge CFPropertyListRef)_items,CFSTR("com.yourname.sbcpufloating"),kCFPreferencesCurrentUser,kCFPreferencesAnyHost); CFPreferencesSynchronize(CFSTR("com.yourname.sbcpufloating"),kCFPreferencesCurrentUser,kCFPreferencesAnyHost); notify_post("com.yourname.sbcpufloating.prefschanged"); [t deleteRowsAtIndexPaths:@[p] withRowAnimation:UITableViewRowAnimationAutomatic];} }
@end
