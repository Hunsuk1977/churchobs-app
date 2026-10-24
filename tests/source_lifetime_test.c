// SPDX-License-Identifier: GPL-2.0-or-later
// Ref-count model of OBS 32 SCENE_REF; exercises production teardown C code.
#include "SourceLifetime.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
struct obs_source { int refs; bool canvas_owned; };
struct obs_scene { struct obs_source source; };
struct obs_scene_item { obs_source_t *source; };
static struct obs_scene live, black;
static struct obs_source camera, skin, microphone;
static struct obs_scene_item camera_item;
static obs_source_t *outputs[2];
static bool filter_attached;
static int queue_checks;
static void setup(void) {
    live.source=(struct obs_source){3,true}; // app, canvas, output
    black.source=(struct obs_source){2,true}; // app, canvas
    camera=(struct obs_source){2,false}; // app, scene item
    skin=(struct obs_source){2,false}; // app, camera filter
    microphone=(struct obs_source){2,false}; // app, output
    camera_item.source=&camera;
    outputs[0]=&live.source; outputs[1]=&microphone;
    filter_attached=true; queue_checks=0;
}
void obs_source_release(obs_source_t *source) { assert(source->refs>0); source->refs--; }
void obs_scene_release(obs_scene_t *scene) { obs_source_release(&scene->source); }
obs_source_t *obs_scene_get_source(const obs_scene_t *scene) { return (obs_source_t*)&scene->source; }
void obs_source_remove(obs_source_t *source) {
    if (source->canvas_owned) { source->canvas_owned=false; obs_source_release(source); }
}
void obs_set_output_source(uint32_t channel,obs_source_t *source) {
    assert(channel<2); if(outputs[channel])obs_source_release(outputs[channel]);
    outputs[channel]=source; if(source)source->refs++;
}
void obs_sceneitem_remove(obs_sceneitem_t *item) {
    assert(item->source); obs_source_release(item->source); item->source=NULL;
}
void obs_source_filter_remove(obs_source_t *parent,obs_source_t *filter) {
    assert(parent==&camera && filter==&skin && filter_attached);
    filter_attached=false; obs_source_release(filter);
}
bool obs_wait_for_destroy_queue(void) {
    assert(!live.source.refs && !black.source.refs);
    assert(!camera.refs && !skin.refs && !microphone.refs);
    assert(!filter_attached && !camera_item.source);
    return queue_checks++==0;
}
int main(void) {
    setup();
    // Reproduce old release-only semantics: canvas/scene references remain.
    obs_set_output_source(0,NULL); obs_set_output_source(1,NULL);
    obs_scene_release(&live); obs_scene_release(&black);
    obs_source_release(&skin); obs_source_release(&camera); obs_source_release(&microphone);
    assert(live.source.refs==1 && black.source.refs==1 && camera.refs==1 && skin.refs==1);
    setup();
    obs_scene_t *scene=&live,*blank=&black; obs_sceneitem_t *item=&camera_item;
    obs_source_t *cam=&camera,*filter=&skin,*mic=&microphone;
    ws_release_owned_sources(&scene,&blank,&item,&cam,&filter,&mic);
    assert(!scene&&!blank&&!item&&!cam&&!filter&&!mic);
    assert(queue_checks==2);
    ws_release_owned_sources(&scene,&blank,&item,&cam,&filter,&mic);
    assert(queue_checks==3); // no double releases
    puts("PASS source lifetime: canvas references, filter detach, queue drain, repeat cleanup");
    return 0;
}
