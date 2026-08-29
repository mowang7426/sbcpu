#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#if __has_include(<ControlCenterUIKit/CCUIContentModule.h>)
#import <ControlCenterUIKit/CCUIContentModule.h>
#import <ControlCenterUIKit/CCUIContentModuleContext.h>
#else
@protocol CCUIContentModule <NSObject>
@required
- (UIViewController *)contentViewController;
@optional
- (UIViewController *)backgroundViewController;
- (void)setContentModuleContext:(id)context;
@end
@interface CCUIContentModuleContext : NSObject
@end
#endif

#if __has_include(<ControlCenterUIKit/CCUIContentModuleContentViewController.h>)
#import <ControlCenterUIKit/CCUIContentModuleContentViewController.h>
#endif
