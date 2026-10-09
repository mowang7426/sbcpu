# Thermal-free baseline (2026-10-09)

This branch removes the old thermal control subsystem. It does not integrate CPUthermal source or install a replacement engine. Older thermal README/merge notes are historical references, not current feature descriptions.

## Removed

- `SBCPUThermal` build/injection target, `SBCPUThermal.x`, recovered hooks, pressure/path/telemetry/writer-status helpers; dormant `MitigationHook.xm` and `SBCPUMitigation.plist`.
- Settings for engine enable, performance/power modes (including extreme full-frequency), pressure protection, lock-screen low-power override, nominal recovery, dimming prevention and warning suppression.
- Thermal diagnostics pages, mode selector, UI-only policy helpers, heartbeat/status label and timer/init in the floating implementation. No artificial “core running after 8 seconds” status remains.
- Thermal-only tests replaced by `tests/thermal_removed.py`; navigation/branding tests retain checks for unrelated UI. The stale screen-safety test already referenced the absent `SBCPUForce120.xm`; it is removed, not treated as runtime coverage.

The old injection was in Apple's `thermalmonitord` (the dormant mitigation filter additionally named `powerd`); there was no separate thermal launch daemon to uninstall. No thermal daemon reload is performed. The independent charge daemon and its existing install/uninstall lifecycle remain.

## Retained

Floating display, CPU/FPS/frequency and raw battery-temperature reporting, text-only layout/color, double-tap position lock/haptics, plugin scanner, lock cleanup/whitelist, independent charging management/temperature-based charge hold, native respring handling and liquid-glass features are not thermal control and remain.

Control Center root-path lookup is extracted into `include/SBCPUPaths.h`; its jailbreak-root selection now uses `SBCPUFloating.dylib`, not the retired thermal library. Shared `settingsChanged` / `prefschanged` notifications stay for other features. The `smartThermalChargeEnable`, `smartThermalUpperC`, `smartThermalLowerC` keys belong to independent charging and remain.

## Upgrade safety and data

- The DEB no longer contains a thermal injection target/filter. Tests inspect extracted packages to prevent accidental stale payload inclusion.
- dpkg removes old package-owned files on upgrade. `postinst` additionally removes only the exact `SBCPUThermal.{dylib,plist}` / `SBCPUMitigation.{dylib,plist}` names in the root validated by this package's charge daemon; it does not search other jailbreak installations or delete directories.
- Removing files does not unload already-resident hooks. Reboot the device after upgrading; re-enable the jailbreak if necessary. A SpringBoard respring alone is not proof that hooks in another daemon have unloaded. The installer deliberately does not kill/reload `thermalmonitord` or force a phone reboot.
- Existing shared preferences are preserved, not wholesale deleted. Old thermal-only keys (`thermalEngineEnabled`, `powerMode`, `thermalPressureAutoProtectionEnabled`, `thermalLockScreenLowPowerEnabled`, `thermalNominalAutoRecoveryEnabled`, `thermalPreventDimmingEnabled`, `thermalBlockNotifPopup`, `thermalEngineStartupAt`, legacy `highPerformanceModeEnabled` / `thermalPuppetValue`) and old heartbeat/telemetry files are inert; the baseline neither reads nor writes them. This avoids clobbering unrelated preferences or historical evidence. A future rewrite must explicitly migrate or ignore these keys rather than silently reactivate them.
- Source history, including the user's `SBCPUThermal.x`, is preserved at `backup/pre-thermal-removal-20261009-9b78a41` (commit `9b78a41`). No hard reset or force push is used. Historical unbuilt backup files and docs are not runtime code or package payload.

## Validation scope

Python structural regressions and portable C/C++ policy tests can run on Linux; Objective-C/Foundation tests and Rootless/RootHide builds run on macOS GitHub Actions. Successful builds demonstrate packaging/compile regressions, not on-device temperature, charging or hook-unload verification. No phone action is executed by the development tools.
