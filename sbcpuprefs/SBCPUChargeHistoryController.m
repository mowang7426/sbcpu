#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
@interface SBCPUChargeHistoryController : PSListController @end
@implementation SBCPUChargeHistoryController
- (NSArray *)specifiers { if(!_specifiers){_specifiers=@[[PSSpecifier emptyGroupSpecifier],[PSSpecifier preferenceSpecifierNamed:@"充电历史记录" target:nil set:NULL get:NULL detail:nil cell:PSStaticTextCell edit:nil]];}return _specifiers; }
- (void)viewDidLoad{[super viewDidLoad];self.title=@"充电历史";}
@end
