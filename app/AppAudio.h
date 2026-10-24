// SPDX-License-Identifier: GPL-2.0-or-later
// 앱 안 웹 플레이어(유튜브 등)의 소리를 방송에 넣는 소스 "church_app_audio" (macOS 14.2+ Core Audio 프로세스 탭)
#pragma once
#include <obs.h>
#ifdef __cplusplus
extern "C" {
#endif
void ws_register_app_audio(void);
#ifdef __cplusplus
}
#endif
