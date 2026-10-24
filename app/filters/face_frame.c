// SPDX-License-Identifier: GPL-2.0-or-later
#include "face_frame.h"
#include <stddef.h>
bool ws_prepare_face_bgra(uint8_t *pixels, uint32_t width, uint32_t height, uint32_t stride, bool flip) {
    if(!pixels || !width || !height || (uint64_t)width*4>stride) return false;
    if(flip) {
        for(uint32_t y=0;y<height/2;y++) {
            uint8_t *top=pixels+(size_t)y*stride;
            uint8_t *bottom=pixels+(size_t)(height-1-y)*stride;
            for(uint32_t x=0;x<width*4;x++) { uint8_t tmp=top[x]; top[x]=bottom[x]; bottom[x]=tmp; }
        }
    }
    for(uint32_t y=0;y<height;y++) for(uint32_t x=0;x<width;x++) pixels[(size_t)y*stride+x*4+3]=255;
    return true;
}
