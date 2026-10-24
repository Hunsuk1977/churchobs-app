// SPDX-License-Identifier: GPL-2.0-or-later
#include "../app/GraphGeometry.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    double values[]={-100,-1,0,0.03,0.28,0.97,1,100};
    for(int a=0;a<8;a++)for(int b=0;b<8;b++)for(int c=0;c<8;c++)for(int d=0;d<8;d++) {
        WSGraphRect r;
        assert(ws_graph_rect(values[a],values[b],values[c],values[d],&r));
        assert(r.x>=0 && r.y>=0 && r.width>=0.02999f && r.height>=0.02999f);
        assert(r.x+r.width<1.00001f && r.y+r.height<1.00001f);
    }
    WSGraphRect r;
    assert(!ws_graph_rect(NAN,0,1,1,&r));assert(!ws_graph_rect(0,0,INFINITY,1,&r));
    assert(ws_graph_rect(0.68,0.66,0.28,0.28,&r));assert(fabsf(r.x-0.68f)<0.00001f);
    puts("PASS 4096 graph geometry cases: bounded layouts, minimum size, PIP and non-finite rejection");
}
