# SBCPU V4.36 — Metal Liquid Glass integration

This version replaces the previous CCLiquidGlassView experiment with the renderer from ceshi-main:
- CABackdropLayer live capture
- custom CAFilter registration
- backboardd Metal refraction shader
- dedicated `dylv.liquidglass.sbcpufloating` filter route

The existing SBCPU floating view remains the host/container; the liquid renderer is its background surface.

## Tuning
Settings > SBCPU Floating > 液态玻璃

Controls: strength, refraction, thickness, specular, dispersion, bezel, refractive index, quality.

## Important
Do not install the original ceshi/SBLiquidGlassBackboardd at the same time as this package. Both register the same QuartzCore custom filter machinery and can conflict.

The shader uses private QuartzCore/backboardd interfaces and OS-version-sensitive offsets inherited from the supplied renderer source. Test on the same iOS generation the source targets.


## Suggested starting point
- Strength 75%
- Refraction 65%
- Thickness 70%
- Specular 65%
- Dispersion 20%
- Bezel 90%
- Refractive Index 1.70
- Quality 100%

For a stronger liquid look, raise Refraction to 75–90% and Thickness to 75–85%; keep Dispersion modest to avoid colored fringes.
