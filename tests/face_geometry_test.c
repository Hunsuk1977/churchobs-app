// SPDX-License-Identifier: GPL-2.0-or-later
#include "../app/filters/face_geometry.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
int main(void) {
    // A stalled analysis cannot leave a permanent warp on the broadcast.
    assert(ws_face_age_gain(0.1)==1);
    assert(ws_face_age_gain(0.3)>0 && ws_face_age_gain(0.3)<1);
    assert(ws_face_age_gain(0.5)==0);
    assert(ws_face_age_gain(NAN)==0);
    ws_face_geometry target={.face={.5f,.5f,.2f,.3f},.confidence=1};
    ws_face_geometry at30={0},at60={0};
    for(int i=0;i<30;i++) ws_face_smooth(&at30,&target,1.0/30);
    for(int i=0;i<60;i++) ws_face_smooth(&at60,&target,1.0/60);
    assert(fabsf(at30.confidence-at60.confidence)<0.00001f);
    assert(at30.face[0]==target.face[0]);
    // Motion is interpolated, while confidence fades out on tracking loss.
    target.face[0]=.6f;
    ws_face_smooth(&at30,&target,1.0/30);
    assert(at30.face[0]>.5f && at30.face[0]<.6f);
    target.confidence=0;
    for(int i=0;i<30;i++) ws_face_smooth(&at30,&target,1.0/30);
    assert(at30.confidence==0);
    // Reacquisition changes coordinates only once the old effect is gone.
    target.confidence=1; target.face[0]=.2f;
    ws_face_smooth(&at30,&target,1.0/30);
    assert(at30.face[0]==.2f && at30.confidence>0 && at30.confidence<1);
    // A camera cut / different largest face fades instead of sweeping a warp.
    target.face[0]=.8f;
    float previous=at30.confidence;
    ws_face_smooth(&at30,&target,1.0/30);
    assert(at30.face[0]==.2f && at30.confidence<previous);
    for(int i=0;i<60;i++) ws_face_smooth(&at30,&target,1.0/30);
    assert(at30.face[0]==.8f && at30.confidence>.99f);
    puts("PASS face tracking smoothing, expiry, frame-rate independence and reacquisition");
}
