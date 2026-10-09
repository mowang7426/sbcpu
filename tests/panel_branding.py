#!/usr/bin/env python3
"""Verify panel wiring, stable identifiers, retina resources and packaged assets."""
from pathlib import Path
import argparse
import plistlib
import struct

root = Path(__file__).resolve().parents[1]

def png_size(path):
    data = path.read_bytes()
    assert data[:8] == b'\x89PNG\r\n\x1a\n', path
    assert data[12:16] == b'IHDR', path
    return struct.unpack('>II', data[16:24])

def check_icons(folder, name, extension):
    for scale in (1, 2, 3):
        suffix = '' if scale == 1 else f'@{scale}x'
        path = folder / f'{name}{suffix}.{extension}'
        assert png_size(path) == (29 * scale, 29 * scale), path

check_icons(root / 'sbcpuprefs/Resources', 'icon', 'PNG')
check_icons(root / 'ControlCenter/resources', 'SettingsIcon', 'png')
assert png_size(root / 'assets/lingdong-icon-master.png') == (720, 720)
control = dict(line.split(': ', 1) for line in (root / 'control').read_text().splitlines() if ': ' in line)
assert control['Package'] == 'com.sbcpu.floating'
assert control['Name'] == '灵动监测'
with (root / 'sbcpuprefs/entry.plist').open('rb') as f:
    entry = plistlib.load(f)['entry']
assert entry['label'] == '灵动监测' and entry['bundle'] == 'SBCPUPrefs'
with (root / 'sbcpuprefs/Resources/Root.plist').open('rb') as f:
    page = plistlib.load(f)
assert page['title'] == '灵动监测'
forbidden = {'功能介绍', 'CPU / FPS', '▣ 电池 / 温度', '▣ 通知中心与悬浮聊天',
             '手势使用说明', '👆 单击浮窗', '👆 长按浮窗', '🤚 拖动浮窗'}
assert not forbidden.intersection(item.get('label', '') for item in page['items'])
assert any(item.get('label') == '浮窗全部设置' for item in page['items'])
assert not any(item.get('key') == 'thermalEngineEnabled' for item in page['items'])
text = (root / 'Tweak.xm').read_text()
assert 'SBCPUBatteryETAText(batInfo[@"SBCPUEtaSnapshot"]' in text
assert 'SBCPUBatteryAppendSample(etaHistory, etaSnapshot)' in text
assert 'SBCPUBatterySnapshot(pDict,' in text
assert 'SBCPUBatteryManufacturerFromProperties(pDict)' in text
assert 'batInfo[@"Manufacturer"] ?: @"Apple"' not in text
assert 'totalRAM_GB = 6' not in text
assert 'vm_stat.free_count + vm_stat.inactive_count + vm_stat.speculative_count' not in text
assert 'SBCPUStatusDotHidden(self.isCollapsed, sbcpuStatusBarDockEffective(), dotLandscape)' in text
assert '_miniCpuLabel.frame = CGRectMake(22, 5, 45, 18);' in text
charge = (root / 'sbcpuprefs/SBCPUChargeHistoryController.m').read_text()
assert 'initWithTitle:@"清空"' in charge
assert 'com.sbcpu.floating.charge-history.clear' in charge
assert '全部清空' in charge
assert 'onChargeHistoryClearRequested' in text
assert 'CFSTR("com.sbcpu.floating.charge-history.clear")' in text

parser = argparse.ArgumentParser()
parser.add_argument('--staged', type=Path)
args = parser.parse_args()
if args.staged:
    prefs = list(args.staged.rglob('SBCPUPrefs.bundle'))
    cc = list(args.staged.rglob('SBCPUFloatingCC.bundle'))
    entries = [p for p in args.staged.rglob('SBCPUPrefs.plist')
               if p.parent.name == 'Preferences']
    assert prefs and cc and entries
    for folder in prefs:
        check_icons(folder, 'icon', 'PNG')
    for path in entries:
        check_icons(path.parent, 'icon', 'PNG')
        with path.open('rb') as f:
            assert plistlib.load(f)['entry']['label'] == '灵动监测'
    for folder in cc:
        check_icons(folder, 'SettingsIcon', 'png')
        with (folder / 'Info.plist').open('rb') as f:
            info = plistlib.load(f)
        assert info['CFBundleIdentifier'] == 'com.sbcpu.floating.ccmodule'
        assert info['CFBundleDisplayName'] == '灵动监测'
print('panel wiring, branding and retina resource checks passed')
