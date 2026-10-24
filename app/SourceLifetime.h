// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include <obs.h>
#ifdef __cplusplus
extern "C" {
#endif
void ws_release_owned_sources(obs_scene_t **scene, obs_scene_t **blank,
                             obs_sceneitem_t **item, obs_source_t **camera,
                             obs_source_t **skin, obs_source_t **microphone);
#ifdef __cplusplus
}
#endif
