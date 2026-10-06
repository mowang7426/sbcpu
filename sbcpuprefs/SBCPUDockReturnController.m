#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <notify.h>

@interface SBCPUDockReturnController : PSListController
@end

@implementation SBCPUDockReturnController

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *items = [NSMutableArray array];
        [items addObject:[PSSpecifier groupSpecifierWithName:@"选择顶部拖动回位时间"]];
        CFPropertyListRef raw = CFPreferencesCopyValue(CFSTR("statusDockReturnDelay"), CFSTR("com.yourname.sbcpufloating"), kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        NSInteger current = raw ? [(id)CFBridgingRelease(raw) integerValue] : 5;
        for (NSInteger seconds = 1; seconds <= 10; seconds++) {
            PSSpecifier *row = [PSSpecifier preferenceSpecifierNamed:[NSString stringWithFormat:@"%ld 秒", (long)seconds] target:self set:NULL get:NULL detail:nil cell:PSButtonCell edit:nil];
            [row setProperty:@(seconds) forKey:@"returnDelayValue"];
            [row setProperty:@(seconds == current) forKey:@"returnDelaySelected"];
            [row setButtonAction:@selector(selectDelay:)];
            [items addObject:row];
        }
        _specifiers = items;
    }
    return _specifiers;
}

- (void)selectDelay:(PSSpecifier *)specifier {
    NSNumber *value = [specifier propertyForKey:@"returnDelayValue"];
    if (!value) return;
    CFPreferencesSetValue(CFSTR("statusDockReturnDelay"), (__bridge CFPropertyListRef)value, CFSTR("com.yourname.sbcpufloating"), kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPreferencesSynchronize(CFSTR("com.yourname.sbcpufloating"), kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    notify_post("com.yourname.sbcpufloating.prefschanged");
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    PSSpecifier *specifier = [self specifierAtIndexPath:indexPath];
    cell.accessoryType = [[specifier propertyForKey:@"returnDelaySelected"] boolValue] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
}
@end
