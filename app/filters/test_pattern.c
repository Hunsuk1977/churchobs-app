// SPDX-License-Identifier: GPL-2.0-or-later
// Static GPU texture with skin-coloured texture detail for real pixel A/B tests.
#include "test_pattern.h"
#include <obs-module.h>
struct pattern { gs_texture_t *texture; };
static const char *name(void *unused) { (void)unused; return "Church OBS test pattern"; }
static void *create(obs_data_t *settings, obs_source_t *source) {
    (void)settings; (void)source;
    struct pattern *pattern = bzalloc(sizeof(*pattern));
    uint8_t *pixels = bmalloc(1280*720*4);
    const int colors[4][3]={{199,150,117},{48,76,58},{25,35,28},{229,224,199}};
    for(int y=0;y<720;y++) for(int x=0;x<1280;x++) {
        int panel=x/320;
        int detail=panel==0 ? (((x/4+y/4)%2) ? 10 : -10) : 0;
        for(int c=0;c<3;c++) pixels[(y*1280+x)*4+c]=(uint8_t)(colors[panel][c]+detail);
        pixels[(y*1280+x)*4+3]=255;
    }
    const uint8_t *planes[]={pixels};
    obs_enter_graphics();
    pattern->texture=gs_texture_create(1280,720,GS_RGBA,1,planes,0);
    obs_leave_graphics();
    bfree(pixels);
    if(!pattern->texture) { bfree(pattern); return NULL; }
    return pattern;
}
static void destroy(void *opaque) {
    struct pattern *pattern=opaque;
    obs_enter_graphics(); gs_texture_destroy(pattern->texture); obs_leave_graphics(); bfree(pattern);
}
static uint32_t width(void *data) { (void)data; return 1280; }
static uint32_t height(void *data) { (void)data; return 720; }
static void render(void *opaque, gs_effect_t *unused) {
    (void)unused;
    struct pattern *pattern=opaque;
    gs_effect_t *effect=obs_get_base_effect(OBS_EFFECT_DEFAULT);
    gs_eparam_t *parameter=gs_effect_get_param_by_name(effect,"image");
    if(gs_get_linear_srgb()) gs_effect_set_texture_srgb(parameter,pattern->texture);
    else gs_effect_set_texture(parameter,pattern->texture);
    while(gs_effect_loop(effect,"Draw")) gs_draw_sprite(pattern->texture,0,1280,720);
}
void ws_register_test_pattern(void) {
    struct obs_source_info info={0};
    info.id="churchobs_test_pattern"; info.type=OBS_SOURCE_TYPE_INPUT;
    info.output_flags=OBS_SOURCE_VIDEO|OBS_SOURCE_CUSTOM_DRAW;
    info.get_name=name; info.create=create; info.destroy=destroy;
    info.get_width=width; info.get_height=height; info.video_render=render;
    obs_register_source(&info);
}
