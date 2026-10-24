// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include <stdbool.h>
#ifdef __cplusplus
extern "C" {
#endif
// Top-left-origin camera UV coordinates. Rectangles contain center and half-size.
typedef struct ws_face_geometry {
    float face[4], left_eye[4], right_eye[4], left_brow[4], right_brow[4], mouth[4];
    float confidence;
} ws_face_geometry;
float ws_face_age_gain(double age);
void ws_face_smooth(ws_face_geometry *current, const ws_face_geometry *target, double dt);
#ifdef __cplusplus
}
#endif
