// SPDX-License-Identifier: GPL-2.0-or-later
// Real photograph through the same async frame/filter path as macos-avcapture.
#include "face_test_input.h"
#include <obs-module.h>
#include <util/platform.h>
#include <stdio.h>
#include <string.h>
static char fixture_path[4096];
struct face_input { obs_source_t *source; uint8_t *pixels; };
static const char *get_name(void *unused) { (void)unused; return "Face tracking regression photograph"; }
static void *create(obs_data_t *settings, obs_source_t *source) {
    (void)settings;
    FILE *file=os_fopen(fixture_path,"rb");
    if(!file) return NULL;
    struct face_input *input=bzalloc(sizeof(*input));
    input->source=source; input->pixels=bmalloc(640*480*4);
    size_t bytes=fread(input->pixels,1,640*480*4,file);
    int extra=fgetc(file); fclose(file);
    if(bytes!=640*480*4 || extra!=EOF) { bfree(input->pixels); bfree(input); return NULL; }
    return input;
}
static void destroy(void *opaque) {
    struct face_input *input=opaque;
    bfree(input->pixels); bfree(input);
}
static void tick(void *opaque, float seconds) {
    (void)seconds;
    struct face_input *input=opaque;
    struct obs_source_frame frame={0};
    frame.data[0]=input->pixels; frame.linesize[0]=640*4;
    frame.width=640; frame.height=480; frame.timestamp=os_gettime_ns();
    frame.format=VIDEO_FORMAT_BGRA; frame.full_range=true;
    obs_source_output_video(input->source,&frame);
}
void ws_register_face_test_input(const char *frame_path) {
    snprintf(fixture_path,sizeof(fixture_path),"%s",frame_path);
    struct obs_source_info info={0};
    info.id="churchobs_face_test_input"; info.type=OBS_SOURCE_TYPE_INPUT;
    info.output_flags=OBS_SOURCE_ASYNC_VIDEO;
    info.get_name=get_name; info.create=create; info.destroy=destroy; info.video_tick=tick;
    obs_register_source(&info);
}
