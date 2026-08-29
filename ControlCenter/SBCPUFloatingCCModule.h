#import <Foundation/Foundation.h>
#import "CCUIHeaders.h"

@interface SBCPUFloatingCCModule : NSObject <CCUIContentModule>
@property (nonatomic, strong, readonly) UIViewController<CCUIContentModuleContentViewController> *contentViewController;
@property (nonatomic, strong, readonly) UIViewController *backgroundViewController;
@end
