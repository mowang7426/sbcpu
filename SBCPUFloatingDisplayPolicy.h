#ifndef SBCPU_FLOATING_DISPLAY_POLICY_H
#define SBCPU_FLOATING_DISPLAY_POLICY_H
#include <stdbool.h>

// Keep the ordinary folded indicator, never overlay it on the top status text.
// Landscape visibility follows the existing refresh policy; geometry is untouched.
static inline bool SBCPUStatusDotHidden(bool collapsed, bool top_status_dock, bool landscape) {
    return !collapsed || top_status_dock || landscape;
}
#endif
