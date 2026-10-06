#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>

static CFStringRef const SBCPUPrefsWhitelistDomain = CFSTR("com.yourname.sbcpufloating");
static CFStringRef const SBCPUPrefsWhitelistKey = CFSTR("lockCleanupWhitelist");

static id SBCPUPrefsWhitelistValue(void) {
    CFPropertyListRef value = CFPreferencesCopyValue(SBCPUPrefsWhitelistKey,
        SBCPUPrefsWhitelistDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    return value ? CFBridgingRelease(value) : nil;
}

// Never rewrite preferences while reading. Keep even unknown/uninstalled IDs,
// their original spelling/order, and duplicates; ignore only non-string/empty entries.
static NSArray<NSString *> *SBCPUPrefsValidWhitelist(id value, BOOL *invalid) {
    if (invalid) *invalid = value && ![value isKindOfClass:[NSArray class]];
    if (![value isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    for (id entry in (NSArray *)value) {
        if ([entry isKindOfClass:[NSString class]] && [entry length] > 0) {
            [result addObject:entry];
        } else if (invalid) {
            *invalid = YES;
        }
    }
    return [result copy];
}

// All private LaunchServices calls are optional, checked, and object-returning.
static id SBCPUPrefsWhitelistSend(id receiver, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (!receiver || ![receiver respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(receiver, selector);
}

static NSDictionary<NSString *, NSString *> *SBCPUPrefsScanWhitelistApps(NSString **message) {
    NSMutableDictionary<NSString *, NSString *> *names = [NSMutableDictionary dictionary];
    BOOL incomplete = NO;
    @try {
        Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
        id workspace = SBCPUPrefsWhitelistSend(workspaceClass, @"defaultWorkspace");
        id rawApps = SBCPUPrefsWhitelistSend(workspace, @"allApplications");
        if (![rawApps isKindOfClass:[NSArray class]]) {
            *message = @"系统未允许读取应用列表。仍可手动添加 Bundle ID。";
            return @{};
        }
        NSArray *apps = rawApps;
        // One bounded pass, never a timer or repeated per-row workspace query.
        NSUInteger limit = MIN(apps.count, (NSUInteger)2048);
        incomplete = apps.count > limit;
        for (NSUInteger index = 0; index < limit; index++) {
            @try {
                id proxy = apps[index];
                id bundleID = SBCPUPrefsWhitelistSend(proxy, @"bundleIdentifier");
                if (![bundleID isKindOfClass:[NSString class]] || [bundleID length] == 0) continue;
                id name = SBCPUPrefsWhitelistSend(proxy, @"localizedName");
                names[bundleID] = ([name isKindOfClass:[NSString class]] && [name length] > 0)
                    ? name : bundleID;
            } @catch (__unused NSException *exception) {
                incomplete = YES;
            }
        }
    } @catch (__unused NSException *exception) {
        incomplete = YES;
    }
    if (incomplete) {
        *message = @"仅列出成功读取的应用；读取失败或未列出的应用可手动添加 Bundle ID。";
    } else if (names.count == 0) {
        *message = @"未读取到已安装应用。可手动添加 Bundle ID；已有白名单不会被删除。";
    } else {
        *message = @"开启开关即可保护应用；未列出的应用也可手动添加 Bundle ID。";
    }
    return [names copy];
}

// Intentionally distinct from the UITableViewController injected by the tweak.
@interface SBCPUPrefsWhitelistController : PSListController
@property (nonatomic, copy) NSArray<NSString *> *whitelist;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *applicationNames;
@property (nonatomic, copy) NSString *scanMessage;
@property (nonatomic, assign) BOOL invalidWhitelist;
@property (nonatomic, assign) BOOL scanning;
- (NSNumber *)isProtected:(PSSpecifier *)specifier;
- (void)setProtected:(NSNumber *)value specifier:(PSSpecifier *)specifier;
- (void)addBundleID;
- (void)refreshApplications;
@end

@implementation SBCPUPrefsWhitelistController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"锁屏清理白名单";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(addBundleID)];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshApplications];
}

- (void)readWhitelist {
    CFPreferencesSynchronize(SBCPUPrefsWhitelistDomain,
        kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    BOOL invalid = NO;
    self.whitelist = SBCPUPrefsValidWhitelist(SBCPUPrefsWhitelistValue(), &invalid);
    self.invalidWhitelist = invalid;
}

- (void)rebuildWhitelistUI {
    _specifiers = nil;
    if (self.isViewLoaded) [self reloadSpecifiers];
}

- (PSSpecifier *)groupNamed:(NSString *)name footer:(NSString *)footer {
    PSSpecifier *group = [PSSpecifier groupSpecifierWithName:name];
    [group setProperty:footer forKey:@"footerText"];
    return group;
}

- (NSString *)displayNameForBundleID:(NSString *)bundleID {
    return self.applicationNames[bundleID] ?: bundleID;
}

- (PSSpecifier *)appSpecifierForBundleID:(NSString *)bundleID {
    NSString *name = [self displayNameForBundleID:bundleID];
    NSString *label = [name isEqualToString:bundleID] ? bundleID
        : [NSString stringWithFormat:@"%@（%@）", name, bundleID];
    PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:label target:self
        set:@selector(setProtected:specifier:) get:@selector(isProtected:)
        detail:nil cell:PSSwitchCell edit:nil];
    [specifier setProperty:bundleID forKey:@"SBCPUWhitelistBundleID"];
    [specifier setProperty:@NO forKey:@"default"];
    return specifier;
}

- (NSMutableArray *)specifiers {
    if (_specifiers) return _specifiers;
    if (!self.whitelist) [self readWhitelist];
    NSMutableArray *items = [NSMutableArray array];
    NSString *intro = @"白名单中的应用在锁屏清理时不会被杀进程或清理卡片。开启开关添加保护；关闭开关并确认后移除。";
    if (self.invalidWhitelist) {
        intro = [intro stringByAppendingString:@" 保存的数据含无效项，已安全忽略；浏览此页不会改写设置。"];
    }
    [items addObject:[self groupNamed:@"管理白名单" footer:intro]];
    PSSpecifier *add = [PSSpecifier preferenceSpecifierNamed:@"手动添加 Bundle ID…"
        target:self set:NULL get:NULL detail:nil cell:PSButtonCell edit:nil];
    [add setButtonAction:@selector(addBundleID)];
    [items addObject:add];
    PSSpecifier *refresh = [PSSpecifier preferenceSpecifierNamed:@"重新读取应用列表"
        target:self set:NULL get:NULL detail:nil cell:PSButtonCell edit:nil];
    [refresh setButtonAction:@selector(refreshApplications)];
    [refresh setProperty:@(!self.scanning) forKey:@"enabled"];
    [items addObject:refresh];

    NSArray<NSString *> *protectedIDs = [NSOrderedSet orderedSetWithArray:self.whitelist].array;
    NSString *protectedFooter = protectedIDs.count
        ? @"包括手动添加或已卸载应用的 ID；应用列表读取失败不会影响这些保护项。"
        : @"白名单为空。可从下方选择应用，或手动输入 Bundle ID 添加。";
    [items addObject:[self groupNamed:[NSString stringWithFormat:@"已保护应用（%lu）",
        (unsigned long)protectedIDs.count] footer:protectedFooter]];
    for (NSString *bundleID in protectedIDs) {
        [items addObject:[self appSpecifierForBundleID:bundleID]];
    }

    [items addObject:[self groupNamed:@"可添加的已安装应用"
        footer:self.scanMessage ?: @"可手动添加 Bundle ID，或重新读取应用列表。"]];
    NSArray<NSString *> *installedIDs = [self.applicationNames.allKeys
        sortedArrayUsingComparator:^NSComparisonResult(NSString *left, NSString *right) {
            NSComparisonResult result = [self.applicationNames[left]
                localizedStandardCompare:self.applicationNames[right]];
            return result == NSOrderedSame ? [left compare:right] : result;
        }];
    for (NSString *bundleID in installedIDs) {
        if (![protectedIDs containsObject:bundleID]) {
            [items addObject:[self appSpecifierForBundleID:bundleID]];
        }
    }
    _specifiers = items;
    return _specifiers;
}

- (NSNumber *)isProtected:(PSSpecifier *)specifier {
    id bundleID = [specifier propertyForKey:@"SBCPUWhitelistBundleID"];
    return @([bundleID isKindOfClass:[NSString class]] && [self.whitelist containsObject:bundleID]);
}

- (void)showMessage:(NSString *)message title:(NSString *)title {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    // A validation/save error may originate in an alert action, before UIKit
    // has finished dismissing that alert. Present the replacement only afterwards.
    if (self.presentedViewController) {
        __weak SBCPUPrefsWhitelistController *weakSelf = self;
        [self dismissViewControllerAnimated:YES completion:^{
            [weakSelf presentViewController:alert animated:YES completion:nil];
        }];
    } else {
        [self presentViewController:alert animated:YES completion:nil];
    }
}

- (void)applyProtection:(BOOL)protect bundleID:(NSString *)bundleID {
    if (![bundleID isKindOfClass:[NSString class]] || bundleID.length == 0) return;
    // Read the latest value for each edit rather than saving a stale page snapshot.
    CFPreferencesSynchronize(SBCPUPrefsWhitelistDomain,
        kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    id previousValue = SBCPUPrefsWhitelistValue();
    BOOL invalid = NO;
    NSArray<NSString *> *previousIDs = SBCPUPrefsValidWhitelist(previousValue, &invalid);
    NSMutableArray<NSString *> *updated = [previousIDs mutableCopy];
    if (protect) {
        if (![updated containsObject:bundleID]) [updated addObject:bundleID];
    } else {
        [updated removeObject:bundleID];
    }
    if (![updated isEqualToArray:previousIDs]) {
        // Deliberately write only this key, never the tweak's global preferences.
        CFPreferencesSetValue(SBCPUPrefsWhitelistKey, (__bridge CFArrayRef)updated,
            SBCPUPrefsWhitelistDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        if (!CFPreferencesSynchronize(SBCPUPrefsWhitelistDomain,
            kCFPreferencesCurrentUser, kCFPreferencesAnyHost)) {
            // Best-effort restore, including an originally absent or malformed value.
            CFPreferencesSetValue(SBCPUPrefsWhitelistKey, (__bridge CFPropertyListRef)previousValue,
                SBCPUPrefsWhitelistDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
            CFPreferencesSynchronize(SBCPUPrefsWhitelistDomain,
                kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
            self.whitelist = previousIDs;
            self.invalidWhitelist = invalid;
            [self rebuildWhitelistUI];
            [self showMessage:@"无法同步白名单，已尝试恢复原值。请稍后重新进入此页面重试。"
                title:@"保存失败"];
            return;
        }
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            CFSTR("com.yourname.sbcpufloating.prefschanged"), NULL, NULL, YES);
    }
    [self readWhitelist];
    [self rebuildWhitelistUI];
}

- (void)setProtected:(NSNumber *)value specifier:(PSSpecifier *)specifier {
    id rawID = [specifier propertyForKey:@"SBCPUWhitelistBundleID"];
    if (![rawID isKindOfClass:[NSString class]] || [rawID length] == 0
        || ![value respondsToSelector:@selector(boolValue)]) return;
    NSString *bundleID = [rawID copy];
    if ([value boolValue]) {
        [self applyProtection:YES bundleID:bundleID];
        return;
    }
    // Until explicitly confirmed, the persisted protection remains enabled.
    [self rebuildWhitelistUI];
    if (self.presentedViewController) return;
    NSString *message = [NSString stringWithFormat:@"确定将 %@（%@）移出白名单？之后锁屏清理将不再保护此应用。",
        [self displayNameForBundleID:bundleID], bundleID];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"移出白名单"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    __weak SBCPUPrefsWhitelistController *weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel
        handler:^(__unused UIAlertAction *action) {
            [weakSelf readWhitelist];
            [weakSelf rebuildWhitelistUI];
        }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"移除" style:UIAlertActionStyleDestructive
        handler:^(__unused UIAlertAction *action) {
            [weakSelf applyProtection:NO bundleID:bundleID];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)addBundleID {
    if (self.presentedViewController) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"手动添加应用"
        message:@"输入应用的完整 Bundle ID（如 com.example.app）。不要求应用当前已安装；如能读取应用列表，将显示对应名称。"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"com.example.app";
        field.keyboardType = UIKeyboardTypeASCIICapable;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak SBCPUPrefsWhitelistController *weakSelf = self;
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"添加" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            SBCPUPrefsWhitelistController *controller = weakSelf;
            if (!controller) return;
            NSString *bundleID = [weakAlert.textFields.firstObject.text
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            NSCharacterSet *invalidCharacters = [[NSCharacterSet characterSetWithCharactersInString:
                @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"] invertedSet];
            NSArray *parts = [bundleID componentsSeparatedByString:@"."];
            if (bundleID.length == 0 || bundleID.length > 255 || parts.count < 2
                || [parts containsObject:@""]
                || [bundleID rangeOfCharacterFromSet:invalidCharacters].location != NSNotFound) {
                [controller showMessage:@"请输入有效的完整 Bundle ID：至少两段，以点分隔，仅包含英文字母、数字、点、连字符或下划线。"
                    title:@"Bundle ID 无效"];
                return;
            }
            [controller readWhitelist];
            if ([controller.whitelist containsObject:bundleID]) {
                [controller rebuildWhitelistUI];
                [controller showMessage:[NSString stringWithFormat:@"%@ 已在白名单中。", bundleID]
                    title:@"已受保护"];
                return;
            }
            [controller applyProtection:YES bundleID:bundleID];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)refreshApplications {
    [self readWhitelist];
    if (self.scanning) {
        [self rebuildWhitelistUI];
        return;
    }
    self.scanning = YES;
    self.scanMessage = @"正在读取应用列表…仍可使用上方按钮手动添加 Bundle ID。";
    [self rebuildWhitelistUI];
    __weak SBCPUPrefsWhitelistController *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            NSString *message = nil;
            NSDictionary<NSString *, NSString *> *names = SBCPUPrefsScanWhitelistApps(&message);
            dispatch_async(dispatch_get_main_queue(), ^{
                SBCPUPrefsWhitelistController *controller = weakSelf;
                if (!controller) return;
                controller.scanning = NO;
                controller.applicationNames = names;
                controller.scanMessage = message;
                // Never let scan completion overwrite edits made during the scan.
                [controller readWhitelist];
                [controller rebuildWhitelistUI];
            });
        }
    });
}

@end
