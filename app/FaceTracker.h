// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include "filters/face_geometry.h"
struct obs_source_frame;
#ifdef __cplusplus
extern "C" {
#endif
typedef struct ws_face_tracker ws_face_tracker;
ws_face_tracker *ws_face_tracker_create(void);
void ws_face_tracker_destroy(ws_face_tracker *tracker);
void ws_face_tracker_submit(ws_face_tracker *tracker, const struct obs_source_frame *frame);
// 0 waiting, 1 tracking, 2 no face, 3 scaler init, 4 buffer allocation/lock,
// 5 pixel conversion, 6 Vision request, 7 stale result, 8 turned/tilted face.
typedef struct ws_face_diagnostics {
    int submitted, analysed, detected, elapsed_ms, error_code;
} ws_face_diagnostics;
void ws_face_tracker_details(ws_face_tracker *tracker, ws_face_diagnostics *details);
int ws_face_tracker_snapshot(ws_face_tracker *tracker, ws_face_geometry *geometry);
bool ws_face_tracker_self_test(void);
#ifdef __cplusplus
}
#endif
