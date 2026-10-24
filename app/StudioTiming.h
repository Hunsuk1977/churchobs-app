// SPDX-License-Identifier: GPL-2.0-or-later
#ifndef WS_STUDIO_TIMING_H
#define WS_STUDIO_TIMING_H
#include <math.h>
// Monotonic deadline: delayed UI ticks cannot make the countdown run slowly.
static inline int ws_countdown_remaining(double deadline, double now) {
    double left=deadline-now;
    if(!isfinite(left) || left<=0) return 0;
    return left>10800 ? 10800 : (int)ceil(left);
}
#endif
