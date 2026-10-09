#ifndef SBCPU_TEXT_ONLY_COLOR_H
#define SBCPU_TEXT_ONLY_COLOR_H
#import <Foundation/Foundation.h>
#include <math.h>
typedef struct { double red, green, blue, alpha; } SBCPUTextRGBA;
static inline SBCPUTextRGBA SBCPUTextDefaultRGBA(void) {
    return (SBCPUTextRGBA){0, 122.0/255.0, 1, 1}; // opaque system blue
}
// Strict property-list decoding: no strings, partial arrays, NaN or infinity.
// Clamp finite out-of-range RGB. Alpha is validated but forced opaque for readability.
static inline SBCPUTextRGBA SBCPUTextDecodeRGBA(id value) {
    SBCPUTextRGBA fallback = SBCPUTextDefaultRGBA();
    if (![value isKindOfClass:[NSArray class]] || [value count] != 4) return fallback;
    double components[4];
    for (NSUInteger i = 0; i < 4; i++) {
        id item = value[i];
        if (![item isKindOfClass:[NSNumber class]]) return fallback;
        double number = [item doubleValue];
        if (!isfinite(number)) return fallback;
        components[i] = fmax(0, fmin(1, number));
    }
    return (SBCPUTextRGBA){components[0], components[1], components[2], 1};
}
// UIKit style values: unspecified=0, light=1, dark=2. Unknown defaults to light.
static inline int SBCPUTextSystemStyle(int screenStyle, int springBoardWindowStyle) {
    if (screenStyle == 1 || screenStyle == 2) return screenStyle;
    return springBoardWindowStyle == 2 ? 2 : 1;
}
static inline int SBCPUTextUsesWhite(int mode, int systemStyle) {
    return mode == 1 || (mode == 0 && systemStyle == 2);
}
#endif
