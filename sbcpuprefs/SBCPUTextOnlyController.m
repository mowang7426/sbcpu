#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <notify.h>
#import "../SBCPUTextOnlyPolicy.h"
#import "../SBCPUTextOnlyColor.h"

@interface SBCPUTextOnlyController : PSListController <UIColorPickerViewControllerDelegate, UIAdaptivePresentationControllerDelegate>
@property(nonatomic, strong) NSArray *pendingTextRGBA;
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
- (void)selectColorMode:(NSInteger)mode {
    [self writeValues:@{@"floatingTextOnlyColor":@(mode)}];
    [self reloadSpecifiers];
}
- (void)automaticText { [self selectColorMode:0]; }
- (void)whiteText { [self selectColorMode:1]; }
- (void)blackText { [self selectColorMode:2]; }
- (void)customText {
    if (self.presentedViewController || self.navigationController.presentedViewController) return;
    SBCPUTextRGBA c = SBCPUTextDecodeRGBA([self valueForKeyName:@"floatingTextOnlyRGBA" fallback:nil]);
    UIColorPickerViewController *picker = [UIColorPickerViewController new];
    picker.title = @"自定义文字颜色";
    picker.supportsAlpha = NO;
    picker.selectedColor = [UIColor colorWithRed:c.red green:c.green blue:c.blue alpha:1];
    picker.delegate = self;
    picker.modalPresentationStyle = UIModalPresentationFormSheet;
    self.pendingTextRGBA = nil;
    UIViewController *presenter = self.navigationController ?: self;
    [presenter presentViewController:picker animated:YES completion:nil];
    picker.presentationController.delegate = self;
}
- (void)capturePickerColor:(UIColorPickerViewController *)picker {
    CGFloat r = 0, g = 0, b = 0, a = 1;
    if (![picker.selectedColor getRed:&r green:&g blue:&b alpha:&a]) return;
    SBCPUTextRGBA c = SBCPUTextDecodeRGBA(@[@(r), @(g), @(b), @(a)]);
    self.pendingTextRGBA = @[@(c.red), @(c.green), @(c.blue), @1];
}
- (void)commitPickerColor {
    if (!self.pendingTextRGBA) return;
    NSArray *color = self.pendingTextRGBA;
    self.pendingTextRGBA = nil;
    id mode = [self valueForKeyName:@"floatingTextOnlyColor" fallback:@0];
    id old = [self valueForKeyName:@"floatingTextOnlyRGBA" fallback:nil];
    // Commit once on completion/dismissal, never on every slider movement.
    if (![mode isEqual:@3] || ![old isEqual:color])
        [self writeValues:@{@"floatingTextOnlyColor":@3, @"floatingTextOnlyRGBA":color}];
    [self reloadSpecifiers];
}
- (void)colorPickerViewController:(UIColorPickerViewController *)viewController didSelectColor:(UIColor *)color continuously:(BOOL)continuously {
    (void)color; (void)continuously;
    [self capturePickerColor:viewController];
}
- (void)colorPickerViewControllerDidFinish:(UIColorPickerViewController *)viewController {
    [self capturePickerColor:viewController];
    [self commitPickerColor];
    [viewController dismissViewControllerAnimated:YES completion:nil];
}
- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController {
    (void)presentationController;
    [self commitPickerColor]; // swipe-to-dismiss also preserves a changed selection
}
- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    PSSpecifier *specifier = [self specifierAtIndexPath:indexPath];
    NSNumber *choice = [specifier propertyForKey:@"textColorMode"];
    if (!choice) return;
    id rawMode = [self valueForKeyName:@"floatingTextOnlyColor" fallback:@0];
    NSInteger mode = [rawMode isKindOfClass:NSNumber.class] ? [rawMode integerValue] : 0;
    if (mode < 0 || mode > 3) mode = 0;
    cell.accessoryType = mode == choice.integerValue ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    cell.textLabel.text = [specifier name];
    cell.imageView.image = nil;
    if (choice.integerValue == 3) {
        SBCPUTextRGBA c = SBCPUTextDecodeRGBA([self valueForKeyName:@"floatingTextOnlyRGBA" fallback:nil]);
        cell.textLabel.text = [NSString stringWithFormat:@"自定义文字颜色 · #%02X%02X%02X", (unsigned)lround(c.red*255), (unsigned)lround(c.green*255), (unsigned)lround(c.blue*255)];
        cell.imageView.image = [UIImage systemImageNamed:@"circle.fill"];
        cell.imageView.tintColor = [UIColor colorWithRed:c.red green:c.green blue:c.blue alpha:1];
    }
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self reloadSpecifiers]; }
- (void)viewDidLoad { [super viewDidLoad]; self.title = @"纯文字浮窗"; }
@end
