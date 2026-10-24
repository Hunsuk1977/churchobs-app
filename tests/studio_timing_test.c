// SPDX-License-Identifier: GPL-2.0-or-later
#include "../app/StudioTiming.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    assert(ws_countdown_remaining(300,0)==300);
    assert(ws_countdown_remaining(300,1.001)==299);
    assert(ws_countdown_remaining(300,57.4)==243);
    assert(ws_countdown_remaining(300,299.99)==1);
    assert(ws_countdown_remaining(300,300)==0);
    assert(ws_countdown_remaining(300,900)==0);
    assert(ws_countdown_remaining(NAN,1)==0);
    assert(ws_countdown_remaining(INFINITY,1)==0);
    assert(ws_countdown_remaining(20000,0)==10800);
    puts("PASS monotonic countdown: delayed ticks, subsecond rounding, expiry and invalid deadlines");
    return 0;
}
