# SBCPU V4.32 — Native CCLiquidGlassView integration

This build integrates the user-provided iOS 26 `CCLiquidGlassView` path into the SBCPU floating panel.

## Behavior
- Runtime-detects `CCLiquidGlassView` via `NSClassFromString`, so older systems fall back to the existing glass implementation.
- Creates the native glass with `initWithFrame:hostView.bounds`, inserts it at index 0 of the floating host, and calls `updateForHostView:preferredStyle:1`, matching the supplied snippet.
- The existing `UIVisualEffectView` remains as a transparent content carrier. When native glass is available, the old CABackdrop/specular overlay layers are disabled so they do not cover the native material.
- Native glass frame/corner radius is updated whenever the floating panel changes size, including expand/collapse transitions.
- The existing Liquid Glass preference switch controls the native view too.
- If the private class or required selector is unavailable, SBCPU keeps its previous CABackdrop/UIBlur fallback.

## Important
`CCLiquidGlassView` is a private system class. Its availability and visual behavior are OS-build dependent. The code intentionally does not link against a private framework; it discovers the class at runtime to reduce startup/link risks.
