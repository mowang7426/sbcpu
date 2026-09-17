# SBCPU V4.35 — Native Glass Host / Expansion Fix

Based on the supplied V4.34 project.

Changes:
- Keeps `CCLiquidGlassView` directly inside `SBCPUFloatingView`, using the floating view itself as `hostView`.
- Stops overriding the private glass view's cornerRadius/masksToBounds.
- Removes the extra sheen/boost/edge glass overlays from the native-glass path.
- Native glass frame is synchronized from the floating view bounds only; it never changes the floating view's size.
- Replaces spring expansion/collapse with non-overshooting ease animations to eliminate the visible second enlargement.
- Keeps the legacy UIBlurEffect only as fallback when native glass is unavailable or disabled.
- The native class is still a private iOS API; actual Liquid Glass rendering depends on the runtime/system context.
