// SPDX-License-Identifier: GPL-2.0-or-later
#import <Vision/Vision.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>
#include "LookFilter.h"
#include "filters/face_frame.h"
#include <obs.h>
#include <media-io/video-scaler.h>
#include <graphics/vec2.h>
#include <graphics/vec4.h>
#include <util/platform.h>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <vector>

namespace {
char lookEffectPath[4096];

struct Look {
    obs_source_t *source=nullptr;
    gs_effect_t *effect=nullptr;
    bool effectTried=false;
    gs_texrender_t *full=nullptr, *small=nullptr;
    gs_texture_t *maskTexture=nullptr;
    uint32_t maskTextureW=0, maskTextureH=0;
    uint64_t maskTextureSerial=0;
    std::atomic<int> tone{0}, toneAmount{0}, blur{0};   // 0..1000
    // 인물 분리 (Vision)
    dispatch_queue_t queue=nullptr;
    std::atomic<bool> busy{false};
    uint64_t submitted=0;
    video_scaler_t *scaler=nullptr;
    uint32_t width=0, height=0, outHeight=0;
    enum video_format format=VIDEO_FORMAT_NONE;
    bool fullRange=false;
    std::mutex maskMutex;
    std::vector<uint8_t> mask;
    uint32_t maskW=0, maskH=0;
    uint64_t maskSerial=0;
    bool warned=false;
};

const char *lookName(void *) { return "Church OBS camera look"; }

void lookUpdate(void *data, obs_data_t *settings) {
    auto *l=static_cast<Look *>(data);
    auto clamp01=[](double v) { return std::isfinite(v) ? std::fmax(0.0,std::fmin(1.0,v)) : 0.0; };
    l->tone.store((int)std::max<long long>(0,std::min<long long>(4,obs_data_get_int(settings,"tone"))));
    l->toneAmount.store((int)(clamp01(obs_data_get_double(settings,"tone_amount"))*1000));
    l->blur.store((int)(clamp01(obs_data_get_double(settings,"blur"))*1000));
}

void *lookCreate(obs_data_t *settings, obs_source_t *source) {
    auto *l=new Look;
    l->source=source;
    l->queue=dispatch_queue_create("app.churchobs.person-mask",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INITIATED,0));
    lookUpdate(l,settings);
    return l;
}

void lookDestroy(void *data) {
    auto *l=static_cast<Look *>(data);
    if(l->queue) dispatch_sync(l->queue,^{});
    video_scaler_destroy(l->scaler);
    obs_enter_graphics();
    if(l->full) gs_texrender_destroy(l->full);
    if(l->small) gs_texrender_destroy(l->small);
    if(l->maskTexture) gs_texture_destroy(l->maskTexture);
    if(l->effect) gs_effect_destroy(l->effect);
    obs_leave_graphics();
    delete l;
}

void segment(Look *l, CVPixelBufferRef buffer) {
    @autoreleasepool {
        VNGeneratePersonSegmentationRequest *request=[VNGeneratePersonSegmentationRequest new];
        request.qualityLevel=VNGeneratePersonSegmentationRequestQualityLevelBalanced;
        request.outputPixelFormat=kCVPixelFormatType_OneComponent8;
        VNImageRequestHandler *handler=[[VNImageRequestHandler alloc] initWithCVPixelBuffer:buffer orientation:kCGImagePropertyOrientationUp options:@{}];
        NSError *error=nil;
        if(![handler performRequests:@[request] error:&error]) {
            if(!l->warned) { blog(LOG_WARNING,"[look] person segmentation failed: %s",error.localizedDescription.UTF8String ?: "unknown"); l->warned=true; }
            return;
        }
        VNPixelBufferObservation *result=request.results.firstObject;
        CVPixelBufferRef m=result.pixelBuffer;
        if(!m) return;
        if(CVPixelBufferLockBaseAddress(m,kCVPixelBufferLock_ReadOnly)!=kCVReturnSuccess) return;
        const uint32_t w=(uint32_t)CVPixelBufferGetWidth(m),h=(uint32_t)CVPixelBufferGetHeight(m);
        const size_t stride=CVPixelBufferGetBytesPerRow(m);
        const uint8_t *base=static_cast<const uint8_t *>(CVPixelBufferGetBaseAddress(m));
        {
            std::lock_guard<std::mutex> guard(l->maskMutex);
            l->mask.resize((size_t)w*h);
            for(uint32_t y=0;y<h;y++) memcpy(l->mask.data()+(size_t)y*w,base+y*stride,w);
            l->maskW=w; l->maskH=h; l->maskSerial++;
        }
        CVPixelBufferUnlockBaseAddress(m,kCVPixelBufferLock_ReadOnly);
    }
}

