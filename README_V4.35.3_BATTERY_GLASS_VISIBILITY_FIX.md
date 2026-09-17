# SBCPU V4.35.3 — Battery Visibility + Native Glass Surface Visibility

Based on V4.35.2.

## Changes
- Widened the battery column from 52pt to 72pt so the battery percentage remains readable while charging.
- The main battery label now shows only the percentage; session mAh is no longer appended to that label, preventing `adjustsFontSizeToFitWidth` from shrinking it.
- Increased the battery value font size and minimum scale factor.
- Kept `CCLiquidGlassView` as the floating view's only native glass surface; no second blur/glass overlay was added.
- Added a subtle border to the existing native glass surface so the material boundary is more visible.
- Kept the native glass corner radius synchronized with the floating view.

## Important limitation
`CCLiquidGlassView` is an iOS private class. The code can call the interface supplied by the user, but the exact full Liquid Glass rendering depends on the runtime implementation and context provided by the target iOS build. This version does not claim to recreate Apple's internal Liquid Glass engine.
