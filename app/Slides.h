// SPDX-License-Identifier: GPL-2.0-or-later
// WORDaLIVE 스튜디오에서 지금 송출 중인 슬라이드 (모든 church_slides 소스가 같은 그림을 보여 준다)
#pragma once
#include <obs.h>
#ifdef __cplusplus
extern "C" {
#endif
void ws_register_slides(void);
/// 메인 스레드. path = 내려받아 둔 PNG (빈 문자열 = 그림 없음), blank = 화면 끄기
void ws_slides_set(const char *path, bool blank);
#ifdef __cplusplus
}
#endif