// 카메라 프레임을 받아 15fps 정도로 인물 영역을 갱신한다 (배경 흐림을 켰을 때만)
struct obs_source_frame *lookFrame(void *data, struct obs_source_frame *frame) {
    auto *l=static_cast<Look *>(data);
    if(!frame || !frame->data[0] || !frame->width || !frame->height || l->blur.load()<=0) return frame;
    const uint64_t now=os_gettime_ns();
    if(now-l->submitted<66000000ULL || l->busy.exchange(true)) return frame;
    l->submitted=now;
    if(!l->scaler || l->width!=frame->width || l->height!=frame->height || l->format!=frame->format || l->fullRange!=frame->full_range) {
        video_scaler_destroy(l->scaler); l->scaler=nullptr;
        l->width=frame->width; l->height=frame->height; l->format=frame->format; l->fullRange=frame->full_range;
        l->outHeight=std::max(32u,std::min(1024u,uint32_t(512.0*frame->height/frame->width)));
        struct video_scale_info src{}; src.format=frame->format; src.width=frame->width; src.height=frame->height;
        src.colorspace=VIDEO_CS_DEFAULT; src.range=frame->full_range ? VIDEO_RANGE_FULL : VIDEO_RANGE_PARTIAL;
        struct video_scale_info dst{}; dst.format=VIDEO_FORMAT_BGRA; dst.width=512; dst.height=l->outHeight;
        dst.colorspace=VIDEO_CS_DEFAULT; dst.range=VIDEO_RANGE_FULL;
        if(video_scaler_create(&l->scaler,&dst,&src,VIDEO_SCALE_FAST_BILINEAR)!=VIDEO_SCALER_SUCCESS) { l->busy=false; return frame; }
    }
    CVPixelBufferRef buffer=nullptr;
    if(CVPixelBufferCreate(kCFAllocatorDefault,512,l->outHeight,kCVPixelFormatType_32BGRA,nullptr,&buffer)!=kCVReturnSuccess) { l->busy=false; return frame; }
    if(CVPixelBufferLockBaseAddress(buffer,0)!=kCVReturnSuccess) { CVPixelBufferRelease(buffer); l->busy=false; return frame; }
    uint8_t *out[MAX_AV_PLANES]={static_cast<uint8_t *>(CVPixelBufferGetBaseAddress(buffer))};
    uint32_t strides[MAX_AV_PLANES]={uint32_t(CVPixelBufferGetBytesPerRow(buffer))};
    const bool ok=video_scaler_scale(l->scaler,out,strides,frame->data,frame->linesize) &&
                  ws_prepare_face_bgra(out[0],512,l->outHeight,strides[0],frame->flip);
    CVPixelBufferUnlockBaseAddress(buffer,0);
    if(!ok) { CVPixelBufferRelease(buffer); l->busy=false; return frame; }
    dispatch_async(l->queue,^{
        segment(l,buffer);
        CVPixelBufferRelease(buffer);
        l->busy=false;
    });
    return frame;
}

void setTexture(gs_eparam_t *param, gs_texture_t *tex, bool linear) {
    if(!param) return;
    if(linear) gs_effect_set_texture_srgb(param,tex); else gs_effect_set_texture(param,tex);
}

