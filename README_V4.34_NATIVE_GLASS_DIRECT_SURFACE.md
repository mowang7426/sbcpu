# SBCPU V4.34 — Native Liquid Glass Direct Surface

Changes:
- CCLiquidGlassView is the floating view's primary background surface, not an overlay.
- UIVisualEffectView is only a fallback when native class is unavailable or Liquid Glass is disabled.
- Removed extra border/mask assumptions from the native glass view.
- Refresh native glass frame/style in layoutSubviews and after collapse/expand/layout changes.
- Extra legacy backdrop/specular/tint layers remain disabled to prevent a second frosted layer.
- Collapse/expand keeps the glass surface and content synchronized.

Note: CCLiquidGlassView is a private system class; whether it renders Apple's full Liquid Glass depends on the iOS build and the runtime host/context.
