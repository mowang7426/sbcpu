# SBCPU V4.35.1 Build Fix

Fixed Theos `-Werror` build failure in `Tweak.xm`: removed the unused local `cornerRad` variable in `SBCPUFloatingView` initialization. No runtime behavior is changed by this fix.
