// SPDX-License-Identifier: GPL-2.0-or-later
#include "ShapeMask.h"
#include <graphics/graphics.h>
#include <graphics/vec2.h>
#include <graphics/vec4.h>
#include <util/bmem.h>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <mutex>

namespace {
char shapeEffectPath[1024];

struct Shape {
    obs_source_t *self=nullptr;
    obs_source_t *child=nullptr;          // 강한 참조
    gs_texrender_t *render=nullptr;
    gs_effect_t *effect=nullptr;
    bool effectTried=false;
    std::mutex mutex;
    float crop[4]={0,0,0,0};              // 왼, 위, 오른, 아래
    int shape=0;
    bool border=false;
};

struct Region { float x, y, w, h; };

Region region(const float crop[4], uint32_t cw, uint32_t ch) {
    Region r;
    r.x=crop[0]*cw; r.y=crop[1]*ch;
    r.w=std::fmax(cw*(1.0f-crop[0]-crop[2]),1.0f);
    r.h=std::fmax(ch*(1.0f-crop[1]-crop[3]),1.0f);
    return r;
}

const char *shapeName(void *) { return "Church OBS shape"; }
void *shapeCreate(obs_data_t *, obs_source_t *source) { auto *s=new Shape; s->self=source; return s; }
void shapeDestroy(void *data) {
    auto *s=static_cast<Shape *>(data);
    obs_enter_graphics();
    if(s->render) gs_texrender_destroy(s->render);
    if(s->effect) gs_effect_destroy(s->effect);
    obs_leave_graphics();
    if(s->child) obs_source_release(s->child);
    delete s;
}
uint32_t shapeWidth(void *data) {
    auto *s=static_cast<Shape *>(data);
    if(!s->child) return 0;
    uint32_t cw=obs_source_get_width(s->child),ch=obs_source_get_height(s->child);
    if(!cw || !ch) return 0;
    std::lock_guard<std::mutex> guard(s->mutex);
    return (uint32_t)std::lround(region(s->crop,cw,ch).w);
}
uint32_t shapeHeight(void *data) {
    auto *s=static_cast<Shape *>(data);
    if(!s->child) return 0;
    uint32_t cw=obs_source_get_width(s->child),ch=obs_source_get_height(s->child);
    if(!cw || !ch) return 0;
    std::lock_guard<std::mutex> guard(s->mutex);
    return (uint32_t)std::lround(region(s->crop,cw,ch).h);
}
void shapeRender(void *data, gs_effect_t *) {
    auto *s=static_cast<Shape *>(data);
    obs_source_t *child=s->child;
    if(!child) return;
    const uint32_t cw=obs_source_get_width(child),ch=obs_source_get_height(child);
    if(!cw || !ch) return;
    float crop[4]; int shape; bool border;
    { std::lock_guard<std::mutex> guard(s->mutex); memcpy(crop,s->crop,sizeof(crop)); shape=s->shape; border=s->border; }
    const Region r=region(crop,cw,ch);
    const uint32_t ow=(uint32_t)std::lround(r.w),oh=(uint32_t)std::lround(r.h);

    if(!s->effectTried) {
        s->effectTried=true;
        s->effect=gs_effect_create_from_file(shapeEffectPath,nullptr);
        if(!s->effect) blog(LOG_WARNING,"[shape] effect load failed: %s",shapeEffectPath);
    }
    if(!s->render) s->render=gs_texrender_create(GS_RGBA,GS_ZS_NONE);
    if(!s->render) return;

    // 1) 원본을 원래 크기 그대로 텍스처에 그린다
    gs_texrender_reset(s->render);
    gs_blend_state_push();
    gs_blend_function(GS_BLEND_ONE,GS_BLEND_ZERO);
    if(gs_texrender_begin_with_color_space(s->render,cw,ch,GS_CS_SRGB)) {
        struct vec4 clear; vec4_zero(&clear);
        gs_clear(GS_CLEAR_COLOR,&clear,0.0f,0);
        gs_ortho(0.0f,(float)cw,0.0f,(float)ch,-100.0f,100.0f);
        obs_source_video_render(child);
        gs_texrender_end(s->render);
    }
    gs_blend_state_pop();
    gs_texture_t *tex=gs_texrender_get_texture(s->render);
    if(!tex) return;

    // 2) 잘라낸 부분을 모양에 맞춰 그린다
    const bool linear=gs_get_linear_srgb();
    const bool previous=gs_framebuffer_srgb_enabled();
    gs_enable_framebuffer_srgb(linear);
    if(s->effect) {
        gs_effect_t *e=s->effect;
        gs_eparam_t *image=gs_effect_get_param_by_name(e,"image");
        if(linear) gs_effect_set_texture_srgb(image,tex); else gs_effect_set_texture(image,tex);
        struct vec2 offset,scale,size;
        vec2_set(&offset,r.x/cw,r.y/ch); vec2_set(&scale,r.w/cw,r.h/ch); vec2_set(&size,(float)ow,(float)oh);
        gs_effect_set_vec2(gs_effect_get_param_by_name(e,"uv_offset"),&offset);
        gs_effect_set_vec2(gs_effect_get_param_by_name(e,"uv_scale"),&scale);
        gs_effect_set_vec2(gs_effect_get_param_by_name(e,"size"),&size);
        const float shortSide=(float)std::fmin(ow,oh);
        gs_effect_set_float(gs_effect_get_param_by_name(e,"radius"),shape==1 ? shortSide*0.08f : 0.0f);
        gs_effect_set_float(gs_effect_get_param_by_name(e,"circle"),shape==2 ? 1.0f : 0.0f);
        gs_effect_set_float(gs_effect_get_param_by_name(e,"border"),border ? std::fmax(shortSide*0.025f,2.0f) : 0.0f);
        struct vec4 color; vec4_set(&color,1.0f,1.0f,1.0f,1.0f);
        gs_effect_set_vec4(gs_effect_get_param_by_name(e,"border_color"),&color);
        while(gs_effect_loop(e,"Draw")) gs_draw_sprite(tex,0,ow,oh);
    } else {
        // 셰이더가 없으면 자르기만 (사각)
        gs_effect_t *def=obs_get_base_effect(OBS_EFFECT_DEFAULT);
        gs_eparam_t *image=gs_effect_get_param_by_name(def,"image");
        if(linear) gs_effect_set_texture_srgb(image,tex); else gs_effect_set_texture(image,tex);
        while(gs_effect_loop(def,"Draw")) gs_draw_sprite_subregion(tex,0,(uint32_t)r.x,(uint32_t)r.y,ow,oh);
    }
    gs_enable_framebuffer_srgb(previous);
}
void shapeEnum(void *data, obs_source_enum_proc_t callback, void *param) {
    auto *s=static_cast<Shape *>(data);
    if(s->child) callback(s->self,s->child,param);
}
// 감싼 영상에 소리가 있으면 그대로 넘긴다 (예: 둥근 모서리 동영상)
bool shapeAudio(void *data, uint64_t *ts_out, struct obs_source_audio_mix *audio, uint32_t mixers, size_t channels, size_t) {
    auto *s=static_cast<Shape *>(data);
    obs_source_t *child=s->child;
    if(!child || !(obs_source_get_output_flags(child)&OBS_SOURCE_AUDIO) || obs_source_audio_pending(child)) return false;
    const uint64_t ts=obs_source_get_audio_timestamp(child);
    if(!ts) return false;
    struct obs_source_audio_mix mix;
    obs_source_get_audio_mix(child,&mix);
    for(size_t m=0;m<MAX_AUDIO_MIXES;m++) {
        if(!(mixers&(1u<<m))) continue;
        for(size_t c=0;c<channels;c++) memcpy(audio->output[m].data[c],mix.output[m].data[c],AUDIO_OUTPUT_FRAMES*sizeof(float));
    }
    *ts_out=ts;
    return true;
}
Shape *shapeData(obs_source_t *source) {
    if(!ws_shape_is(source)) return nullptr;
    return static_cast<Shape *>(obs_obj_get_data(source));
}
}

