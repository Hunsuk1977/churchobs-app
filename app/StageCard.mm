// SPDX-License-Identifier: GPL-2.0-or-later
#import "StageCard.h"
#include <util/platform.h>
#include <cstring>
#include <algorithm>
#include <mutex>
namespace {
struct Card { obs_source_t *source=nullptr; uint8_t *pixels=nullptr; std::mutex mutex; };
const char *cardName(void *) { return "Church OBS stage card"; }
void *createCard(obs_data_t *settings, obs_source_t *source) {
    @autoreleasepool {
        NSString *encoded=[NSString stringWithUTF8String:obs_data_get_string(settings,"pixels")];
        NSData *data=[[NSData alloc] initWithBase64EncodedString:encoded options:0];
        if(data.length!=1280*720*4) return nullptr;
        Card *card=new Card; card->source=source; card->pixels=static_cast<uint8_t *>(bmemdup(data.bytes,data.length));
        return card;
    }
}
void updateCard(void *opaque, obs_data_t *settings) {
    @autoreleasepool {
        NSString *encoded=[NSString stringWithUTF8String:obs_data_get_string(settings,"pixels")];
        NSData *data=[[NSData alloc] initWithBase64EncodedString:encoded options:0];
        if(data.length!=1280*720*4) return;
        Card *card=static_cast<Card *>(opaque);
        uint8_t *copy=static_cast<uint8_t *>(bmemdup(data.bytes,data.length));
        { std::lock_guard<std::mutex> guard(card->mutex); std::swap(card->pixels,copy); }
        bfree(copy);
    }
}
void destroyCard(void *opaque) { Card *card=static_cast<Card *>(opaque); bfree(card->pixels); delete card; }
void tickCard(void *opaque,float seconds) {
    (void)seconds; Card *card=static_cast<Card *>(opaque);
    std::lock_guard<std::mutex> guard(card->mutex);
    obs_source_frame frame={}; frame.data[0]=card->pixels; frame.linesize[0]=1280*4;
    frame.width=1280; frame.height=720; frame.format=VIDEO_FORMAT_BGRA;
    frame.timestamp=os_gettime_ns(); frame.full_range=true;
    obs_source_output_video(card->source,&frame);
}
void drawText(NSString *text, NSRect rect, CGFloat size, NSColor *color, NSTextAlignment alignment) {
    NSMutableParagraphStyle *style=[NSMutableParagraphStyle new]; style.alignment=alignment;
    style.lineBreakMode=NSLineBreakByWordWrapping;
    [text drawInRect:rect withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:size weight:NSFontWeightSemibold],NSForegroundColorAttributeName:color,NSParagraphStyleAttributeName:style}];
}
}
void ws_register_stage_card(void) {
    obs_source_info info={}; info.id="churchobs_stage_card"; info.type=OBS_SOURCE_TYPE_INPUT;
    info.output_flags=OBS_SOURCE_ASYNC_VIDEO;
    info.get_name=cardName; info.create=createCard; info.destroy=destroyCard; info.update=updateCard; info.video_tick=tickCard;
    obs_register_source(&info);
}
static NSData *renderCardPixels(NSInteger scene, NSString *text, NSString *imagePath) {
    // Draw into an ordinary RGBA bitmap, then submit top-down premultiplied BGRA.
    NSBitmapImageRep *bitmap=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nullptr pixelsWide:1280 pixelsHigh:720 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bitmapFormat:0 bytesPerRow:1280*4 bitsPerPixel:32];
    if(!bitmap) return nil;
    memset(bitmap.bitmapData,0,1280*720*4);
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext=[NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    NSColor *background=[NSColor colorWithSRGBRed:0.055 green:0.10 blue:0.08 alpha:1];
    if(scene==0 || scene==3 || scene==4) {
        [background setFill]; NSRectFill(NSMakeRect(0,0,1280,720));
        if(imagePath.length) {
            NSImage *image=[[NSImage alloc] initWithContentsOfFile:imagePath];
            if(!image || image.size.width<=0 || image.size.height<=0) { [NSGraphicsContext restoreGraphicsState]; return nil; }
            double scale=std::min(1280.0/image.size.width,720.0/image.size.height);
            NSSize size=NSMakeSize(image.size.width*scale,image.size.height*scale);
            [image drawInRect:NSMakeRect((1280-size.width)/2,(720-size.height)/2,size.width,size.height) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
        }
        if(!imagePath.length || scene==0 || scene==4) {
            if(imagePath.length) { [[NSColor colorWithWhite:0 alpha:0.36] setFill]; NSRectFill(NSMakeRect(0,0,1280,720)); }
            drawText(scene==0 ? @"예배를 준비하고 있습니다" : scene==4 ? @"함께 예배해 주셔서 감사합니다" : @"말씀 · 자료",NSMakeRect(100,470,1080,80),38,[NSColor colorWithWhite:0.7 alpha:1],NSTextAlignmentCenter);
            drawText(text,NSMakeRect(100,155,1080,280),scene==3 ? 42 : 54,NSColor.whiteColor,NSTextAlignmentCenter);
        }
    } else if(scene==5 || scene==6) {
        [[NSColor colorWithWhite:0 alpha:0.32] setFill]; NSRectFill(NSMakeRect(0,0,1280,720));
        drawText(text,NSMakeRect(100,155,1080,330),54,NSColor.whiteColor,NSTextAlignmentCenter);
    } else if(text.length) {
        [[NSColor colorWithWhite:0 alpha:0.76] setFill]; NSRectFill(NSMakeRect(0,0,1280,scene==1 ? 180 : 108));
        drawText(text,NSMakeRect(70,18,1140,scene==1 ? 148 : 78),scene==1 ? 42 : 32,NSColor.whiteColor,scene==1 ? NSTextAlignmentCenter : NSTextAlignmentLeft);
    }
    [NSGraphicsContext restoreGraphicsState];
    NSMutableData *pixels=[NSMutableData dataWithLength:1280*720*4];
    uint8_t *dest=static_cast<uint8_t *>(pixels.mutableBytes); const uint8_t *src=bitmap.bitmapData;
    for(size_t i=0;i<1280*720;i++) { dest[4*i]=src[4*i+2]; dest[4*i+1]=src[4*i+1]; dest[4*i+2]=src[4*i]; dest[4*i+3]=src[4*i+3]; }
    return pixels;
}
bool ws_update_stage_card(obs_source_t *source, NSInteger scene, NSString *text, NSString *imagePath) {
    if(!source || strcmp(obs_source_get_unversioned_id(source),"churchobs_stage_card")) return false;
    NSData *pixels=renderCardPixels(scene,text,imagePath);
    if(!pixels) return false;
    // get_type_data returns registration-level metadata, NOT this instance's Card.
    // OBS passes the instance to info.update on its video thread.
    obs_data_t *settings=obs_data_create();
    obs_data_set_string(settings,"pixels",[pixels base64EncodedStringWithOptions:0].UTF8String);
    obs_source_update(source,settings);
    obs_data_release(settings);
    return true;
}
obs_source_t *ws_create_stage_card(NSInteger scene, NSString *text, NSString *imagePath) {
    NSData *pixels=renderCardPixels(scene,text,imagePath);
    if(!pixels) return nullptr;
    obs_data_t *settings=obs_data_create();
    obs_data_set_string(settings,"pixels",[pixels base64EncodedStringWithOptions:0].UTF8String);
    obs_source_t *source=obs_source_create_private("churchobs_stage_card","Church OBS stage",settings);
    obs_data_release(settings);
    // Private source settings retain the latest frame for deferred updates only.
    // Keeping it until the callback runs avoids erasing a pending video update.
    return source;
}
