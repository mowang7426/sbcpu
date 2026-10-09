#include "../SBCPUFloatingLockPolicy.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    assert(SBCPULockedCoordinate(120, 390, 40) == 120);
    assert(SBCPULockedCoordinate(120, 390, 15) == 120); /* folded */
    assert(SBCPULockedCoordinate(120, 390, 100) == 120); /* expanded */
    assert(SBCPULockedCoordinate(370, 390, 40) == 350); /* keep unlock reachable */
    assert(SBCPULockedCoordinate(370, 844, 40) == 370); /* restore original anchor */
    assert(SBCPULockedCoordinate(-20, 390, 40) == 40);
    assert(SBCPULockedCoordinate(120, 100, 80) == 50); /* oversized view */
    assert(SBCPULockedCoordinate(NAN, 390, 40) == 0);
    assert(SBCPULockedCoordinate(120, 0, 40) == 0);
    puts("floating lock geometry regression passed");
    return 0;
}