void ws_register_shape(const char *effect_path) {
    snprintf(shapeEffectPath,sizeof(shapeEffectPath),"%s",effect_path ? effect_path : "");
    struct obs_source_info info={};
    info.id="church_shape";
    info.type=OBS_SOURCE_TYPE_INPUT;
    info.output_flags=OBS_SOURCE_VIDEO|OBS_SOURCE_CUSTOM_DRAW|OBS_SOURCE_COMPOSITE|OBS_SOURCE_DO_NOT_DUPLICATE|OBS_SOURCE_CAP_DISABLED;
    info.get_name=shapeName;
    info.create=shapeCreate;
    info.destroy=shapeDestroy;
    info.get_width=shapeWidth;
    info.get_height=shapeHeight;
    info.video_render=shapeRender;
    info.enum_active_sources=shapeEnum;
    info.enum_all_sources=shapeEnum;
    info.audio_render=shapeAudio;
    obs_register_source(&info);
}

bool ws_shape_is(obs_source_t *source) {
    return source && strcmp(obs_source_get_unversioned_id(source),"church_shape")==0;
}

obs_source_t *ws_shape_create(obs_source_t *child, const char *name) {
    if(!child) return nullptr;
    obs_source_t *source=obs_source_create_private("church_shape",name ? name : "shape",nullptr);
    Shape *s=shapeData(source);
    if(!s) { if(source) obs_source_release(source); return nullptr; }
    s->child=obs_source_get_ref(child);
    return source;
}

void ws_shape_set_crop(obs_source_t *source, double left, double top, double right, double bottom) {
    Shape *s=shapeData(source); if(!s) return;
    std::lock_guard<std::mutex> guard(s->mutex);
    s->crop[0]=(float)left; s->crop[1]=(float)top; s->crop[2]=(float)right; s->crop[3]=(float)bottom;
}

void ws_shape_set_style(obs_source_t *source, int shape, bool border) {
    Shape *s=shapeData(source); if(!s) return;
    std::lock_guard<std::mutex> guard(s->mutex);
    s->shape=shape; s->border=border;
}
