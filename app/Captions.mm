// SPDX-License-Identifier: GPL-2.0-or-later
// WORDaLIVE 자막 띠. WORDaLIVE 방송 자막(BroadcastTicker)과 같은 모양으로 그린다:
// 띠 전체에 배경색, 가운데 글 영역에 왼쪽 정렬, 최신 문장이 맨 아래·밝게, 지난 문장은 위로 흐려지며 밀려 올라간다.
// 글자는 메인 스레드에서 AppKit으로 그리고, 그래픽 스레드에서는 텍스처만 올린다.
#import <AppKit/AppKit.h>
#include "Captions.h"
#include <graphics/graphics.h>
#include <algorithm>
#include <cmath>
#include <mutex>
#include <set>
#include <string>
#include <vector>

namespace {
constexpr uint32_t W=1920, BandH=360, BoxH=884;   // 띠(1~2문장) · 상자형(3문장, 반반 배치용)

struct Line { std::string translated, source; };

struct Captions {
    obs_source_t *self=nullptr;
    std::mutex mutex;
    uint32_t h=BandH;
    std::vector<uint8_t> pixels=std::vector<uint8_t>(W*BandH*4,0);
    bool dirty=true;
    gs_texture_t *texture=nullptr;
    uint32_t textureH=BandH;
    bool showSource=false, background=true;
    int fontSize=56, lines=1;
};

std::mutex registryMutex;
std::set<Captions *> live;
std::vector<Line> current;
ws_caption_style style={};

NSFont *fontFor(NSString *family, CGFloat size, int weight) {
    NSFontWeight w = weight>=800 ? NSFontWeightHeavy : weight>=700 ? NSFontWeightBold : weight>=600 ? NSFontWeightSemibold
                   : weight>=500 ? NSFontWeightMedium : weight<=300 ? NSFontWeightLight : NSFontWeightRegular;
    NSFont *system=[NSFont systemFontOfSize:size weight:w];
    if(!family.length || [family caseInsensitiveCompare:@"Inter"]==NSOrderedSame || [family hasPrefix:@"system"]) return system;
    // 설치된 글꼴이면 그 글꼴의 해당 굵기, 없으면 시스템 글꼴 (한글은 시스템이 알아서 대체)
    NSFontDescriptor *d=[NSFontDescriptor fontDescriptorWithFontAttributes:@{NSFontFamilyAttribute:family,
        NSFontTraitsAttribute:@{NSFontWeightTrait:@(w)}}];
    NSFont *f=[NSFont fontWithDescriptor:d size:size];
    return (f && [f.familyName caseInsensitiveCompare:family]==NSOrderedSame) ? f : system;
}
NSColor *rgba(const double c[4]) { return [NSColor colorWithSRGBRed:c[0] green:c[1] blue:c[2] alpha:c[3]]; }

void paint(Captions *c, const std::vector<Line> &all) {
    const uint32_t H=c->h;
    std::vector<uint8_t> buffer(W*H*4,0);
    ws_caption_style s=style;
    const bool box=c->lines>=3;
    // 글자 크기: WORDaLIVE 값은 1280 무대 기준 → 이 소스가 놓이는 칸(띠=무대 전체 너비, 상자형=반반 배치의 704)에 맞춰 키운다
    CGFloat size=s.active ? (CGFloat)(s.size*(W/(box ? 704.0 : 1280.0))) : (CGFloat)c->fontSize;
    size=std::clamp<CGFloat>(size,20,180);
    int maxLines=s.active ? std::clamp(s.lines,1,box ? 6 : 3) : c->lines;
    if(!box) maxLines=std::min(maxLines,3);
    std::vector<Line> shown;
    for(const Line &l:all) if(!l.translated.empty() || (c->showSource && !l.source.empty())) shown.push_back(l);
    if((int)shown.size()>maxLines) shown.erase(shown.begin(),shown.end()-maxLines);
    double bg[4]={0,0,0,0.55}, fg[4]={1,1,1,1};
    if(s.active) { std::copy(s.bg,s.bg+4,bg); std::copy(s.fg,s.fg+4,fg); }
    if(!c->background) bg[3]=0;

    CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx=CGBitmapContextCreate(buffer.data(),W,H,8,W*4,space,kCGImageAlphaPremultipliedFirst|kCGBitmapByteOrder32Little);
    if(ctx && !shown.empty()) {
        // 1) 띠 배경
        CGContextSetRGBFillColor(ctx,bg[0],bg[1],bg[2],bg[3]);
        CGContextFillRect(ctx,CGRectMake(0,0,W,H));
        // 2) 글자는 따로 그려 위쪽을 부드럽게 지운 뒤 얹는다
        std::vector<uint8_t> textPixels(W*H*4,0);
        CGContextRef tctx=CGBitmapContextCreate(textPixels.data(),W,H,8,W*4,space,kCGImageAlphaPremultipliedFirst|kCGBitmapByteOrder32Little);
        if(tctx) {
            [NSGraphicsContext saveGraphicsState];
            NSGraphicsContext.currentContext=[NSGraphicsContext graphicsContextWithCGContext:tctx flipped:NO];
            NSFont *main=fontFor(s.active ? [NSString stringWithUTF8String:s.family] : @"",size,s.active ? s.weight : 600);
            NSFont *small=fontFor(s.active ? [NSString stringWithUTF8String:s.family] : @"",size*0.62,500);
            NSMutableParagraphStyle *para=[NSMutableParagraphStyle new];
            para.alignment=NSTextAlignmentNatural; para.lineBreakMode=NSLineBreakByWordWrapping;
            para.lineHeightMultiple=box ? 1.18 : 1.1; para.paragraphSpacing=size*(box ? 0.45 : 0.18);
            NSShadow *shadow=[NSShadow new];
            shadow.shadowColor=[NSColor colorWithWhite:0 alpha:bg[3]>0.4 ? 0.6 : 0.9];
            shadow.shadowBlurRadius=size*0.18; shadow.shadowOffset=NSMakeSize(0,-size*0.04);
            NSMutableAttributedString *text=[NSMutableAttributedString new];
            for(size_t i=0;i<shown.size();i++) {
                // 최신 문장은 또렷하게, 지난 문장은 차례로 흐리게
                size_t age=shown.size()-1-i;
                double alpha=age==0 ? 1.0 : age==1 ? 0.72 : 0.5;
                NSColor *color=rgba(fg); color=[color colorWithAlphaComponent:fg[3]*alpha];
                if(i) [text appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:@{NSFontAttributeName:main,NSParagraphStyleAttributeName:para}]];
                NSString *src=[NSString stringWithUTF8String:shown[i].source.c_str()] ?: @"";
                NSString *tr=[NSString stringWithUTF8String:shown[i].translated.c_str()] ?: @"";
                if(c->showSource && src.length)
                    [text appendAttributedString:[[NSAttributedString alloc] initWithString:[src stringByAppendingString:tr.length ? @"\u2028" : @""]
                        attributes:@{NSFontAttributeName:small,NSForegroundColorAttributeName:[color colorWithAlphaComponent:fg[3]*alpha*0.7],NSParagraphStyleAttributeName:para,NSShadowAttributeName:shadow}]];
                if(tr.length)
                    [text appendAttributedString:[[NSAttributedString alloc] initWithString:tr
                        attributes:@{NSFontAttributeName:main,NSForegroundColorAttributeName:color,NSParagraphStyleAttributeName:para,NSShadowAttributeName:shadow}]];
            }
            const CGFloat padX=box ? std::max<CGFloat>(48,size*0.9) : W*0.05;
            const CGFloat padY=std::max<CGFloat>(18,size*(box ? 0.6 : 0.32));
            double pct=s.active ? std::clamp(s.content_pct,50.0,100.0) : 100.0;
            const CGFloat column=(W-2*padX)*pct/100.0;
            NSRect bounds=[text boundingRectWithSize:NSMakeSize(column,100000) options:NSStringDrawingUsesLineFragmentOrigin];
            const CGFloat textH=ceil(bounds.size.height);
            // 아래쪽 정렬: 넘치면 위(오래된 말)부터 띠 밖으로 밀려난다
            NSRect rect=NSMakeRect((W-column)/2,padY,column,textH);
            [text drawWithRect:rect options:NSStringDrawingUsesLineFragmentOrigin];
            [NSGraphicsContext restoreGraphicsState];
            // 위쪽 끝은 잘린 티가 나지 않게 부드럽게 사라지도록
            const CGFloat top=H-padY*0.5, fade=std::min<CGFloat>(size*1.2,H*0.3);
            if(textH>H-padY*1.5) {
                CGContextSetBlendMode(tctx,kCGBlendModeDestinationOut);
                CGFloat comps[8]={0,0,0,1, 0,0,0,0};
                CGFloat locs[2]={0,1};
                CGGradientRef g=CGGradientCreateWithColorComponents(space,comps,locs,2);
                CGContextDrawLinearGradient(tctx,g,CGPointMake(0,top),CGPointMake(0,top-fade),kCGGradientDrawsBeforeStartLocation);
                CGGradientRelease(g);
            }
            CGImageRef image=CGBitmapContextCreateImage(tctx);
            if(image) { CGContextDrawImage(ctx,CGRectMake(0,0,W,H),image); CGImageRelease(image); }
            CGContextRelease(tctx);
        }
    }
    if(ctx) CGContextRelease(ctx);
    CGColorSpaceRelease(space);
    // OBS 기본 효과는 곧은(straight) 알파를 기대한다
    for(size_t i=0;i<buffer.size();i+=4) {
        uint8_t a=buffer[i+3];
        if(a && a<255) for(int k=0;k<3;k++) buffer[i+k]=(uint8_t)std::min(255,buffer[i+k]*255/a);
    }
    std::lock_guard<std::mutex> guard(c->mutex);
    c->pixels.swap(buffer); c->dirty=true; c->textureH=H;
}

