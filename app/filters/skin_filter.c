// SPDX-License-Identifier: GPL-2.0-or-later
// Camera-frame Vision tracking plus SDR GPU beauty processing.
#include "skin_filter.h"
#include "../FaceTracker.h"
#include <graphics/vec4.h>
#include <util/platform.h>
#include <obs-module.h>
#include <graphics/vec2.h>
#include <math.h>
#include <stdio.h>
#include <stdatomic.h>
#include <string.h>

static char shader_path[4096];
struct skin_filter {
    obs_source_t *source;
    gs_effect_t *effect;
    gs_eparam_t *strength;
    gs_eparam_t *pixel_size;
    gs_eparam_t *comparison;
    gs_eparam_t *face_params[6];
    gs_eparam_t *face_gain;
    gs_eparam_t *details;
    gs_eparam_t *guide;
    ws_face_tracker *tracker;
    ws_face_geometry geometry;
    uint64_t rendered_at;
    atomic_int skin, shape, eyes, brows, test_face;
    atomic_int amount; // update and rendering can run on different threads
    atomic_int compare;
    atomic_int show_guide;
    atomic_int state;
    atomic_int frames;
    atomic_int raw_frames;
    atomic_int render_gain;
};
static const char *filter_name(void *unused) { (void)unused; return "Natural face beauty (Vision)"; }
static void defaults(obs_data_t *settings) {
    obs_data_set_default_double(settings, "strength", 0.0);
    obs_data_set_default_bool(settings, "comparison", false);
    obs_data_set_default_double(settings, "skin", 0.65);
    obs_data_set_default_double(settings, "shape", 0.25);
    obs_data_set_default_double(settings, "eyes", 0.20);
    obs_data_set_default_double(settings, "brows", 0.35);
}
static void update(void *opaque, obs_data_t *settings) {
    struct skin_filter *filter = opaque;
    double value = obs_data_get_double(settings, "strength");
    if (!isfinite(value)) value = 0.0;
    atomic_store(&filter->amount, (int)(fmax(0.0, fmin(1.0, value)) * 1000.0));
    atomic_store(&filter->compare, obs_data_get_bool(settings, "comparison"));
    atomic_store(&filter->show_guide,obs_data_get_bool(settings,"face_guide"));
    const char *keys[]={"shape","eyes","brows","skin"};
    atomic_int *values[]={&filter->shape,&filter->eyes,&filter->brows,&filter->skin};
    for(int i=0;i<4;i++) {
        double v=obs_data_get_double(settings,keys[i]);
        atomic_store(values[i],isfinite(v) ? (int)(fmax(0,fmin(1,v))*1000) : 0);
    }
    atomic_store(&filter->test_face,obs_data_get_bool(settings,"test_face"));
}
static void get_status(void *opaque, calldata_t *data) {
    struct skin_filter *filter = opaque;
    calldata_set_int(data, "state", atomic_load(&filter->state));
    calldata_set_int(data, "frames", atomic_load(&filter->frames));
    ws_face_geometry geometry={0};
    calldata_set_int(data,"tracking",ws_face_tracker_snapshot(filter->tracker,&geometry));
    ws_face_diagnostics diagnostics={0}; ws_face_tracker_details(filter->tracker,&diagnostics);
    calldata_set_int(data,"raw_frames",atomic_load(&filter->raw_frames));
    calldata_set_int(data,"analysed",diagnostics.analysed);
    calldata_set_int(data,"detected",diagnostics.detected);
    calldata_set_int(data,"elapsed_ms",diagnostics.elapsed_ms);
    calldata_set_int(data,"error_code",diagnostics.error_code);
    calldata_set_int(data,"gain",atomic_load(&filter->render_gain));
}
static void destroy(void *opaque) {
    struct skin_filter *filter = opaque;
    ws_face_tracker_destroy(filter->tracker);
    obs_enter_graphics();
    gs_effect_destroy(filter->effect);
    obs_leave_graphics();
    bfree(filter);
}
static void *create(obs_data_t *settings, obs_source_t *source) {
    struct skin_filter *filter = bzalloc(sizeof(*filter));
    filter->source = source;
    atomic_init(&filter->skin,0); atomic_init(&filter->shape,0); atomic_init(&filter->eyes,0); atomic_init(&filter->brows,0); atomic_init(&filter->test_face,0);
    filter->tracker=ws_face_tracker_create();
    atomic_init(&filter->amount, 0);
    atomic_init(&filter->compare, 0);
    atomic_init(&filter->show_guide,0);
    atomic_init(&filter->state, 0);
    atomic_init(&filter->frames, 0);
    atomic_init(&filter->raw_frames,0); atomic_init(&filter->render_gain,0);
    obs_enter_graphics();
    filter->effect = gs_effect_create_from_file(shader_path, NULL);
    if (filter->effect) {
        filter->strength = gs_effect_get_param_by_name(filter->effect, "strength");
        filter->pixel_size = gs_effect_get_param_by_name(filter->effect, "pixel_size");
        filter->comparison = gs_effect_get_param_by_name(filter->effect, "comparison");
        const char *names[]={"face_rect","left_eye","right_eye","left_brow","right_brow","mouth_rect"};
        for(int i=0;i<6;i++) filter->face_params[i]=gs_effect_get_param_by_name(filter->effect,names[i]);
        filter->face_gain=gs_effect_get_param_by_name(filter->effect,"face_gain");
        filter->details=gs_effect_get_param_by_name(filter->effect,"details");
        filter->guide=gs_effect_get_param_by_name(filter->effect,"show_guide");
    }
    obs_leave_graphics();
    if (!filter->effect || !filter->strength || !filter->pixel_size || !filter->comparison) { destroy(filter); return NULL; }
    for(int i=0;i<6;i++) if(!filter->face_params[i]) { destroy(filter); return NULL; }
    if(!filter->face_gain || !filter->details || !filter->guide) { destroy(filter); return NULL; }
    proc_handler_add(obs_source_get_proc_handler(source),
                     "void churchobs_skin_status(out int state, out int frames, out int tracking, out int raw_frames, out int analysed, out int detected, out int elapsed_ms, out int error_code, out int gain)", get_status, filter);
    update(filter, settings);
    return filter;
}
static struct obs_source_frame *track_frame(void *opaque, struct obs_source_frame *frame) {
    struct skin_filter *filter=opaque;
    if(frame) atomic_fetch_add(&filter->raw_frames,1);
    if(atomic_load(&filter->amount)) ws_face_tracker_submit(filter->tracker,frame);
    return frame;
}
static void render(void *opaque, gs_effect_t *unused) {
    (void)unused;
    struct skin_filter *filter = opaque;
    obs_source_t *target = obs_filter_get_target(filter->source);
    const int amount = atomic_load(&filter->amount);
    const uint32_t w = target ? obs_source_get_base_width(target) : 0;
    const uint32_t h = target ? obs_source_get_base_height(target) : 0;
    const bool comparing = atomic_load(&filter->compare);
    if ((!amount && !comparing) || !w || !h) {
        atomic_store(&filter->state, !amount ? 1 : 2);
        atomic_store(&filter->render_gain,0);
        obs_source_skip_video_filter(filter->source); return;
    }
    // This app has an SDR output. OBS renders/tone-maps the target into this SDR
    // intermediate, including when the camera supplies a 16-bit/HDR source.
    // Do not silently skip all processing solely because of the input space.
    if (!obs_source_process_filter_begin(filter->source, GS_RGBA, OBS_NO_DIRECT_RENDERING)) {
        atomic_store(&filter->state, 4); return;
    }
    ws_face_geometry target_geometry={0};
    ws_face_tracker_snapshot(filter->tracker,&target_geometry);
    // Only the generated smoke-test source is allowed to use synthetic geometry.
    obs_source_t *parent=obs_filter_get_parent(filter->source);
    if(atomic_load(&filter->test_face) && parent && strcmp(obs_source_get_unversioned_id(parent),"churchobs_test_pattern")==0) {
        const ws_face_geometry test={{0.125f,0.5f,0.115f,0.43f},{0.08f,0.35f,0.025f,0.018f},{0.17f,0.35f,0.025f,0.018f},
          {0.08f,0.29f,0.03f,0.012f},{0.17f,0.29f,0.03f,0.012f},{0.125f,0.68f,0.04f,0.025f},1};
        target_geometry=test;
    }
    uint64_t now=os_gettime_ns();
    ws_face_smooth(&filter->geometry,&target_geometry,filter->rendered_at ? (double)(now-filter->rendered_at)/1e9 : 1.0/30.0);
    filter->rendered_at=now;
    const float *rects[]={filter->geometry.face,filter->geometry.left_eye,filter->geometry.right_eye,filter->geometry.left_brow,filter->geometry.right_brow,filter->geometry.mouth};
    for(int i=0;i<6;i++) {
        struct vec4 rect; vec4_set(&rect,rects[i][0],rects[i][1],rects[i][2],rects[i][3]);
        gs_effect_set_vec4(filter->face_params[i],&rect);
    }
    gs_effect_set_float(filter->face_gain,filter->geometry.confidence);
    gs_effect_set_float(filter->guide,atomic_load(&filter->show_guide) ? 1.0f : 0.0f);
    atomic_store(&filter->render_gain,(int)(1000*filter->geometry.confidence));
    struct vec4 detail; vec4_set(&detail,atomic_load(&filter->shape)/1000.0f,atomic_load(&filter->eyes)/1000.0f,atomic_load(&filter->brows)/1000.0f,atomic_load(&filter->skin)/1000.0f);
    gs_effect_set_vec4(filter->details,&detail);
    struct vec2 px = {0};
    const float radius = fminf(12.0f, fmaxf(1.5f, 3.0f * (float)h / 720.0f));
    vec2_set(&px, radius / (float)w, radius / (float)h);
    gs_effect_set_float(filter->strength, (float)amount / 1000.0f);
    gs_effect_set_vec2(filter->pixel_size, &px);
    gs_effect_set_float(filter->comparison, comparing ? 1.0f : 0.0f);
    obs_source_process_filter_end(filter->source, filter->effect, 0, 0);
    atomic_store(&filter->state, 3);
    atomic_fetch_add(&filter->frames, 1);
}
void ws_register_skin_filter(const char *effect_path) {
    snprintf(shader_path, sizeof(shader_path), "%s", effect_path);
    struct obs_source_info info = {0};
    info.id = "churchobs_skin_soften";
    info.type = OBS_SOURCE_TYPE_FILTER;
    info.output_flags = OBS_SOURCE_VIDEO;
    info.get_name = filter_name;
    info.create = create;
    info.destroy = destroy;
    info.update = update;
    info.get_defaults = defaults;
    info.video_render = render;
    info.filter_video = track_frame;
    obs_register_source(&info);
}
