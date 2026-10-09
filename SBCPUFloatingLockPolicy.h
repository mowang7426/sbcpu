#ifndef SBCPU_FLOATING_LOCK_POLICY_H
#define SBCPU_FLOATING_LOCK_POLICY_H
#include <math.h>
/* Only safety correction: never dock, avoid keyboard, or change the saved anchor. */
static inline double SBCPULockedCoordinate(double anchor, double extent, double halfSize) {
    if (!isfinite(anchor) || !isfinite(extent) || !isfinite(halfSize) || extent <= 0) return 0;
    halfSize = fmax(0, halfSize);
    if (halfSize * 2 >= extent) return extent / 2;
    return fmin(fmax(anchor, halfSize), extent - halfSize);
}
#endif
