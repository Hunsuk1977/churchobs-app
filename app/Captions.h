// SPDX-License-Identifier: GPL-2.0-or-later
// WORDaLIVE 실시간 번역 자막 소스 (WORDaLIVE 방송 자막 띠와 같은 모양)
#pragma once
#include <obs.h>
#ifdef __cplusplus
extern "C" {
#endif
void ws_register_captions(void);
/// 메인 스레드. 오래된 것 → 최신 순. 최신 줄은 타자 효과 중이면 일부만 들어온다
void ws_captions_set_lines(const char *const *translated, const char *const *source, int count);

/// WORDaLIVE 스튜디오의 자막 디자인 (active=false면 각 소스의 Church OBS 설정을 쓴다)
struct ws_caption_style {
    bool active;
    char family[96];
    int weight;          // 100~900
    double size;         // WORDaLIVE 무대(1280×720) 기준 px
    double fg[4];        // RGBA 0~1
    double bg[4];
    int lines;           // 보이는 문장 수
    double content_pct;  // 글 영역 너비 % (50~100)
};
void ws_captions_set_style(const struct ws_caption_style *style);
#ifdef __cplusplus
}
#endif
