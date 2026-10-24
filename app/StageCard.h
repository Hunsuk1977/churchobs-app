// SPDX-License-Identifier: GPL-2.0-or-later
#import <AppKit/AppKit.h>
#include <obs.h>
void ws_register_stage_card(void);
obs_source_t *ws_create_stage_card(NSInteger scene, NSString *text, NSString *imagePath);

bool ws_update_stage_card(obs_source_t *source, NSInteger scene, NSString *text, NSString *imagePath);