void lookRender(void *data, gs_effect_t *) {
    auto *l=static_cast<Look *>(data);
    const int tone=l->tone.load(), toneAmount=l->toneAmount.load(), blur=l->blur.load();
    obs_source_t *target=obs_filter_get_target(l->source), *parent=obs_filter_get_parent(l->source);
    const uint32_t cx=target ? obs_source_get_base_width(target) : 0, cy=target ? obs_source_get_base_height(target) : 0;
    if((!(tone && toneAmount) && !blur) || !target || !parent || !cx || !cy) { obs_source_skip_video_filter(l->source); return; }
    if(!l->effectTried) {
        l->effectTried=true;
        l->effect=gs_effect_create_from_file(lookEffectPath,nullptr);
        if(!l->effect) blog(LOG_WARNING,"[look] effect load failed: %s",lookEffectPath);
    }
    if(!l->effect) { obs_source_skip_video_filter(l->source); return; }
    if(!l->full) l->full=gs_texrender_create(GS_RGBA,GS_ZS_NONE);
    if(!l->small) l->small=gs_texrender_create(GS_RGBA,GS_ZS_NONE);

    // 1) 이전 단계(보정 필터 또는 카메라)를 텍스처로
    gs_texrender_reset(l->full);
    if(gs_texrender_begin_with_color_space(l->full,cx,cy,GS_CS_SRGB)) {
        gs_blend_state_push();
        gs_blend_function_separate(GS_BLEND_SRCALPHA,GS_BLEND_INVSRCALPHA,GS_BLEND_ONE,GS_BLEND_INVSRCALPHA);
        struct vec4 clear; vec4_zero(&clear);
        gs_clear(GS_CLEAR_COLOR,&clear,0.0f,0);
        gs_ortho(0.0f,(float)cx,0.0f,(float)cy,-100.0f,100.0f);
        const uint32_t flags=obs_source_get_output_flags(parent);
        if(target==parent && !(flags&OBS_SOURCE_CUSTOM_DRAW) && !(flags&OBS_SOURCE_ASYNC)) obs_source_default_render(target);
        else obs_source_video_render(target);
        gs_blend_state_pop();
        gs_texrender_end(l->full);
    }
    gs_texture_t *fullTex=gs_texrender_get_texture(l->full);
    if(!fullTex) return;

    // 2) 사람 영역 텍스처 갱신
    bool hasMask=false;
    if(blur) {
        std::vector<uint8_t> copy; uint32_t mw=0,mh=0; uint64_t serial=0;
        {
            std::lock_guard<std::mutex> guard(l->maskMutex);
            if(l->maskSerial!=l->maskTextureSerial && !l->mask.empty()) { copy=l->mask; }
            mw=l->maskW; mh=l->maskH; serial=l->maskSerial;
        }
        if(!copy.empty()) {
            if(!l->maskTexture || l->maskTextureW!=mw || l->maskTextureH!=mh) {
                if(l->maskTexture) gs_texture_destroy(l->maskTexture);
                l->maskTexture=gs_texture_create(mw,mh,GS_R8,1,nullptr,GS_DYNAMIC);
                l->maskTextureW=mw; l->maskTextureH=mh;
            }
            if(l->maskTexture) gs_texture_set_image(l->maskTexture,copy.data(),mw,false);
            l->maskTextureSerial=serial;
        }
        hasMask=l->maskTexture!=nullptr;
    }

    // 3) 1/4로 줄인 화면 (배경 흐림 재료)
    const uint32_t sx=std::max(1u,cx/4), sy=std::max(1u,cy/4);
    gs_texture_t *smallTex=nullptr;
    if(blur && hasMask) {
        gs_texrender_reset(l->small);
        if(gs_texrender_begin_with_color_space(l->small,sx,sy,GS_CS_SRGB)) {
            gs_blend_state_push();
            gs_blend_function(GS_BLEND_ONE,GS_BLEND_ZERO);
            gs_ortho(0.0f,(float)sx,0.0f,(float)sy,-100.0f,100.0f);
            gs_effect_set_texture(gs_effect_get_param_by_name(l->effect,"image"),fullTex);
            struct vec2 ft; vec2_set(&ft,1.0f/cx,1.0f/cy);
            gs_effect_set_vec2(gs_effect_get_param_by_name(l->effect,"full_texel"),&ft);
            while(gs_effect_loop(l->effect,"Down")) gs_draw_sprite(fullTex,0,sx,sy);
            gs_blend_state_pop();
            gs_texrender_end(l->small);
        }
        smallTex=gs_texrender_get_texture(l->small);
    }

    // 4) 최종: 배경 흐림 + 색 톤
    const bool linear=gs_get_linear_srgb();
    const bool previous=gs_framebuffer_srgb_enabled();
    gs_enable_framebuffer_srgb(linear);
    gs_effect_t *e=l->effect;
    setTexture(gs_effect_get_param_by_name(e,"image"),fullTex,linear);
    setTexture(gs_effect_get_param_by_name(e,"small_image"),smallTex ? smallTex : fullTex,linear);
    gs_effect_set_texture(gs_effect_get_param_by_name(e,"mask_image"),hasMask ? l->maskTexture : fullTex);
    gs_effect_set_float(gs_effect_get_param_by_name(e,"tone"),(float)tone);
    gs_effect_set_float(gs_effect_get_param_by_name(e,"tone_amount"),toneAmount/1000.0f);
    gs_effect_set_float(gs_effect_get_param_by_name(e,"blur"),(smallTex && hasMask) ? blur/1000.0f : 0.0f);
    gs_effect_set_float(gs_effect_get_param_by_name(e,"has_mask"),hasMask ? 1.0f : 0.0f);
    struct vec2 st; vec2_set(&st,1.0f/sx,1.0f/sy);
    gs_effect_set_vec2(gs_effect_get_param_by_name(e,"small_texel"),&st);
    while(gs_effect_loop(e,"Draw")) gs_draw_sprite(fullTex,0,cx,cy);
    gs_enable_framebuffer_srgb(previous);
}
}

void ws_register_look_filter(const char *effect_path) {
    snprintf(lookEffectPath,sizeof(lookEffectPath),"%s",effect_path ? effect_path : "");
    struct obs_source_info info={};
    info.id="church_camera_look";
    info.type=OBS_SOURCE_TYPE_FILTER;
    info.output_flags=OBS_SOURCE_VIDEO;
    info.get_name=lookName;
    info.create=lookCreate;
    info.destroy=lookDestroy;
    info.update=lookUpdate;
    info.video_render=lookRender;
    info.filter_video=lookFrame;
    obs_register_source(&info);
}
