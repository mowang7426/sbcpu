#!/usr/bin/env python3
"""UI wiring and unchanged RootHide path/core guards; not a device/path runtime test."""
from pathlib import Path
import hashlib
import plistlib

root = Path(__file__).resolve().parents[1]
read = lambda p: (root / p).read_text()
policy = read('sbcpuprefs/SBCPUThermalPreferenceUI.h')
controllers = ['sbcpuprefs/SBCPUPrefsRootListController.m',
               'sbcpuprefs/SBCPUFloatingAdvancedController.m']
for path in controllers:
    source = read(path)
    assert '#import "SBCPUThermalPreferenceUI.h"' in source
    assert 'SBCPUThermalPreferenceValue(SBCPUThermalReadPrefs(),' in source
    assert 'propertyForKey:@"default"' in source
    assert 'if (!SBCPUSaveThermalPreference(' in source
    failure = source.split('if (!SBCPUSaveThermalPreference(')[1].split('return;')[0]
    assert 'dispatch_async(dispatch_get_main_queue()' in failure
    assert '[self reloadSpecifiers]' in failure
    assert 'UIAlertController' in failure and 'presentViewController:alert' in failure
    assert '未保存' in failure and '未发送给温控核心' in failure
    assert 'SBCPUThermalWritePrefs(' not in source
    assert 'SBCPUThermalPostPowerMode(' not in source
assert policy.index('if (!SBCPUThermalWritePrefs(prefs)) return NO;') < policy.index('notify_post(')
assert policy.count('notify_post(') == 2
assert policy.index('notify_post(') < policy.index('SBCPUThermalPostPowerMode(prefs[key])')

items = plistlib.loads((root / 'sbcpuprefs/Resources/Root.plist').read_bytes())['items']
expected = dict(thermalEngineEnabled=True, thermalPressureAutoProtectionEnabled=True,
                thermalLockScreenLowPowerEnabled=True, thermalNominalAutoRecoveryEnabled=True,
                thermalPreventDimmingEnabled=False, thermalBlockNotifPopup=False)
for key, default in expected.items():
    specs = [sp for sp in items if sp.get('key') == key]
    assert specs and all(sp['default'] is default for sp in specs)
    assert all('PostNotification' not in sp for sp in specs), 'must not auto-publish failed writes'
text = '\n'.join(str(sp.get('footerText', '')) for sp in items)
assert '受温度保护总开关控制' in text and '不保证隐藏系统全屏高温保护界面' in text
assert all(sp.get('label') != '不弹出高温警告' for sp in items)

# Scope locks: the user's 76ac1de thermal hook and 630924b path algorithm stay exact.
for path, expected_blob in {
    'SBCPUThermal.x': '7912064af539cbac0feb1c408b133809819d0b7b',
    'include/SBCPUThermalPaths.h': '49f849a357f4299505fcf205880e5a086ab92c2b',
}.items():
    data = (root / path).read_bytes()
    blob = hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()
    assert blob == expected_blob, f'{path}: protected baseline changed'
paths = read('include/SBCPUThermalPaths.h')
assert '/var/mobile/Library/Preferences/com.yourname.sbcpufloating.plist' in paths
assert 'SBCPUThermalCurrentRootHideRoot' in paths and 'jbroot(' in paths
# Recording/respring read/write branches remain byte-identical to installed baseline.
current = read(controllers[0])
for method, expected_hash in {
    '- (id)getPreferenceValue:': 'd643d939908493a9c3c66370439841e90b17cd855e7fbc5c8fdfa68ada3f962d',
    '- (void)setPreferenceValue:': '8882fa3fac9f3caf0588dc8b130968385142f4939088620d58e271ea5760c493',
}.items():
    branch = current.split(method)[1].split('    if (SBCPUIsThermalPreference')[0]
    assert hashlib.sha256(branch.encode()).hexdigest() == expected_hash, 'recording/respring controls changed'
workflow = read('.github/workflows/build.yml')
assert 'python3 tests/thermal_preferences.py' in workflow and 'tests/thermal_preferences.m' in workflow
print('PASS: both UI routes, default plist values, failure reload/alert, unchanged recording/respring, thermal hook and RootHide paths (static only)')
