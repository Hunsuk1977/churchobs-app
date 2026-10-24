// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include <obs.h>
#include <obs-audio-controls.h>
#include <atomic>
#include <algorithm>
#include <cmath>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <string>
struct WSGraphInput {
    obs_source_t *source=nullptr;
    obs_volmeter_t *meter=nullptr;
    std::atomic<float> peak{0};
    std::string signature;
    obs_source_t *skin=nullptr;          // 추가 카메라의 자연 보정 필터 (주 카메라와 같은 설정)
    obs_source_t *look=nullptr;          // 추가 카메라의 색 톤·배경 흐림 필터
    obs_source_t *key=nullptr;           // 자료 배경 투명(컬러 키) 필터
    obs_source_t *audio=nullptr;         // 유튜브: 앱 안 웹 플레이어 소리 (church_app_audio)
    bool webMuted=false;                 // 믹서에서 끈 상태 (현장만으로 바꿀 때 유지)
    // 이 카메라만의 설정 (없으면 준비 화면의 공통 설정을 따른다)
    bool ownLook=false;
    int ownBeauty=0, ownTone=0;
    double ownToneAmount=0.6, ownBlur=0;
    ~WSGraphInput() {
        if(meter) obs_volmeter_destroy(meter);
        if(skin) { if(source) obs_source_filter_remove(source,skin); obs_source_release(skin); }
        if(look) { if(source) obs_source_filter_remove(source,look); obs_source_release(look); }
        if(key) { if(source) obs_source_filter_remove(source,key); obs_source_release(key); }
        if(audio) obs_source_release(audio);
        if(source) obs_source_release(source);
    }
};
static inline void ws_graph_meter(void *opaque,const float magnitude[MAX_AUDIO_CHANNELS],const float peak[MAX_AUDIO_CHANNELS],const float inputPeak[MAX_AUDIO_CHANNELS]) {
    (void)magnitude; (void)inputPeak;
    auto *input=static_cast<WSGraphInput *>(opaque); float value=0;
    for(size_t i=0;i<MAX_AUDIO_CHANNELS;i++) if(std::isfinite(peak[i])) value=std::max(value,std::pow(10.0f,peak[i]/20.0f));
    input->peak.store(std::clamp(value,0.0f,1.0f));
}
struct WSGraphState {
    std::unique_ptr<WSGraphInput> mainMic;
    bool sceneMicMuted=false;
    std::mutex previewMutex;
    obs_source_t *preview=nullptr; // one owned reference, showing counter while previewing
    // 출력 창(프로젝터)에 송출과 다른 장면을 띄울 때 그 장면 (nullptr = 송출 화면 그대로). previewMutex로 보호
    obs_source_t *projector=nullptr;
    // 진행(스튜디오) 모드: 미리보기 화면은 다음 장면만 보여 주고, 없으면 검은 화면 (송출 화면과 혼동 방지)
    std::atomic<bool> studioMode{false};
    obs_scene_t *program=nullptr;
    obs_source_t *transition=nullptr;
    std::string transitionKind;
    std::string cacheDirectory;
    std::map<std::string,std::unique_ptr<WSGraphInput>> inputs;
    // 마지막 적용에서 만들지 못해 건너뛴 소스: 소스 id → 이유 (장면 전체는 계속 그린다)
    std::map<std::string,std::string> warnings;
    // 지금 미리보기·송출 장면이 쓰는 소스. 둘 다 안 쓰는 소스(추가 카메라·마이크 등)는 닫는다
    std::set<std::string> previewKeys, programKeys, projectorKeys;
    // 소스 추가 창의 "소리 확인" 미터 (출력에는 보내지 않음)
    std::unique_ptr<WSGraphInput> probe;
    std::string probeDevice;
};
