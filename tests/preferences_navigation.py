#!/usr/bin/env python3
"""Protect Settings root/detail routing, including the actual packaged resources."""
import argparse
import pathlib
import plistlib
import re
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
ROOT_CLASS = 'SBCPUPrefsRootListController'


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
    text_only = [r for r in rows if r.get('detail') == 'SBCPUTextOnlyController']
    assert len(text_only) == 1 and text_only[0]['cell'] == 'PSLinkCell' and text_only[0]['isController'] is True


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
assert 'openThermalDiagnostics' not in source
assert 'pushViewController:' not in source, 'Root must never auto-open a detail'
assert 'self.title = @"灵动监测"' in method(source, 'viewWillAppear')
assert 'self.navigationItem.title = @"灵动监测"' in method(source, 'viewWillAppear')
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
print('PASS: native settings root and remaining detail navigation preserved')
