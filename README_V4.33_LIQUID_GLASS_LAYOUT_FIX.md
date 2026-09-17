# SBCPU V4.33 — Native Liquid Glass / Expansion Layout Fix

This version is based on V4.32 and addresses two issues observed after native `CCLiquidGlassView` integration:

1. **Delayed / second expansion after tapping the floating capsule**
   - Expansion no longer uses a spring animation with overshoot.
   - Final expanded bounds are calculated once, then animated with a non-overshooting ease-out curve.
   - Native Liquid Glass host refresh is deferred until the final bounds are committed.

2. **Weak / apparently inactive native Liquid Glass effect**
   - The supplied `CCLiquidGlassView` pattern is now followed more closely: create the view, insert at index 0, and only call `updateForHostView:` after the floating view has actually entered a UIWindow.
   - The native view is no longer forced to `backgroundColor = clearColor`, `opaque = NO`, or `masksToBounds = YES`, which could interfere with private rendering behavior.
   - Runtime logs report class discovery, selector availability, creation, and post-window refresh success/exception.

### Runtime diagnostics

Look for log lines beginning with:

`[SBCPUFloating][LiquidGlass]`

Important outcomes:
- `CCLiquidGlassView NOT FOUND` → system does not expose the class to this process; fallback remains active.
- `view CREATED, waiting for window/layout refresh` → class was found and instantiated.
- `refresh SUCCESS preferredStyle=1` → the supplied preferred-style path executed after the view entered the window.
- `refresh EXCEPTION` → the private implementation rejected the current host/context; the exact exception text is useful for the next revision.

### Fallback

If the private class is unavailable, SBCPU continues using its existing fallback glass implementation.
