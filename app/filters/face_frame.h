// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include <stdbool.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// Match OBS's displayed orientation and make camera BGRX pixels opaque for Vision.
bool ws_prepare_face_bgra(uint8_t *pixels, uint32_t width, uint32_t height, uint32_t stride, bool flip);
#ifdef __cplusplus
}
#endif
