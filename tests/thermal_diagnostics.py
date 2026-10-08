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
for required in ['telemetry[@"routes"]', 'telemetry[@"events"]', 'telemetry[@"config"]', 'telemetry[@"lastLoadSucceeded"]', 'telemetry[@"revision"]', '@"stale"', '观测距今', '核心函数调用与分支结果', '核心近期事件', 'Hook 安装与调用证据']:
    assert required in source, required
assert 'SBCPUThermalDiagnosticsController.m' in (root / 'sbcpuprefs/Makefile').read_text()
# Telemetry is the approved core-only change; all non-observational source stays exact.
baseline = subprocess.check_output(['git', 'show', '57bb6b9:SBCPUThermal.x'], cwd=root, text=True).rstrip('\n')
def strip_observation(text):
    return '\n'.join(line for line in text.splitlines() if 'SBCT' not in line and 'SBCPUThermalTelemetry.h' not in line and 'SBCPUThermalScreenIsLocked(void);' not in line and 'SBCPUThermalScreenIsBlanked(void);' not in line)
assert strip_observation(source := (root / 'SBCPUThermal.x').read_text()) == baseline
telemetry = (root / 'SBCPUThermalTelemetry.h').read_text()
for required in ['configLoaded', 'TEvents.count > 80', 'data.length > 131072', 'QOS_CLASS_UTILITY', 'DISPATCH_QUEUE_SERIAL', '3 * NSEC_PER_SEC', 'atomic_compare_exchange_strong_explicit', 'TGeneration', 'O_EXCL | O_NOFOLLOW', 'fchmod(fd, 0640)', 'fchown(fd, 0, 501)', 'rename(tmp.fileSystemRepresentation', 'method_getImplementation', 'dladdr', '效果未知']:
    assert required in telemetry, required
for forbidden in ['dispatch_source_create(', 'NSTimer', 'notify_post(', 'notify_set_state(', 'MSHookMessageEx(', 'MSHookFunction(']:
    assert forbidden not in telemetry, forbidden
heartbeat = source.split('static void publishThermalEngineHeartbeat(void) {', 1)[1].split('static void startThermalEngineHeartbeat', 1)[0]
assert 'TSchedule' not in heartbeat and 'TNote' not in heartbeat, 'telemetry must not piggyback continuous heartbeat I/O'
assert source.index('TConfig(d);') > source.index('g_userSelectedPowerMode = selected;'), 'successful load evidence must follow actual config application'
assert 'TFailedConfig(d);' in source, 'failed reads still publish meaningful error/retained state'
print('PASS: telemetry-only diagnostics wiring, bounded read, honest unknown states, and core behavior guard')
