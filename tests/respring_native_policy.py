#!/usr/bin/env python3
"""Native request-only policy: source wiring + extracted decision regression.

Not an iOS authentication/device test. Compile only the hook's decision body
with stubs to verify OFF delegates (including native YES) and ON requests YES.
"""
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
key = 'respringPreserveNativeUnlockEnabled'
tweak = (root / 'Tweak.xm').read_text()
prefs = (root / 'sbcpuprefs/SBCPUPrefsRootListController.m').read_text()
items = plistlib.loads((root / 'sbcpuprefs/Resources/Root.plist').read_bytes())['items']
sp, = [item for item in items if item.get('key') == key]
assert sp['default'] is False and sp['cell'] == 'PSSwitchCell'
assert sp['defaults'] == 'com.yourname.sbcpufloating'
assert sp['get'] == 'getPreferenceValue:'
assert sp['set'] == 'setPreferenceValue:specifier:'
assert prefs.count(f'isEqualToString:@"{key}"') == 2
read = prefs.split(f'isEqualToString:@"{key}"')[1].split('return SBChargeRead')[0]
write = prefs.split(f'isEqualToString:@"{key}"')[2].split('screenRecordingHighFrameRateEnabled')[0]
assert 'CFPreferencesCopyValue' in read and ': @NO' in read
assert 'CFPreferencesSetValue' in write and 'CFPreferencesSynchronize' in write
assert 'kCFBooleanTrue : kCFBooleanFalse' in write
assert 'prefschanged' in write
assert 'com.yourname.sbcpufloating' in read and 'com.yourname.sbcpufloating' in write
hook = tweak.split('%group SBCPUNativeRespringPolicy')[1].split('#pragma mark')[0]
assert '%hook SBBootDefaults' in hook
body = re.search(r'- \(BOOL\)dontLockAfterCrash \{(.*?)\n\}', hook, re.S)[1]
assert f'getBoolPref(CFSTR("{key}"), NO)' in body
assert 'return %orig;' in body
ctor = tweak.split('%ctor {')[1]
sb = ctor.split('if ([processName isEqualToString:@"SpringBoard"]) {')[1]
assert sb.index('class_getInstanceMethod') < sb.index('%init(SBCPUNativeRespringPolicy)')
assert '@selector(dontLockAfterCrash)' in sb
for forbidden in ('setAuthenticated:', 'setAuthenticated:YES', 'wasUnlocked'):
    assert forbidden not in tweak, forbidden

# Compile the actual decision statements after replacing platform plumbing.
body = re.sub(r'\s*CFPreferencesSynchronize\([^;]+;', '', body)
body = body.replace(f'getBoolPref(CFSTR("{key}"), NO)', 'enabled')
body = body.replace('%orig', 'nativePolicy()')
source = '''#include <assert.h>
#define BOOL int
#define YES 1
#define NO 0
static int enabled, nativeResult, calls;
static int nativePolicy(void) { calls++; return nativeResult; }
static BOOL policy(void) { BODY }
int main(void) {
    for (int e=0; e<=1; e++) for (int n=0; n<=1; n++) {
        enabled=e; nativeResult=n; calls=0;
        assert(policy() == (e ? YES : n));
        assert(calls == (e ? 0 : 1));
    }
    return 0;
}
'''.replace('BODY', body)
compiler = shutil.which('cc') or shutil.which('clang')
assert compiler, 'C compiler required for extracted hook decision test'
with tempfile.TemporaryDirectory() as tmp:
    c = Path(tmp) / 'policy.c'
    c.write_text(source)
    binary = Path(tmp) / 'policy'
    subprocess.run([compiler, '-std=c11', '-Wall', '-Wextra', '-Werror', str(c), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
print('native respring policy: wiring + OFF/native YES/ON decision regressions passed (not device verification)')
