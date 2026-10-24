// SPDX-License-Identifier: GPL-2.0-or-later
#include "face_geometry.h"
#include <math.h>
float ws_face_age_gain(double age) {
    if (!isfinite(age) || age < 0 || age >= 0.50) return 0;
    return age <= 0.18 ? 1.0f : (float)((0.50-age)/0.32);
}
void ws_face_smooth(ws_face_geometry *current, const ws_face_geometry *target, double dt) {
    if (!isfinite(dt) || dt <= 0) return;
    float alpha = (float)(1.0-exp(-fmin(dt, 0.1)/0.055));
    // A large location jump can be a different person or a camera cut. Fade the
    // old warp before snapping, rather than sliding it across the background.
    float jump=hypotf(target->face[0]-current->face[0],target->face[1]-current->face[1]);
    float limit=fmaxf(0.06f,0.8f*fmaxf(current->face[2],target->face[2]));
    if(current->confidence>=0.002f && target->confidence>0 && jump>limit) {
        current->confidence*=1-alpha;
        return;
    }
    float *dst[] = {current->face,current->left_eye,current->right_eye,current->left_brow,current->right_brow,current->mouth};
    const float *src[] = {target->face,target->left_eye,target->right_eye,target->left_brow,target->right_brow,target->mouth};
    // First acquisition may snap coordinates while the effect itself fades in.
    const bool fresh = current->confidence < 0.002f && target->confidence > 0;
    for (int r=0;r<6;r++) for(int i=0;i<4;i++) dst[r][i] = fresh ? src[r][i] : dst[r][i]+alpha*(src[r][i]-dst[r][i]);
    current->confidence += alpha*(target->confidence-current->confidence);
    if(current->confidence < 0.0001f) current->confidence=0;
}
