#include "../SBCPUFloatingDisplayPolicy.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    for (int landscape = 0; landscape <= 1; ++landscape) {
        assert(SBCPUStatusDotHidden(false, false, landscape));
        assert(SBCPUStatusDotHidden(false, true, landscape));
        assert(SBCPUStatusDotHidden(true, true, landscape));
    }
    assert(!SBCPUStatusDotHidden(true, false, false)); // Normal portrait fold unchanged.
    assert(SBCPUStatusDotHidden(true, false, true));  // Existing landscape refresh unchanged.
    assert(SBCPUStatusDotHidden(false, false, false));
    assert(!SBCPUStatusDotHidden(true, false, false)); // Collapse restores the dot.
    assert(SBCPUStatusDotHidden(true, true, false));   // Top mode suppresses overlap.
    assert(!SBCPUStatusDotHidden(true, false, false)); // Leaving top mode restores it.
    puts("floating dot display policy regression tests passed");
    return 0;
}
