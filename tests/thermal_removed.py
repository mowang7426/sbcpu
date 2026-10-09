#!/usr/bin/env python3
"""A thermal-control-free baseline; temperature sensing/charge safety are retained."""
import argparse
import pathlib
import plistlib
import re
import subprocess
R = pathlib.Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('--staged', type=pathlib.Path)
args = p.parse_args()
removed = ['SBCPUThermal.x', 'SBCPUThermalRecovered.mm', 'SBCPUThermalRecovered.h',
           'SBCPUThermal.plist', 'SBCPUMitigation.plist', 'MitigationHook.xm',
           'SBCPUThermalTelemetry.h', 'include/SBCPUThermalPaths.h',
           'include/SBCPUThermalPressure.h', 'include/SBCPUTelemetryFormat.h',
           'include/SBCPUWriterStatus.h', 'sbcpuprefs/Resources/ThermalMode.plist']
for f in removed:
    assert not (R / f).exists(), f
for pattern in ['SBCPUThermal*']:
    assert not list((R / 'sbcpuprefs').glob(pattern))
for f in ['Makefile', 'sbcpuprefs/Makefile', 'Tweak.xm', 'CCRegistration.xm',
          'ControlCenter/SBCPUFloatingCCModuleViewController.m',
          'sbcpuprefs/SBCPUPrefsRootListController.m',
          'sbcpuprefs/SBCPUFloatingAdvancedController.m']:
    source = (R / f).read_text()
    for forbidden in ['SBCPUThermal', 'sbcputhermal', 'thermalStatusLabel',
                      'registerThermalHeartbeatListener', 'startThermalStatusTimer',
                      'thermalEngineEnabled', 'thermalBlockNotifPopup',
                      'thermalPreventDimmingEnabled', 'extremeFull']:
        assert forbidden not in source, (f, forbidden)
    assert not re.search(r'^\s*(?!#).*INSTALL_TARGET_PROCESSES\s*=.*thermalmonitord', source, re.M)
keys = {'thermalEngineEnabled', 'powerMode', 'thermalPressureAutoProtectionEnabled',
        'thermalLockScreenLowPowerEnabled', 'thermalNominalAutoRecoveryEnabled',
        'thermalPreventDimmingEnabled', 'thermalBlockNotifPopup'}
for f in (R / 'sbcpuprefs/Resources').glob('*.plist'):
    value = plistlib.loads(f.read_bytes())
    for row in value.get('items', []):
        assert row.get('key') not in keys, (f, row)
        assert 'SBCPUThermal' not in str(row)
        assert row.get('action') != 'openThermalDiagnostics'
# Protect every unrelated root item and its ordering against the backup baseline.
old = plistlib.loads(subprocess.check_output(['git', 'show', '9b78a41:sbcpuprefs/Resources/Root.plist'], cwd=R))
def retained(row):
    return (row.get('key') not in keys and row.get('detail') != 'SBCPUThermalModeController'
            and row.get('action') != 'openThermalDiagnostics' and row.get('label') != '修改温控 bug')
old['items'] = [r for r in old['items'] if retained(r)]
for row in old['items']:
    if 'footerText' in row:
        row['footerText'] = row['footerText'].replace('温控防暗屏不拦截系统熄屏、锁屏或热安全路径。', '')
assert plistlib.loads((R / 'sbcpuprefs/Resources/Root.plist').read_bytes()) == old
main = (R / 'Tweak.xm').read_text()
for kept in ['getBatteryTemperatureInternal', 'NSProcessInfoThermalStateCritical',
             'smartThermalChargeEnable', 'floatingTextOnlyMode', 'SBCPUFloatingLockPolicy.h',
             'getTotalCPUUsage', 'SBCPUFPSHelper']:
    assert kept in main, kept
# No filter in the source or built package may target thermalmonitord.
for f in R.rglob('*.plist'):
    if '.git' not in f.parts:
        assert 'thermalmonitord' not in f.read_text(errors='replace'), f
if args.staged:
    for f in args.staged.rglob('*'):
        assert not f.name.startswith(('SBCPUThermal', 'SBCPUMitigation')), f
        if f.suffix == '.plist':
            data = f.read_bytes()
            try: value = plistlib.loads(data)
            except Exception: continue
            assert 'thermalmonitord' not in str(value), f
    assert list(args.staged.rglob('SBCPUChargeDaemon')), 'Independent charge daemon missing'
    assert list(args.staged.rglob('SBCPUFloating.dylib')), 'Floating display missing'
print('PASS: no thermal control target/UI/telemetry/init; unrelated root rows and sensors retained')
