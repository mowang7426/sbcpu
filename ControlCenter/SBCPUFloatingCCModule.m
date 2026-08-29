#import "SBCPUFloatingCCModule.h"
#import "SBCPUFloatingCCModuleViewController.h"

@implementation SBCPUFloatingCCModule
@synthesize contentViewController = _contentViewController;

- (UIViewController<CCUIContentModuleContentViewController> *)contentViewController {
    if (!_contentViewController) {
        _contentViewController = [[SBCPUFloatingCCModuleViewController alloc] init];
    }
    return _contentViewController;
}

- (UIViewController *)backgroundViewController {
    return nil;
}

- (void)controlCenterWillPresent {
    UIViewController *controller = self.contentViewController;
    if ([controller respondsToSelector:@selector(refreshState)]) {
        [(id)controller refreshState];
    }
}
@end
