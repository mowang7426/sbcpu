#!/usr/bin/env python3
"""Source/package wiring guards, not a claim of device compositor verification."""
import argparse
from pathlib import Path
import plistlib
import re

root = Path(__file__).resolve().parents[1]
text = (root / 'Tweak.xm').read_text()
controller = (root / 'sbcpuprefs/SBCPUTextOnlyController.m').read_text()
page = plistlib.loads((root / 'sbcpuprefs/Resources/TextOnly.plist').read_bytes())
rows = page['items']
assert next(r for r in rows if r.get('key') == 'floatingTextOnlyMode')['default'] is False
font = next(r for r in rows if r.get('key') == 'floatingTextOnlyFontSize')
assert font['cell'] == 'PSSliderCell' and (font['min'], font['max'], font['default']) == (8, 24, 13)
for action in ('moveUp','moveDown','moveLeft','moveRight','topLeft','topCenter','topRight','editX','editY','automaticText','customText','whiteText','blackText'):
    assert any(r.get('action') == action for r in rows), action
    assert '- (void)' + action in controller, action
assert 'SBCPUTextOnlyController.m' in (root / 'sbcpuprefs/Makefile').read_text()
assert 'getBoolPref(CFSTR("floatingTextOnlyMode"), NO)' in text
keys = ('CPU', 'Frequency', 'FPS', 'Battery', 'Temperature', 'Current', 'SIM1', 'SIM2')
for suffix in keys:
    key = 'floatingTextOnlyShow' + suffix
    entry, = [r for r in rows if r.get('key') == key]
    assert entry['cell'] == 'PSSwitchCell' and entry['default'] is True
    assert entry['defaults'] == 'com.yourname.sbcpufloating'
    assert entry['get'] == 'getPreferenceValue:' and entry['set'] == 'setPreferenceValue:specifier:'
    assert f'getBoolPref(CFSTR("{key}"), YES)' in text
assert 'notify_post("com.yourname.sbcpufloating.prefschanged")' in controller
assert 'SBCPUTextOnlyRow(fields,' in text
assert 'textOnlyLabel.numberOfLines = 1' in text
assert 'SBCPUTextOnlyMinimumScale(naturalWidth, available)' in text
assert 'textOnlyLabel.hidden = (textOnlyLabel.text.length == 0)' in text
assert 'textOnlySignals = (textOnlyShowSIM1 || textOnlyShowSIM2) ? readAllSimSignals() : @[];' in text
assert '(floatingTextOnlyMode && textOnlyShowFPS)' in text
assert 'if (floatingTextOnlyMode) {' in text[text.index('// Reuse the existing refresh tick.'):][:260]
assert 'if (floatingTextOnlyMode)' in text[text.index('- (void)updateLayoutWithShowCpuFreq:'):]
assert 'SBCPUTextOnlyDockEffective(statusBarDockEnable, floatingTextOnlyMode)' in text
assert 'SBCPUTextOnlyTop(floatingTextOnlyMode, safeTop, sbcpuStatusBarDockEffective())' in text
start = text.index('static void applyTextOnlyTextFilter(void) {')
end = text.index('static void updateFloatingSize(void) {', start)
mode = text[start:end]
assert 'differenceBlendMode' not in text
assert 'textOnlyLabel.layer.compositingFilter = nil;' in mode
assert 'SBCPUTextUsesWhite((int)floatingTextOnlyColor, style) ? UIColor.whiteColor : UIColor.blackColor' in mode
assert 'UIScreen.mainScreen.traitCollection.userInterfaceStyle' in mode
assert 'cpuWindow.traitCollection.userInterfaceStyle' in mode
trait = text[text.index('- (void)traitCollectionDidChange:'):text.index('// 清理反色定时器')]
assert trait.index('applyTextOnlyTextFilter();') < trait.index('if (liquidGlassEnabled)')
assert 'SBCPUTextDecodeRGBA(getArrayPref(CFSTR("floatingTextOnlyRGBA"), nil))' in text
assert 'UIColorPickerViewControllerDelegate' in controller and 'picker.supportsAlpha = NO' in controller
assert 'UIModalPresentationFormSheet' in controller and 'presentationControllerDidDismiss:' in controller
assert 'UITableViewCellAccessoryCheckmark' in controller
selection = controller[controller.index('- (void)colorPickerViewController:'):controller.index('- (void)colorPickerViewControllerDidFinish:')]
assert 'writeValues' not in selection and 'commitPickerColor' not in selection
colors = [r for r in rows if 'textColorMode' in r]
assert [r['textColorMode'] for r in colors] == [0, 3, 1, 2]
assert colors[0]['label'] == '自动模式' and colors[1]['label'] == '自定义文字颜色'
assert 'monospacedSystemFontOfSize:floatingTextOnlyFontSize' in mode
assert 'NSTimer' not in mode and 'snapshotView' not in mode and 'sampleBackgroundLuminance' not in mode
assert 'textOnlySnapshotCenter' in mode and 'textOnlyHiddenSnapshot' in mode
assert 'statusBarDockEnable =' not in mode and 'SavePreferencesAndNotify' not in mode
for label in ('cpuValueLabel','cpuFreqLabel','fpsValueLabel','batteryValueLabel','tempValueLabel'):
    assert label in mode
assert 'SBCPUTextOnlyCurrentText(textOnlyBatteryCurrent' in mode
assert 'floatingView.thermalStatusLabel.text' not in mode
assert 'floatingView.statusLabel.text' not in mode
assert 'floatingView.signalLabel.text' not in mode
adaptive = text[text.index('- (void)applyAdaptiveTextColors {'):text.index('- (CGFloat)sampleBackgroundLuminance')]
assert adaptive.index('if (floatingTextOnlyMode)') < adaptive.index('sampleBackgroundLuminance')
assert 'if (floatingTextOnlyMode) return;' in text[text.index('- (void)collapseToEdgeAnimated:(BOOL)animated {'):][:150]
assert 'else if (rememberPositionEnable)' in text
# No accidental mutation of core control sources.
assert 'SBCPUThermal' not in controller and 'SBChargePatch' not in controller
parser = argparse.ArgumentParser()
parser.add_argument('--staged', type=Path)
args = parser.parse_args()
if args.staged:
    bundle, = args.staged.rglob('SBCPUPrefs.bundle')
    assert plistlib.loads((bundle / 'TextOnly.plist').read_bytes()) == page
    info = plistlib.loads((bundle / 'Info.plist').read_bytes())
    assert info['NSPrincipalClass'] == 'SBCPUPrefsRootListController'
    assert b'SBCPUTextOnlyController' in (bundle / info['CFBundleExecutable']).read_bytes()
print('PASS: text-only controls, default OFF, presentation isolation, fallback and packaged navigation')
