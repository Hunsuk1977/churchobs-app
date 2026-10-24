// SPDX-License-Identifier: GPL-2.0-or-later
#include "../app/StudioLayout.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
static void inside(WSRect r,double w,double h) {
    assert(r.width>=0 && r.height>=0 && r.x>=0 && r.y>=0);
    assert(r.x+r.width<=w+0.01 && r.y+r.height<=h+0.01);
}
int main(void) {
    const double widths[]={1120,1220,1440,1920};
    const double heights[]={720,800,930,1080};
    for(int wi=0;wi<4;wi++) for(int hi=0;hi<4;hi++) for(int page=0;page<3;page++) for(int perf=0;perf<2;perf++) for(int countdown=0;countdown<2;countdown++) {
        double w=widths[wi],h=heights[hi];
        WSLayoutFrames f=ws_studio_layout(w,h,page,perf,countdown);
        inside(f.stage,w,h);inside(f.inspector,w,h);inside(f.sidebar,w,h);inside(f.scenes,w,h);inside(f.footer,w,h);inside(f.status,w,h);inside(f.countdown,w,h);
        assert(f.stage.width>=500 && f.stage.height-36-42>=250);
        assert(f.footer.y+f.footer.height<=f.status.y);
        if(countdown) assert(f.stage.y+f.stage.height<=f.countdown.y);
        if(perf) {
            assert(fabs(f.stage.width-(w-32))<0.01);
            assert(f.stage.y+f.stage.height<=f.scenes.y);
            assert((f.scenes.width-4*10)/5>=100 && f.scenes.height>=100);
        } else if(page==0) assert(f.inspector.x+f.inspector.width<f.stage.x);
        else {
            assert(f.stage.x+f.stage.width<f.inspector.x);
            if(page==1) assert(f.sidebar.x+f.sidebar.width<f.stage.x);
        }
    }
    puts("PASS 192 native workspace layouts: preparation/editor/performance, minimum preview, pane order, scene targets and non-overlap");
    return 0;
}
