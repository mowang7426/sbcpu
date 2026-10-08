#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <notify.h>
#import "../SBCPUTextOnlyPolicy.h"

@interface SBCPUTextOnlyController : PSListController
@end
@implementation SBCPUTextOnlyController
- (NSArray *)specifiers {
    if (!_specifiers) _specifiers = [self loadSpecifiersFromPlistName:@"TextOnly" target:self];
    return _specifiers;
}
- (id)valueForKeyName:(NSString *)key fallback:(id)fallback {
    CFPreferencesSynchronize(CFSTR("com.yourname.sbcpufloating"), kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPropertyListRef value = CFPreferencesCopyValue((__bridge CFStringRef)key,
        CFSTR("com.yourname.sbcpufloating"), kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    return value ? CFBridgingRelease(value) : fallback;
}
- (id)getPreferenceValue:(PSSpecifier *)specifier {
    return [self valueForKeyName:[specifier propertyForKey:@"key"] fallback:[specifier propertyForKey:@"default"]];
}
- (void)writeValues:(NSDictionary *)values {
    for (NSString *key in values) CFPreferencesSetValue((__bridge CFStringRef)key,
        (__bridge CFPropertyListRef)values[key], CFSTR("com.yourname.sbcpufloating"),
        kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPreferencesSynchronize(CFSTR("com.yourname.sbcpufloating"), kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    notify_post("com.yourname.sbcpufloating.prefschanged");
}
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if ([key isEqualToString:@"floatingTextOnlyFontSize"]) value = @(SBCPUTextOnlyBound([value doubleValue], 8, 24, 13));
    [self writeValues:@{key:value}];
}
- (void)preset:(NSInteger)preset {
    [self writeValues:@{@"floatingTextOnlyPreset":@(preset), @"floatingTextOnlyX":@0, @"floatingTextOnlyY":@0}];
    [self reloadSpecifiers];
}
- (void)topLeft { [self preset:0]; }
- (void)topCenter { [self preset:1]; }
- (void)topRight { [self preset:2]; }
- (void)moveX:(double)x y:(double)y {
    double oldX = [[self valueForKeyName:@"floatingTextOnlyX" fallback:@0] doubleValue];
    double oldY = [[self valueForKeyName:@"floatingTextOnlyY" fallback:@0] doubleValue];
    [self writeValues:@{@"floatingTextOnlyX":@(SBCPUTextOnlyBound(oldX+x, -1000, 1000, 0)),
                       @"floatingTextOnlyY":@(SBCPUTextOnlyBound(oldY+y, -1000, 1000, 0))}];
    [self reloadSpecifiers];
}
- (void)moveUp { [self moveX:0 y:-8]; }
- (void)moveDown { [self moveX:0 y:8]; }
- (void)moveLeft { [self moveX:-8 y:0]; }
- (void)moveRight { [self moveX:8 y:0]; }
- (void)editOffset:(NSString *)key title:(NSString *)title {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
        message:@"相对所选顶部预设的偏移（pt），范围 -1000 到 1000。屏幕边缘会限制实际位置。"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
        field.text = [[self valueForKeyName:key fallback:@0] description];
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        double value = 0;
        NSScanner *scanner = [NSScanner scannerWithString:alert.textFields.firstObject.text ?: @""];
        if ([scanner scanDouble:&value] && scanner.isAtEnd && isfinite(value)) {
            [self writeValues:@{key:@(SBCPUTextOnlyBound(value, -1000, 1000, 0))}];
            [self reloadSpecifiers];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)editX { [self editOffset:@"floatingTextOnlyX" title:@"水平偏移 X（正数向右）"]; }
- (void)editY { [self editOffset:@"floatingTextOnlyY" title:@"垂直偏移 Y（正数向下）"]; }
- (void)difference { [self writeValues:@{@"floatingTextOnlyColor":@0}]; }
- (void)whiteText { [self writeValues:@{@"floatingTextOnlyColor":@1}]; }
- (void)blackText { [self writeValues:@{@"floatingTextOnlyColor":@2}]; }
- (void)viewDidLoad { [super viewDidLoad]; self.title = @"纯文字浮窗"; }
@end
