#!/usr/bin/env python3
"""Static safety/wiring guard; Objective-C behavioral tests run on macOS CI."""
import pathlib, plistlib, subprocess
root = pathlib.Path(__file__).resolve().parents[1]
items = plistlib.loads((root / 'sbcpuprefs/Resources/Root.plist').read_bytes())['items']
link = next(i for i, row in enumerate(items) if row.get('action') == 'openThermalDiagnostics')
assert items[link]['label'] == '诊断报告'
assert items[link]['cell'] == 'PSButtonCell'
assert 'detail' not in items[link] and 'isController' not in items[link]
assert items[link - 1]['key'] == 'thermalBlockNotifPopup'
assert items[link + 1]['action'] == 'openMoWangSource'
source = (root / 'sbcpuprefs/SBCPUThermalDiagnosticsController.m').read_text()
for forbidden in ['SBCPUThermalReadPrefs(', 'SBCPUThermalReadMutablePrefs(', 'notify_set_state(', 'notify_post(', 'writeToFile:', 'removeItemAtPath:', 'dispatch_source_create(', 'NSTimer', 'system(', 'popen(']:
    assert forbidden not in source, forbidden
for required in ['QOS_CLASS_UTILITY', '262144', 'SBCDRead(path, 64', 'self.events.count > 80', '运行：未知/待验证', 'Hook 安装：未验证', 'future', '未获得核心重载确认', 'copyDiagnostics', 'viewWillAppear:']:
    assert required in source, required
assert 'SBCPUThermalDiagnosticsController.m' in (root / 'sbcpuprefs/Makefile').read_text()
assert subprocess.check_output(['git', 'hash-object', 'SBCPUThermal.x'], cwd=root, text=True).strip() == '7912064af539cbac0feb1c408b133809819d0b7b'
# Protect the user's charging implementation and all existing core support files.
changed = subprocess.check_output(['git', 'diff', '31e0f39', '--name-only'], cwd=root, text=True).splitlines()
assert not any(p.startswith(('SBCPUCharge', 'SBCPUPowerd', 'SBCPUThermal.', 'SBCPUThermalRecovered', 'include/')) for p in changed)
print('PASS: thermal diagnostics wiring, read-only safety, bounded I/O/logs, byte-identical core and unchanged charge files')
