// SPDX-License-Identifier: GPL-2.0-or-later
// 가상 카메라: 설치된 "OBS Virtual Camera" 시스템 확장(CoreMediaIO 카메라 확장)의 입력(sink) 스트림에
// 송출 화면(출력 0번)을 넣는다. OBS mac-virtualcam 플러그인의 CMIO 방식(GPL-2.0)을 따랐다.
//
// 조건: OBS Studio가 설치되어 있고, OBS에서 "가상 카메라 시작"을 한 번 눌러 시스템 확장을 허용했을 것.
//       그 뒤에는 OBS를 켜지 않아도 된다. Zoom·Meet에서는 카메라를 "OBS Virtual Camera"로 고른다.
// 나중에 Apple 개발자 계정으로 서명·공증하면 "Church OBS Camera" 자체 확장으로 바꿀 수 있다.

#import <Foundation/Foundation.h>
#import <CoreMediaIO/CMIOHardware.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#include <obs.h>
#include <media-io/video-io.h>
#include "VirtualCam.h"

// OBS 공식 빌드의 가상 카메라 장치 UUID (CMakePresets.json VIRTUALCAM_DEVICE_UUID)
static NSString *const kOBSVirtualCameraUUID = @"7626645E-4425-469E-9D8B-97E0FA59AC75";

struct ws_vcam {
    obs_output_t *output = nullptr;
    CMIODeviceID device = 0;
    CMIOStreamID stream = 0;
    CMSimpleQueueRef queue = nullptr;
    CMFormatDescriptionRef format = nullptr;
    CVPixelBufferPoolRef pool = nullptr;
    bool streaming = false;
};

static bool ws_vcam_find(CMIODeviceID *deviceOut, CMIOStreamID *sinkOut) {
    CMIOObjectPropertyAddress address = {kCMIOHardwarePropertyDevices, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain};
    UInt32 size = 0, used = 0;
    if (CMIOObjectGetPropertyDataSize(kCMIOObjectSystemObject, &address, 0, nullptr, &size) != noErr || size == 0) return false;
    NSMutableData *devices = [NSMutableData dataWithLength:size];
    if (CMIOObjectGetPropertyData(kCMIOObjectSystemObject, &address, 0, nullptr, size, &used, devices.mutableBytes) != noErr) return false;
    const CMIOObjectID *ids = (const CMIOObjectID *)devices.bytes;
    for (UInt32 i = 0; i < used / sizeof(CMIOObjectID); i++) {
        CMIOObjectPropertyAddress uidAddress = {kCMIODevicePropertyDeviceUID, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain};
        CFStringRef uid = nullptr; UInt32 uidUsed = 0;
        if (CMIOObjectGetPropertyData(ids[i], &uidAddress, 0, nullptr, sizeof(uid), &uidUsed, &uid) != noErr || !uid) continue;
        BOOL match = [(__bridge NSString *)uid caseInsensitiveCompare:kOBSVirtualCameraUUID] == NSOrderedSame;
        CFRelease(uid);
        if (!match) continue;
        // 스트림: [0] 앱들이 보는 출력(source), [1] 우리가 넣는 입력(sink)
        CMIOObjectPropertyAddress streamsAddress = {kCMIODevicePropertyStreams, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain};
        UInt32 streamSize = 0, streamUsed = 0;
        if (CMIOObjectGetPropertyDataSize(ids[i], &streamsAddress, 0, nullptr, &streamSize) != noErr || streamSize < 2 * sizeof(CMIOStreamID)) return false;
        NSMutableData *streams = [NSMutableData dataWithLength:streamSize];
        if (CMIOObjectGetPropertyData(ids[i], &streamsAddress, 0, nullptr, streamSize, &streamUsed, streams.mutableBytes) != noErr) return false;
        if (deviceOut) *deviceOut = ids[i];
        if (sinkOut) *sinkOut = ((const CMIOStreamID *)streams.bytes)[1];
        return true;
    }
    return false;
}

bool ws_vcam_device_available(void) {
    return ws_vcam_find(nullptr, nullptr);
}

static const char *ws_vcam_name(void *) { return "Church OBS Virtual Camera"; }

static void *ws_vcam_create(obs_data_t *, obs_output_t *output) {
    auto *vcam = new ws_vcam();
    vcam->output = output;
    return vcam;
}

static void ws_vcam_cleanup(ws_vcam *vcam) {
    if (vcam->streaming) { CMIODeviceStopStream(vcam->device, vcam->stream); vcam->streaming = false; }
    if (vcam->format) { CFRelease(vcam->format); vcam->format = nullptr; }
    if (vcam->pool) { CVPixelBufferPoolRelease(vcam->pool); vcam->pool = nullptr; }
    vcam->queue = nullptr;   // CMIO가 소유
}

static void ws_vcam_destroy(void *data) {
    auto *vcam = (ws_vcam *)data;
    ws_vcam_cleanup(vcam);
    delete vcam;
}

