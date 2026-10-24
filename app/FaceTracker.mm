// SPDX-License-Identifier: GPL-2.0-or-later
#import <Vision/Vision.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>
#include "FaceTracker.h"
#include "filters/face_frame.h"
#include <obs.h>
#include <media-io/video-scaler.h>
#include <util/platform.h>
#include <atomic>
#include <mutex>
#include <algorithm>
#include <cmath>
#include <cstring>

struct ws_face_tracker {
    dispatch_queue_t queue;
    std::atomic<bool> busy{false};
    uint64_t submitted=0;
    video_scaler_t *scaler=nullptr;
    uint32_t width=0,height=0,outHeight=0;
    enum video_format format=VIDEO_FORMAT_NONE;
    bool fullRange=false;
    std::mutex mutex;
    ws_face_geometry geometry{};
    uint64_t measured=0;
    int status=0;
    ws_face_diagnostics diagnostics{};
};
static void failure(ws_face_tracker *t, int state, int code, const char *stage) {
    std::lock_guard<std::mutex> lock(t->mutex);
    if(t->status!=state || t->diagnostics.error_code!=code)
        blog(LOG_WARNING,"[face] %s failed (code=%d, format=%d, %ux%u)",stage,code,(int)t->format,t->width,t->height);
    t->status=state; t->diagnostics.error_code=code;
}
static void regionRect(VNFaceLandmarkRegion2D *region, CGRect box, float out[4]) {
    if (!region || !region.pointCount) return;
    float minX=1,minY=1,maxX=0,maxY=0;
    const CGPoint *points=region.normalizedPoints;
    for(NSUInteger i=0;i<region.pointCount;i++) {
        float x=box.origin.x+points[i].x*box.size.width;
        float y=1.0-(box.origin.y+points[i].y*box.size.height);
        minX=std::min(minX,x); maxX=std::max(maxX,x);
        minY=std::min(minY,y); maxY=std::max(maxY,y);
    }
    out[0]=(minX+maxX)*0.5f; out[1]=(minY+maxY)*0.5f;
    out[2]=std::max(0.002f,(maxX-minX)*0.5f); out[3]=std::max(0.002f,(maxY-minY)*0.5f);
}
static void detect(ws_face_tracker *t, CVPixelBufferRef buffer, uint64_t submitted) {
    @autoreleasepool {
        VNDetectFaceLandmarksRequest *request=[VNDetectFaceLandmarksRequest new];
        VNImageRequestHandler *handler=[[VNImageRequestHandler alloc] initWithCVPixelBuffer:buffer orientation:kCGImagePropertyOrientationUp options:@{}];
        NSError *error=nil;
        const BOOL success=[handler performRequests:@[request] error:&error];
        VNFaceObservation *chosen=nil;
        // First version follows the largest face; never apply one face's geometry to others.
        for(VNFaceObservation *face in request.results) {
            if (!chosen || face.boundingBox.size.width*face.boundingBox.size.height > chosen.boundingBox.size.width*chosen.boundingBox.size.height) chosen=face;
        }
        ws_face_geometry g{};
        int status=success ? 2 : 6;
        if(chosen && chosen.confidence>=0.6f && chosen.landmarks.leftEye.pointCount>=3 && chosen.landmarks.rightEye.pointCount>=3) {
            CGRect b=chosen.boundingBox;
            if(b.size.width>=0.08 && b.size.height>=0.12) {
                g.face[0]=b.origin.x+b.size.width*0.5; g.face[1]=1-(b.origin.y+b.size.height*0.5);
                g.face[2]=b.size.width*0.5; g.face[3]=b.size.height*0.5;
                regionRect(chosen.landmarks.leftEye,b,g.left_eye);
                regionRect(chosen.landmarks.rightEye,b,g.right_eye);
                regionRect(chosen.landmarks.leftEyebrow,b,g.left_brow);
                regionRect(chosen.landmarks.rightEyebrow,b,g.right_brow);
                regionRect(chosen.landmarks.outerLips,b,g.mouth);
                // Avoid geometry changes on strongly turned or tilted faces.
                const double yaw=chosen.yaw ? std::abs(chosen.yaw.doubleValue) : 0;
                const double roll=chosen.roll ? std::abs(chosen.roll.doubleValue) : 0;
                g.confidence=std::clamp(float((0.65-yaw)/0.25),0.0f,1.0f)*std::clamp(float((0.55-roll)/0.20),0.0f,1.0f);
                status=g.confidence>0 ? 1 : 8;
            }
        }
        std::lock_guard<std::mutex> lock(t->mutex);
        if(!success && t->status!=6)
            blog(LOG_WARNING,"[face] Vision request failed: %s (code=%ld)",error.localizedDescription.UTF8String ?: "unknown",(long)error.code);
        t->diagnostics.analysed++;
        if(chosen) t->diagnostics.detected++;
        t->diagnostics.elapsed_ms=(int)((os_gettime_ns()-submitted)/1000000ULL);
        t->diagnostics.error_code=success ? 0 : (int)error.code;
        t->status=status;
        if(status==1) { t->geometry=g; t->measured=submitted; }
        // A miss leaves the last geometry in place, then fades it by age.
    }
}
ws_face_tracker *ws_face_tracker_create(void) {
    auto *t=new ws_face_tracker;
    t->queue=dispatch_queue_create("org.mmcnyc.churchobs.face-tracker",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INITIATED,0));
    return t;
}
void ws_face_tracker_destroy(ws_face_tracker *t) {
    if(!t) return;
    // OBS has stopped the filter callbacks before destroy. Drain Vision before free.
    dispatch_sync(t->queue,^{});
    video_scaler_destroy(t->scaler);
    delete t;
}
void ws_face_tracker_submit(ws_face_tracker *t, const struct obs_source_frame *frame) {
    if(!t || !frame || !frame->data[0] || !frame->width || !frame->height) return;
    const uint64_t now=os_gettime_ns();
    if(now-t->submitted<100000000ULL || t->busy.exchange(true)) return;
    t->submitted=now;
    { std::lock_guard<std::mutex> lock(t->mutex); t->diagnostics.submitted++; }
    if(!t->scaler || t->width!=frame->width || t->height!=frame->height || t->format!=frame->format || t->fullRange!=frame->full_range) {
        video_scaler_destroy(t->scaler); t->scaler=nullptr;
        t->width=frame->width; t->height=frame->height; t->format=frame->format; t->fullRange=frame->full_range;
        t->outHeight=std::clamp(uint32_t(480.0*frame->height/frame->width),32u,960u);
        struct video_scale_info src{}; src.format=frame->format; src.width=frame->width; src.height=frame->height;
        src.colorspace=VIDEO_CS_DEFAULT; src.range=frame->full_range ? VIDEO_RANGE_FULL : VIDEO_RANGE_PARTIAL;
        struct video_scale_info dst{}; dst.format=VIDEO_FORMAT_BGRA; dst.width=480; dst.height=t->outHeight;
        dst.colorspace=VIDEO_CS_DEFAULT; dst.range=VIDEO_RANGE_FULL;
        // OBS maps VIDEO_SCALE_BILINEAR to two FFmpeg algorithm bits. The
        // scaler rejects that combination. FAST_BILINEAR selects one algorithm.
        const int result=video_scaler_create(&t->scaler,&dst,&src,VIDEO_SCALE_FAST_BILINEAR);
        if(result!=VIDEO_SCALER_SUCCESS) {
            failure(t,3,result,"video scaler initialization"); t->busy=false; return;
        }
    }
    CVPixelBufferRef buffer=nullptr;
    const CVReturn created=CVPixelBufferCreate(kCFAllocatorDefault,480,t->outHeight,kCVPixelFormatType_32BGRA,nullptr,&buffer);
    if(created!=kCVReturnSuccess) { failure(t,4,(int)created,"pixel buffer allocation"); t->busy=false; return; }
    const CVReturn locked=CVPixelBufferLockBaseAddress(buffer,0);
    if(locked!=kCVReturnSuccess) {
        CVPixelBufferRelease(buffer); failure(t,4,(int)locked,"pixel buffer lock"); t->busy=false; return;
    }
    uint8_t *out[MAX_AV_PLANES]={static_cast<uint8_t *>(CVPixelBufferGetBaseAddress(buffer))};
    uint32_t strides[MAX_AV_PLANES]={uint32_t(CVPixelBufferGetBytesPerRow(buffer))};
    const bool scaled=video_scaler_scale(t->scaler,out,strides,frame->data,frame->linesize);
    const bool prepared=scaled && ws_prepare_face_bgra(out[0],480,t->outHeight,strides[0],frame->flip);
    CVPixelBufferUnlockBaseAddress(buffer,0);
    if(!prepared) { CVPixelBufferRelease(buffer); failure(t,5,-1,"frame conversion"); t->busy=false; return; }
    dispatch_async(t->queue,^{
        detect(t,buffer,now);
        CVPixelBufferRelease(buffer);
        t->busy=false;
    });
}
int ws_face_tracker_snapshot(ws_face_tracker *t, ws_face_geometry *g) {
    if(!t) { *g={}; return 0; }
    std::lock_guard<std::mutex> lock(t->mutex);
    *g=t->geometry;
    g->confidence*=ws_face_age_gain(t->measured ? double(os_gettime_ns()-t->measured)/1e9 : 1);
    return g->confidence>0.01f ? 1 : t->status==1 ? 7 : t->status;
}

