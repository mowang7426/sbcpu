#import "../SBCPUTextOnlyColor.h"
#include <assert.h>
static void fallback(id value) {
    SBCPUTextRGBA c = SBCPUTextDecodeRGBA(value), d = SBCPUTextDefaultRGBA();
    assert(c.red == d.red && c.green == d.green && c.blue == d.blue && c.alpha == 1);
}
int main(void) { @autoreleasepool {
    assert(!SBCPUTextUsesWhite(0, SBCPUTextSystemStyle(1, 2)));
    assert(SBCPUTextUsesWhite(0, SBCPUTextSystemStyle(2, 1)));
    assert(SBCPUTextSystemStyle(0, 2) == 2);
    assert(SBCPUTextSystemStyle(0, 1) == 1);
    assert(SBCPUTextSystemStyle(0, 0) == 1);
    assert(SBCPUTextSystemStyle(99, -1) == 1);
    for (int style = 0; style <= 2; style++) {
        assert(SBCPUTextUsesWhite(1, style));
        assert(!SBCPUTextUsesWhite(2, style));
    }
    fallback(nil); fallback(@[]); fallback(@[@1, @0, @1]);
    fallback(@[@1, @0, @1, @1, @0]); fallback(@{}); fallback(@"red");
    fallback(@[@"1", @0, @1, @1]); fallback(@[@1, NSNull.null, @1, @1]);
    for (NSUInteger i = 0; i < 4; i++) {
        for (NSNumber *bad in @[@(NAN), @(INFINITY), @(-INFINITY)]) {
            NSMutableArray *values = [@[@0, @0.5, @1, @1] mutableCopy];
            values[i] = bad; fallback(values);
        }
    }
    SBCPUTextRGBA c = SBCPUTextDecodeRGBA(@[@(-5), @0.25, @8, @0]);
    assert(c.red == 0 && c.green == 0.25 && c.blue == 1 && c.alpha == 1);
    c = SBCPUTextDecodeRGBA(@[@0.2, @0.3, @0.4, @0.5]);
    assert(c.red == 0.2 && c.green == 0.3 && c.blue == 0.4 && c.alpha == 1);
    puts("PASS: system light/dark, authoritative fallback, fixed modes, strict RGBA and opacity");
} return 0; }
