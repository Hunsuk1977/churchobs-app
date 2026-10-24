// SPDX-License-Identifier: GPL-2.0-or-later
#include "../app/filters/face_frame.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
int main(void) {
    // Three rows and padded stride catch orientation, alpha and boundary errors.
    uint8_t frame[3*12]; memset(frame,0xcc,sizeof(frame));
    for(int y=0;y<3;y++) for(int x=0;x<2;x++) {
        frame[y*12+x*4]=10*y+x; frame[y*12+x*4+1]=33;
        frame[y*12+x*4+2]=44; frame[y*12+x*4+3]=0;
    }
    assert(ws_prepare_face_bgra(frame,2,3,12,true));
    for(int y=0;y<3;y++) for(int x=0;x<2;x++) {
        assert(frame[y*12+x*4]==10*(2-y)+x);
        assert(frame[y*12+x*4+1]==33 && frame[y*12+x*4+2]==44);
        assert(frame[y*12+x*4+3]==255);
    }
    for(int y=0;y<3;y++) for(int x=8;x<12;x++) assert(frame[y*12+x]==0xcc);
    assert(ws_prepare_face_bgra(frame,2,3,12,true));
    assert(frame[0]==0 && frame[24]==20);
    assert(ws_prepare_face_bgra(frame,2,3,12,false));
    assert(!ws_prepare_face_bgra(NULL,2,3,12,false));
    assert(!ws_prepare_face_bgra(frame,4,3,12,false));
    assert(!ws_prepare_face_bgra(frame,UINT32_MAX,3,12,false));
    puts("PASS face BGRA orientation, opacity, row padding and invalid dimensions");
}