void ws_face_tracker_details(ws_face_tracker *t, ws_face_diagnostics *details) {
    if(!t) { *details={}; return; }
    std::lock_guard<std::mutex> lock(t->mutex); *details=t->diagnostics;
}

// Mac-only integration check: run the actual converter and Vision request on
// blank NV12/BGRA frames. Recognition quality still needs a real camera face.
bool ws_face_tracker_self_test(void) {
    const enum video_format formats[]={VIDEO_FORMAT_NV12,VIDEO_FORMAT_BGRA};
    for(enum video_format format:formats) {
        ws_face_tracker *tracker=ws_face_tracker_create();
        struct obs_source_frame *frame=obs_source_frame_create(format,640,360);
        if(!frame) { ws_face_tracker_destroy(tracker); return false; }
        if(format==VIDEO_FORMAT_NV12) {
            memset(frame->data[0],16,frame->linesize[0]*360);
            memset(frame->data[1],128,frame->linesize[1]*180);
        } else {
            for(uint32_t y=0;y<360;y++) for(uint32_t x=0;x<640;x++) {
                uint8_t *pixel=frame->data[0]+y*frame->linesize[0]+x*4;
                pixel[0]=pixel[1]=pixel[2]=0; pixel[3]=255;
            }
        }
        frame->full_range=format==VIDEO_FORMAT_BGRA;
        ws_face_tracker_submit(tracker,frame);
        ws_face_geometry geometry{}; int status=0;
        for(int i=0;i<300 && status==0;i++) { os_sleep_ms(30); status=ws_face_tracker_snapshot(tracker,&geometry); }
        obs_source_frame_destroy(frame);
        ws_face_tracker_destroy(tracker);
        if(status!=2 || geometry.confidence!=0) return false;
    }
    return true;
}
