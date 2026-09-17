# SBCPU V4.40 SmartCharge / Daemon Fix

- launchd daemon uses unconditional `KeepAlive=true` so unexpected exits are restarted.
- postinst explicitly bootstrap/enable/kickstart the daemon.
- SpringBoard no longer permanently caches a failed daemon socket probe.
- CH0I smart-stop no longer rejects a real cable because `CH0R.bit1` transiently reports No VBUS.
- CH0I=1 is verified by SMC readback with up to 3 retries.
- CH0I=0 recovery is verified as well.
- Protocol version bumped to 4 so stale daemons are detectable.
- Existing V4.38 floating-window fixes are preserved.
