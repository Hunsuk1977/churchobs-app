// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include <math.h>
typedef struct { float x,y,width,height; } WSGraphRect;
static inline double ws_graph_limit(double v,double low,double high) { return v<low ? low : v>high ? high : v; }
static inline int ws_graph_rect(double x,double y,double width,double height,WSGraphRect *out) {
    if(!out || !isfinite(x) || !isfinite(y) || !isfinite(width) || !isfinite(height)) return 0;
    width=ws_graph_limit(width,0.03,1); height=ws_graph_limit(height,0.03,1);
    x=ws_graph_limit(x,0,1-width); y=ws_graph_limit(y,0,1-height);
    out->x=(float)x; out->y=(float)y; out->width=(float)width; out->height=(float)height;
    return 1;
}
