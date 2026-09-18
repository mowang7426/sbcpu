#import "SBCPUChargePreferencesCommon.h"
#import <CoreFoundation/CoreFoundation.h>
#include <string.h>
#include <notify.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <errno.h>
#include "../include/SBCPUChargeProtocol.h"

@implementation SBCPUChargePreferencesCommon

+ (id)valueForKey:(NSString *)key defaultValue:(id)defaultValue {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:@SB_PREF_FILE];
    id v = d[key];
    if (v) return v;

    CFPropertyListRef cfv = CFPreferencesCopyValue((__bridge CFStringRef)key,
                                                   CFSTR(SB_PREF_DOMAIN),
                                                   kCFPreferencesCurrentUser,
                                                   kCFPreferencesAnyHost);
    if (cfv) return CFBridgingRelease(cfv);
    return defaultValue;
}

+ (void)setValue:(id)value forKey:(NSString *)key {
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:@SB_PREF_FILE];
    if (!d) d = [NSMutableDictionary dictionary];
    if (value) d[key] = value;
    else [d removeObjectForKey:key];

    // V1 keeps the existing SBCPU smart-charge master switch as the single
    // source of truth. This prevents an old chargeLimitEnabled=YES value from
    // silently re-enabling the daemon after smartChargeEnable is turned off.
    if ([key isEqualToString:@"smartChargeEnable"]) {
        d[@"chargeLimitEnabled"] = @([value boolValue]);
    }

    // Keep the hysteresis interval valid when sliders are edited independently.
    if ([key isEqualToString:@"smartChargeUpperLimit"]) {
        NSInteger upper = [value integerValue];
        NSInteger lower = [d[@"smartChargeLowerLimit"] integerValue];
        if (upper <= lower) d[@"smartChargeLowerLimit"] = @(MAX(0, upper - 1));
    } else if ([key isEqualToString:@"smartChargeLowerLimit"]) {
        NSInteger lower = [value integerValue];
        NSInteger upper = [d[@"smartChargeUpperLimit"] integerValue];
        if (lower >= upper) d[@"smartChargeUpperLimit"] = @(MIN(100, lower + 1));
    }

    [d writeToFile:@SB_PREF_FILE atomically:YES];

    // Persist to both stores and synchronize immediately so PreferenceLoader
    // does not fall back to the plist defaults after navigation.
    CFPreferencesSetValue((__bridge CFStringRef)key,
                          (__bridge CFPropertyListRef)value,
                          CFSTR(SB_PREF_DOMAIN),
                          kCFPreferencesCurrentUser,
                          kCFPreferencesAnyHost);
    CFPreferencesSynchronize(CFSTR(SB_PREF_DOMAIN),
                             kCFPreferencesCurrentUser,
                             kCFPreferencesAnyHost);

    // Keep the SpringBoard-side cached settings in sync immediately, even when
    // the user changes values from these child preference controllers.
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                          CFSTR("com.yourname.sbcpufloating.prefschanged"),
                                          NULL, NULL, YES);
    notify_post("com.yourname.sbcpufloating/settingsChanged");
}

+ (BOOL)daemonRunning {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return NO;
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, SB_SOCKET_PATH, sizeof(addr.sun_path) - 1);
    BOOL ok = connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0;
    close(fd);
    return ok;
}

+ (void)redecideDaemon {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return;
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, SB_SOCKET_PATH, sizeof(addr.sun_path) - 1);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return;
    }

    sb_cmd_t cmd = {0};
    cmd.magic = SB_MAGIC;
    cmd.cmd = SB_CMD_REDECIDE;
    size_t done = 0;
    while (done < sizeof(cmd)) {
        ssize_t n = write(fd, (uint8_t *)&cmd + done, sizeof(cmd) - done);
        if (n > 0) done += (size_t)n;
        else if (n < 0 && errno == EINTR) continue;
        else { close(fd); return; }
    }

    sb_resp_t resp = {0};
    done = 0;
    while (done < sizeof(resp)) {
        ssize_t n = read(fd, (uint8_t *)&resp + done, sizeof(resp) - done);
        if (n > 0) done += (size_t)n;
        else if (n < 0 && errno == EINTR) continue;
        else break;
    }
    close(fd);
}

+ (NSString *)daemonStatusText {
    if (![self daemonRunning]) return @"值守进程：未运行";
    return @"值守进程：运行中（由 launchd 托管）";
}

@end
