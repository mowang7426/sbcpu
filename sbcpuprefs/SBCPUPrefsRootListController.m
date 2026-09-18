#import <UIKit/UIKit.h>

#import "SBCPUPrefsRootListController.h"

@implementation SBCPUPrefsRootListController

- (NSArray *)specifiers {
	if (!_specifiers) {
		_specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
	}
	return _specifiers;
}

- (void)openMoWangSource {
	NSURL *url = [NSURL URLWithString:@"sileo://source/https://mowang7426.github.io/MoWang/"];
	if ([[UIApplication sharedApplication] canOpenURL:url]) {
		[[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
	}
}

@end

