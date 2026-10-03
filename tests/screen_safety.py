#!/usr/bin/env python3
"""Pure policy checks for screen recording and thermal display safety."""
from pathlib import Path

root = Path(__file__).parents[1]
force = (root / "SBCPUForce120.xm").read_text()
thermal = (root / "SBCPUThermal.x").read_text()
plist = (root / "sbcpuprefs/Resources/Root.plist").read_text()
assert 'screenRecordingHighFrameRateEnabled' in force
assert 'RPScreenRecorderRecordingDidStartNotification' in force
assert 'gScreenRecordingActive' in force
assert 'thermalPreventDimmingEnabled' in thermal
assert 'return NO;' in thermal[thermal.index('static BOOL thermalDimmingPreventionEnabled'):thermal.index('static CommonProduct *commonProductSnapshot')]
assert 'screenRecordingHighFrameRateEnabled' in plist
assert '<false/>' in plist
# A recording request must still honor OS power/thermal safety gates.
part = force[force.index('static BOOL shouldForce120'):force.index('typedef void (*SBCPUSetHighReasonIMP')]
assert 'isLowPowerModeEnabled' in part and 'NSProcessInfoThermalStateCritical' in part
print('screen safety policy checks passed')