void readSettings(Captions *c, obs_data_t *settings) {
    c->showSource=obs_data_get_bool(settings,"show_source");
    c->background=obs_data_get_bool(settings,"background");
    c->fontSize=(int)obs_data_get_int(settings,"font_size");
    c->lines=std::clamp((int)obs_data_get_int(settings,"lines"),1,3);
    c->h=c->lines>=3 ? BoxH : BandH;
}

const char *captionsName(void *) { return "WORDaLIVE Captions"; }
void captionsDefaults(obs_data_t *s) {
    obs_data_set_default_bool(s,"background",true); obs_data_set_default_int(s,"font_size",56); obs_data_set_default_int(s,"lines",1);
}
void *captionsCreate(obs_data_t *settings, obs_source_t *source) {
    auto *c=new Captions(); c->self=source; readSettings(c,settings);
    std::vector<Line> snapshot;
    { std::lock_guard<std::mutex> guard(registryMutex); live.insert(c); snapshot=current; }
    if([NSThread isMainThread]) paint(c,snapshot);
    else dispatch_sync(dispatch_get_main_queue(),^{ paint(c,snapshot); });
    return c;
}
void captionsDestroy(void *data) {
    auto *c=static_cast<Captions *>(data);
    { std::lock_guard<std::mutex> guard(registryMutex); live.erase(c); }
    if(c->texture) { obs_enter_graphics(); gs_texture_destroy(c->texture); obs_leave_graphics(); }
    delete c;
}
void captionsUpdate(void *data, obs_data_t *settings) {
    auto *c=static_cast<Captions *>(data); readSettings(c,settings);
    dispatch_async(dispatch_get_main_queue(),^{
        std::lock_guard<std::mutex> guard(registryMutex);
        if(live.count(c)) paint(c,current);
    });
}
uint32_t captionsWidth(void *) { return W; }
uint32_t captionsHeight(void *data) { return static_cast<Captions *>(data)->h; }
void captionsRender(void *data, gs_effect_t *) {
    auto *c=static_cast<Captions *>(data);
    {
        std::lock_guard<std::mutex> guard(c->mutex);
        if(c->dirty) {
            const uint8_t *planes[1]={c->pixels.data()};
            if(c->texture && gs_texture_get_height(c->texture)!=c->textureH) { gs_texture_destroy(c->texture); c->texture=nullptr; }
            if(!c->texture) c->texture=gs_texture_create(W,c->textureH,GS_BGRA,1,planes,GS_DYNAMIC);
            else gs_texture_set_image(c->texture,c->pixels.data(),W*4,false);
            c->dirty=false;
        }
    }
    if(c->texture) obs_source_draw(c->texture,0,0,0,0,false);
}
}

void ws_register_captions(void) {
    struct obs_source_info info={};
    info.id="church_captions";
    info.type=OBS_SOURCE_TYPE_INPUT;
    info.output_flags=OBS_SOURCE_VIDEO|OBS_SOURCE_DO_NOT_DUPLICATE|OBS_SOURCE_CAP_DISABLED;
    info.get_name=captionsName;
    info.get_defaults=captionsDefaults;
    info.create=captionsCreate;
    info.destroy=captionsDestroy;
    info.update=captionsUpdate;
    info.get_width=captionsWidth;
    info.get_height=captionsHeight;
    info.video_render=captionsRender;
    obs_register_source(&info);
}

void ws_captions_set_lines(const char *const *translated, const char *const *source, int count) {
    std::vector<Line> next;
    for(int i=0;i<count;i++) next.push_back({translated[i] ? translated[i] : "",source[i] ? source[i] : ""});
    std::lock_guard<std::mutex> guard(registryMutex);
    current=next;
    for(Captions *c:live) paint(c,current);
}

void ws_captions_set_style(const struct ws_caption_style *next) {
    std::lock_guard<std::mutex> guard(registryMutex);
    if(next) style=*next; else style=ws_caption_style{};
    for(Captions *c:live) paint(c,current);
}
