#!/usr/bin/env python3
"""Protect Settings root/detail routing, including the actual packaged resources."""
import argparse
import pathlib
import plistlib
import re
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
ROOT_CLASS = 'SBCPUPrefsRootListController'
DETAIL_CLASS = 'SBCPUThermalDiagnosticsController'


def read(path):
    return plistlib.loads(path.read_bytes())


def check_resources(entry, info, settings):
    assert entry['entry']['detail'] == ROOT_CLASS
    assert entry['entry']['bundle'] == 'SBCPUPrefs'
    assert entry['entry']['isController'] is True
    assert entry['entry']['cell'] == 'PSLinkCell'
    assert info['NSPrincipalClass'] == ROOT_CLASS
    assert info['CFBundleExecutable'] == 'SBCPUPrefs'
    assert settings['title'] == '灵动监测'
    rows = settings['items']
    diagnostics = [r for r in rows if r.get('action') == 'openThermalDiagnostics']
    assert len(diagnostics) == 1
    assert diagnostics[0] == {'cell': 'PSButtonCell', 'label': '诊断报告', 'action': 'openThermalDiagnostics'}
    assert DETAIL_CLASS not in repr(entry) and DETAIL_CLASS not in repr(settings)
    text_only = [r for r in rows if r.get('detail') == 'SBCPUTextOnlyController']
    assert len(text_only) == 1 and text_only[0]['cell'] == 'PSLinkCell' and text_only[0]['isController'] is True
    position = rows.index(diagnostics[0])
    assert rows[position - 1]['key'] == 'thermalBlockNotifPopup'
    assert rows[position + 1]['action'] == 'openMoWangSource'
    assert next(r for r in reversed(rows[:position]) if r.get('cell') == 'PSGroupCell')['label'] == '修改温控 bug'
    # Every original row, key, default, detail link, footer and ordering is retained.
    baseline = plistlib.loads(subprocess.check_output(
        ['git', 'show', '31e0f39:sbcpuprefs/Resources/Root.plist'], cwd=ROOT))
    assert {**settings, 'items': [r for r in rows if r not in diagnostics and r.get('detail') != 'SBCPUTextOnlyController']} == baseline


def method(source, name):
    match = re.search(r'-\s*\([^)]*\)' + name + r'[^\{]*\{', source)
    assert match, name
    start = match.end()
    depth = 1
    end = start
    while depth:
        assert end < len(source)
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end - 1]


parser = argparse.ArgumentParser()
parser.add_argument('--staged', type=pathlib.Path)
args = parser.parse_args()
entry = read(ROOT / 'sbcpuprefs/entry.plist')
info = read(ROOT / 'sbcpuprefs/SBCPUPrefs-Info.plist')
settings = read(ROOT / 'sbcpuprefs/Resources/Root.plist')
check_resources(entry, info, settings)
source = (ROOT / 'sbcpuprefs/SBCPUPrefsRootListController.m').read_text()
assert 'loadSpecifiersFromPlistName:@"Root" target:self' in method(source, 'specifiers')
action = method(source, 'openThermalDiagnostics')
assert 'self.navigationController' in action
assert 'navigationController.topViewController != self' in action
assert '[[SBCPUThermalDiagnosticsController alloc] init]' in action
assert '[navigationController pushViewController:controller animated:YES]' in action
assert source.count('openThermalDiagnostics') == 1, 'No automatic action calls'
assert source.count('pushViewController:') == 1, 'Only the explicit button may push'
assert source.count('[SBCPUThermalDiagnosticsController alloc]') == 1
assert 'self.title = @"灵动监测"' in method(source, 'viewWillAppear')
assert 'self.navigationItem.title = @"灵动监测"' in method(source, 'viewWillAppear')
assert '- (void)openThermalDiagnostics;' in (ROOT / 'sbcpuprefs/SBCPUPrefsRootListController.h').read_text()
assert '@interface SBCPUThermalDiagnosticsController : PSListController' in (ROOT / 'sbcpuprefs/SBCPUThermalDiagnosticsController.h').read_text()
assert 'self.title = @"诊断报告"' in (ROOT / 'sbcpuprefs/SBCPUThermalDiagnosticsController.m').read_text()
makefile = (ROOT / 'sbcpuprefs/Makefile').read_text()
assert re.search(r'^SBCPUPrefs_FILES = SBCPUPrefsRootListController\.m ', makefile, re.M)
assert 'cp SBCPUPrefs-Info.plist $(THEOS_STAGING_DIR)/Library/PreferenceBundles/SBCPUPrefs.bundle/Info.plist' in makefile
if args.staged:
    bundles = list(args.staged.rglob('SBCPUPrefs.bundle'))
    entries = list(args.staged.rglob('PreferenceLoader/Preferences/SBCPUPrefs.plist'))
    assert len(bundles) == len(entries) == 1, (bundles, entries)
    bundle = bundles[0]
    packaged_entry = read(entries[0])
    packaged_info = read(bundle / 'Info.plist')
    packaged_root = read(bundle / 'Root.plist')
    check_resources(packaged_entry, packaged_info, packaged_root)
    assert packaged_entry == entry, 'Staged entry differs from source'
    assert packaged_root == settings, 'Staged root overwritten or stale'
    executable = bundle / packaged_info['CFBundleExecutable']
    assert executable.is_file() and executable.stat().st_size > 0
    print('PASS: DEB entry, principal class, complete Root.plist and executable:', args.staged)
print('PASS: full settings root preserved; diagnostics is click-only native push, never automatic')
