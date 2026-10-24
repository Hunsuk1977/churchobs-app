// SPDX-License-Identifier: GPL-2.0-or-later
// 가상 카메라 — 송출 화면을 Zoom·Google Meet 등에서 카메라로 쓸 수 있게 한다.
#pragma once
#include <stdbool.h>
#ifdef __cplusplus
extern "C" {
#endif
/// obs_startup 뒤 한 번: "church_virtualcam" 출력 종류 등록
void ws_vcam_register(void);
/// 시스템에 OBS Virtual Camera 확장(CoreMediaIO)이 설치·허용되어 있는가
bool ws_vcam_device_available(void);
#ifdef __cplusplus
}
#endif
