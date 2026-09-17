# SBCPU V4.36.2

## Build fix

Fixed `Shared/LGHostRegistry.h`: the final `SBCPUFloating` entry in the `LG_HOST_REGISTRY(X)` X-macro now has the required trailing `\\` continuation. Without it, the following `enum`/macro expansion is parsed as C/Objective-C tokens outside the macro and causes errors such as `expected identifier`, `type specifier missing`, and `expected ';' after top level declarator`.

## Liquid Glass integration

No Liquid Glass renderer architecture was removed in this build-fix revision. The V4.36 chain remains:

`SBCPUFloating -> LGLiveBackdropView -> CABackdropLayer/CAFilter -> dylv.liquidglass.sbcpufloating -> SBCPULiquidGlassBackboardd -> Metal shader`

## Validation

- `LGHostRegistry.h` compiles as a standalone C translation unit with the X-macro expanded.
- Preference plists are retained unchanged from V4.36.
