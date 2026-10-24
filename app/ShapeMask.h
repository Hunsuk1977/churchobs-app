// SPDX-License-Identifier: GPL-2.0-or-later
// 장면 레이어 하나를 감싸 소수 단위 자르기 + 둥근 모서리/원 마스크 + 테두리를 적용하는 소스
#pragma once
#include <obs.h>
#ifdef __cplusplus
extern "C" {
#endif
void ws_register_shape(const char *effect_path);
/// child를 감싸는 새 소스 (참조 1개를 돌려준다)
obs_source_t *ws_shape_create(obs_source_t *child, const char *name);
bool ws_shape_is(obs_source_t *source);
/// 자르기 비율 (각 변 0~0.9, 합계 0.9 이하로 이미 정리된 값)
void ws_shape_set_crop(obs_source_t *source, double left, double top, double right, double bottom);
/// shape: 0 사각, 1 둥근 모서리, 2 원(타원)
void ws_shape_set_style(obs_source_t *source, int shape, bool border);
#ifdef __cplusplus
}
#endif
