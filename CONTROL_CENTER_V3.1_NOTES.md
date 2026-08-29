# SBCPUFloating V3.1 - Control Center module

This revision fixes the previous V3.1 Control Center build failure.

## Build fix
The iPhoneOS 16.5 SDK used by the GitHub Actions workflow does not expose
`ControlCenterUIKit/CCUIContentModule.h`. The module therefore uses local
compatibility declarations instead of importing that unavailable private
header. The bundle still implements the `CCUIContentModule` protocol by name,
which is resolved by the running Control Center/CCLess environment.

## Functional behavior
- Control Center module is installed to `/Library/ControlCenter/Bundles`.
- Module identifier: `com.sbcpu.floating.cc`.
- Toggle reads/writes the existing `com.yourname.sbcpufloating` `isEnabled` preference.
- Toggle posts `com.yourname.sbcpufloating.prefschanged`, which is already consumed
  by the main SpringBoard tweak.
- The original 120Hz feature and other SBCPUFloating features are not removed.
