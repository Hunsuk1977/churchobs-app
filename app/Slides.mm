// SPDX-License-Identifier: GPL-2.0-or-later
// 그림 해독은 메인 스레드(ws_slides_set)에서, 텍스처 올리기·교체는 그래픽 스레드(렌더)에서 한다.
#include "Slides.h"
#include <graphics/graphics.h>
#include <graphics/image-file.h>
#include <atomic>
#include <mutex>
#include <string>
#include <vector>

namespace {
std::mutex slideMutex;
gs_image_file_t *current=nullptr;   // 텍스처까지 올라간 그림 (그래픽 스레드만 바꾼다)
gs_image_file_t *pending=nullptr;   // 해독만 끝난 새 그림
std::vector<gs_image_file_t *> retired;   // 텍스처 정리는 그래픽 스레드에서만
std::string currentPath;
std::atomic<bool> blank{false};
std::atomic<uint32_t> width{1920}, height{1080};

const char *slidesName(void *) { return "WORDaLIVE Slide"; }
void *slidesCreate(obs_data_t *, obs_source_t *source) { return source; }
void slidesDestroy(void *) {}
uint32_t slidesWidth(void *) { return width.load(); }
uint32_t slidesHeight(void *) { return height.load(); }
void slidesRender(void *, gs_effect_t *) {
    gs_image_file_t *draw=nullptr;
    {
        std::lock_guard<std::mutex> guard(slideMutex);
        for(gs_image_file_t *old:retired) { gs_image_file_free(old); bfree(old); }
        retired.clear();
        if(pending) {
            if(current) { gs_image_file_free(current); bfree(current); }   // 그래픽 스레드라 안전
            current=pending; pending=nullptr;
            gs_image_file_init_texture(current);
        }
        draw=current;
        if(blank.load() || !draw || !draw->texture) return;
        obs_source_draw(draw->texture,0,0,0,0,false);
    }
}
}

void ws_register_slides(void) {
    struct obs_source_info info={};
    info.id="church_slides";
    info.type=OBS_SOURCE_TYPE_INPUT;
    info.output_flags=OBS_SOURCE_VIDEO|OBS_SOURCE_DO_NOT_DUPLICATE|OBS_SOURCE_CAP_DISABLED;
    info.get_name=slidesName;
    info.create=slidesCreate;
    info.destroy=slidesDestroy;
    info.get_width=slidesWidth;
    info.get_height=slidesHeight;
    info.video_render=slidesRender;
    obs_register_source(&info);
}

void ws_slides_set(const char *path, bool isBlank) {
    blank.store(isBlank);
    std::string next=path ? path : "";
    {
        std::lock_guard<std::mutex> guard(slideMutex);
        if(next==currentPath) return;
        currentPath=next;
    }
    gs_image_file_t *file=nullptr;
    if(!next.empty()) {
        file=static_cast<gs_image_file_t *>(bzalloc(sizeof(gs_image_file_t)));
        gs_image_file_init(file,next.c_str());
        if(!file->loaded) { gs_image_file_free(file); bfree(file); file=nullptr; }
    }
    std::lock_guard<std::mutex> guard(slideMutex);
    if(pending) { retired.push_back(pending); pending=nullptr; }
    if(file) {
        pending=file;
        width.store(file->cx ? file->cx : 1920); height.store(file->cy ? file->cy : 1080);
    } else if(current) {
        retired.push_back(current); current=nullptr;   // 그림 없음
    }
}
