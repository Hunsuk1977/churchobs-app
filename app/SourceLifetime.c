// SPDX-License-Identifier: GPL-2.0-or-later
#include "SourceLifetime.h"

static void remove_scene(obs_scene_t **owned)
{
    obs_scene_t *scene = *owned;
    *owned = NULL;
    if (!scene) return;
    // OBS 32's main canvas holds its own scene reference (SCENE_REF).
    // Dropping only our reference leaves the scene alive until obs_shutdown,
    // after registered source types/modules have already been torn down.
    obs_source_remove(obs_scene_get_source(scene));
    obs_scene_release(scene);
}

static void release_source(obs_source_t **owned)
{
    obs_source_t *source = *owned;
    *owned = NULL;
    if (source) obs_source_release(source);
}

void ws_release_owned_sources(obs_scene_t **scene, obs_scene_t **blank,
                             obs_sceneitem_t **item, obs_source_t **camera,
                             obs_source_t **skin, obs_source_t **microphone)
{
    obs_set_output_source(0, NULL);
    obs_set_output_source(1, NULL);
    if (*item) {
        obs_sceneitem_remove(*item);
        *item = NULL;
    }
    if (*camera && *skin) obs_source_filter_remove(*camera, *skin);
    remove_scene(scene);
    remove_scene(blank);
    release_source(skin);
    release_source(camera);
    release_source(microphone);
    // Drain deferred source/filter destruction while graphics and modules live.
    while (obs_wait_for_destroy_queue()) {}
}
