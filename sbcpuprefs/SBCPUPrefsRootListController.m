
#import "SBCPUPrefsRootListController.h"

@implementation SBCPUPrefsRootListController

- (NSArray *)specifiers {
	if (!_specifiers) {
		_specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
	}
	return _specifiers;
}

@end

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Preferences 可能缓存 specifier/cell；每次返回页面都重新读取持久化值。
    [self reloadSpecifiers];
    if ([self respondsToSelector:@selector(table)]) {
        [[self table] reloadData];
    }
}
