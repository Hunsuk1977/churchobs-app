// SPDX-License-Identifier: GPL-2.0-or-later
#ifndef WS_STUDIO_LAYOUT_H
#define WS_STUDIO_LAYOUT_H
// Shared by the real AppKit workspace and portable geometry tests. Points, not pixels.
typedef struct { double x,y,width,height; } WSRect;
typedef struct { WSRect stage,inspector,sidebar,scenes,countdown,footer,status; } WSLayoutFrames;
static inline WSRect ws_rect(double x,double y,double width,double height) {
    WSRect r={x,y,width,height}; return r;
}
static inline WSLayoutFrames ws_studio_layout(double width,double height,int page,int performance,int countdown) {
    WSLayoutFrames f={0};
    const double margin=16, gap=16;
    f.status=ws_rect(margin,height-margin-72,width-2*margin,72);
    f.footer=ws_rect(margin,f.status.y-8-44,width-2*margin,44);
    double bottom=f.footer.y-12;
    if(performance) { f.scenes=ws_rect(margin,bottom-104,width-2*margin,104); bottom=f.scenes.y-12; }
    if(countdown) { f.countdown=ws_rect(margin,bottom-32,width-2*margin,32); bottom=f.countdown.y-12; }
    double bodyHeight=bottom-margin;
    if(bodyHeight<0) bodyHeight=0;
    f.stage=ws_rect(margin,margin,width-2*margin,bodyHeight);
    if(!performance && page==0) {
        f.inspector=ws_rect(margin,margin,360,bodyHeight);
        f.stage.x=margin+360+gap; f.stage.width=width-f.stage.x-margin;
    } else if(!performance) {
        double sidebar=page==1 ? 156 : 0;
        double inspector=page==1 ? 300 : 360;
        if(sidebar) f.sidebar=ws_rect(margin,margin,sidebar,bodyHeight);
        f.inspector=ws_rect(width-margin-inspector,margin,inspector,bodyHeight);
        f.stage.x=margin+(sidebar ? sidebar+gap : 0);
        f.stage.width=f.inspector.x-gap-f.stage.x;
    }
    if(f.stage.width<0) f.stage.width=0;
    return f;
}
#endif