static bool ws_vcam_start(void *data) {
    auto *vcam = (ws_vcam *)data;
    if (!ws_vcam_find(&vcam->device, &vcam->stream)) {
        obs_output_set_last_error(vcam->output, "OBS Virtual Camera 확장이 설치되어 있지 않습니다.");
        return false;
    }
    struct obs_video_info ovi = {};
    if (!obs_get_video_info(&ovi)) return false;

    // NV12로 받아 CoreVideo 420 형식으로 그대로 넘긴다
    struct video_scale_info conversion = {};
    conversion.format = VIDEO_FORMAT_NV12;
    conversion.width = ovi.output_width;
    conversion.height = ovi.output_height;
    conversion.colorspace = ovi.colorspace;
    conversion.range = ovi.range;
    obs_output_set_video_conversion(vcam->output, &conversion);
    const FourCharCode pixelFormat = ovi.range == VIDEO_RANGE_FULL ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                                                                   : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;

    NSDictionary *attributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(pixelFormat),
        (id)kCVPixelBufferWidthKey: @(ovi.output_width),
        (id)kCVPixelBufferHeightKey: @(ovi.output_height),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    if (CVPixelBufferPoolCreate(kCFAllocatorDefault, nullptr, (__bridge CFDictionaryRef)attributes, &vcam->pool) != kCVReturnSuccess) {
        obs_output_set_last_error(vcam->output, "가상 카메라 영상 버퍼를 만들지 못했습니다.");
        return false;
    }
    if (CMVideoFormatDescriptionCreate(kCFAllocatorDefault, pixelFormat, ovi.output_width, ovi.output_height, nullptr, &vcam->format) != noErr ||
        CMIOStreamCopyBufferQueue(vcam->stream, [](CMIOStreamID, void *, void *) {}, nullptr, &vcam->queue) != noErr) {
        ws_vcam_cleanup(vcam);
        obs_output_set_last_error(vcam->output, "가상 카메라에 연결하지 못했습니다.");
        return false;
    }
    if (CMIODeviceStartStream(vcam->device, vcam->stream) != noErr) {
        ws_vcam_cleanup(vcam);
        obs_output_set_last_error(vcam->output, "가상 카메라를 시작하지 못했습니다. OBS에서 가상 카메라를 한 번 시작해 확장을 허용하세요.");
        return false;
    }
    vcam->streaming = true;
    if (!obs_output_begin_data_capture(vcam->output, 0)) { ws_vcam_cleanup(vcam); return false; }
    blog(LOG_INFO, "[virtualcam] started %ux%u", ovi.output_width, ovi.output_height);
    return true;
}

static void ws_vcam_stop(void *data, uint64_t) {
    auto *vcam = (ws_vcam *)data;
    obs_output_end_data_capture(vcam->output);
    ws_vcam_cleanup(vcam);
    blog(LOG_INFO, "[virtualcam] stopped");
}

static void ws_vcam_copy(uint8_t *dst, size_t dstStride, const uint8_t *src, size_t srcStride, size_t rows) {
    if (dstStride == srcStride) { memcpy(dst, src, dstStride * rows); return; }
    const size_t bytes = dstStride < srcStride ? dstStride : srcStride;
    for (size_t r = 0; r < rows; r++) memcpy(dst + r * dstStride, src + r * srcStride, bytes);
}

static void ws_vcam_raw_video(void *data, struct video_data *frame) {
    auto *vcam = (ws_vcam *)data;
    if (!vcam->streaming || !vcam->queue) return;
    CVPixelBufferRef buffer = nullptr;
    if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, vcam->pool, &buffer) != kCVReturnSuccess) return;
    CVPixelBufferLockBaseAddress(buffer, 0);
    const size_t planes = CVPixelBufferGetPlaneCount(buffer);
    for (size_t p = 0; p < planes && p < 2; p++) {
        if (!frame->data[p]) break;
        ws_vcam_copy((uint8_t *)CVPixelBufferGetBaseAddressOfPlane(buffer, p), CVPixelBufferGetBytesPerRowOfPlane(buffer, p),
                     frame->data[p], frame->linesize[p], CVPixelBufferGetHeightOfPlane(buffer, p));
    }
    CVPixelBufferUnlockBaseAddress(buffer, 0);

    CMSampleTimingInfo timing = {};
    timing.presentationTimeStamp = CMTimeMake((int64_t)frame->timestamp, NSEC_PER_SEC);
    timing.duration = kCMTimeInvalid;
    timing.decodeTimeStamp = kCMTimeInvalid;
    CMSampleBufferRef sample = nullptr;
    if (CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, buffer, true, nullptr, nullptr, vcam->format, &timing, &sample) == noErr) {
        // 화상회의 앱이 늦게 가져가 대기열이 차 있으면 이번 프레임은 버린다
        if (CMSimpleQueueEnqueue(vcam->queue, sample) != noErr) CFRelease(sample);
    }
    CVPixelBufferRelease(buffer);
}

void ws_vcam_register(void) {
    static bool registered = false;
    if (registered) return;
    struct obs_output_info info = {};
    info.id = "church_virtualcam";
    info.flags = OBS_OUTPUT_VIDEO;
    info.get_name = ws_vcam_name;
    info.create = ws_vcam_create;
    info.destroy = ws_vcam_destroy;
    info.start = ws_vcam_start;
    info.stop = ws_vcam_stop;
    info.raw_video = ws_vcam_raw_video;
    obs_register_output(&info);
    registered = true;
}
