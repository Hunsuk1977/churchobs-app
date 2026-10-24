// SPDX-License-Identifier: GPL-2.0-or-later
#import "Engine.h"
#import "PreviewView.h"
#import "Localize.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <obs.h>
#include <graphics/graphics.h>
#include <graphics/vec2.h>
#include <graphics/vec4.h>
#include "VirtualCam.h"
#include "ShapeMask.h"
#include "Captions.h"
#include "Slides.h"
#include "AppAudio.h"
#include "LookFilter.h"
#include "filters/skin_filter.h"
#include "filters/test_pattern.h"
#include "filters/face_test_input.h"
#include "SourceLifetime.h"
#include "GraphState.h"
#include "GraphGeometry.h"
#import "StageCard.h"
#include <atomic>
#include <algorithm>
#include <cstring>
#include <mutex>
#include <vector>
#include <cstdlib>
#include <cstdio>
#include <util/platform.h>
#include <cmath>

namespace {
// 방송 화면 크기: 준비 화면의 화질 선택(720p/1080p). 엔진을 시작할 때 정해지고, 바꾸면 앱을 다시 시작한다
uint32_t CanvasWidth = 1280, CanvasHeight = 720;
static bool WSFullHD() { return [NSUserDefaults.standardUserDefaults integerForKey:@"WSVideoQuality"] == 1080; }
/// 맥 하드웨어 H.264 인코더(VideoToolbox). 없으면 nullptr → x264
static const char *WSHardwareH264() {
    const char *id=nullptr, *any=nullptr;
    for(size_t i=0; obs_enum_encoder_types(i,&id); i++) {
        if(!id || !strstr(id,"videotoolbox")) continue;
        const char *codec=obs_get_encoder_codec(id);
        if(!codec || strcmp(codec,"h264")!=0) continue;
        if(strstr(id,".ave.")) return id;      // Apple 하드웨어 H.264
        if(!any) any=id;
    }
    return any;
}
/// 화질·용도에 맞는 영상 인코더 (하드웨어 우선)
static obs_encoder_t *WSCreateVideoEncoder(const char *name, bool recording) {
    const bool full=WSFullHD();
    const int bitrate=recording ? (full ? 10000 : 5000) : (full ? 6000 : 3500);
    obs_data_t *settings=obs_data_create();
    obs_data_set_string(settings,"rate_control","CBR"); obs_data_set_int(settings,"bitrate",bitrate);
    obs_data_set_int(settings,"keyint_sec",2); obs_data_set_string(settings,"profile","high");
    obs_encoder_t *encoder=nullptr;
    if(const char *hw=WSHardwareH264()) {
        obs_data_set_bool(settings,"bframes",false);
#if !defined(__aarch64__)
        obs_data_set_string(settings,"rate_control","ABR");   // 인텔 맥의 하드웨어 인코더는 CBR을 못 쓰는 경우가 있다
#endif
        encoder=obs_video_encoder_create(hw,name,settings,nullptr);
    }
    if(!encoder) {
        obs_data_set_string(settings,"preset",full ? "superfast" : "veryfast");
        encoder=obs_video_encoder_create("obs_x264",name,settings,nullptr);
    }
    obs_data_release(settings);
    return encoder;
}
struct EngineCore {
    WSGraphState graph;
    bool initialized = false;
    obs_display_t *display = nullptr;
    obs_display_t *programDisplay = nullptr;   // 스튜디오 모드의 실제 송출(프로그램) 화면
    obs_display_t *projectorDisplay = nullptr; // 출력 창(프로젝터·두 번째 모니터·별도 창)에 그리는 송출 화면
    obs_output_t *virtualCam = nullptr;          // 가상 카메라 (Zoom·Meet용)
    obs_scene_t *scene = nullptr;
    obs_scene_t *blank = nullptr;
    obs_sceneitem_t *cameraItem = nullptr;
    obs_source_t *camera = nullptr;
    obs_source_t *microphone = nullptr;
    obs_source_t *skin = nullptr;
    obs_source_t *look = nullptr;          // 색 톤·배경 흐림 (Pro)
    int lookTone = 0;
    double lookToneAmount = 0.6, lookBlur = 0;
    obs_output_t *record = nullptr;
    obs_output_t *stream = nullptr;
    obs_service_t *service = nullptr;
    obs_encoder_t *streamVideo = nullptr, *streamAudio = nullptr;
    std::atomic<bool> streamStopped{false};
    std::atomic<int> streamCode{0};
    bool streamStopping=false;
    obs_source_t *stageCard=nullptr;
    obs_sceneitem_t *cardItem=nullptr;
    NSInteger stage=2;
    obs_source_t *windowCapture[5]={};
    obs_sceneitem_t *windowItems[5]={};
    bool windowEnabled[5]={};
    NSInteger captureLayout[5]={};
    obs_source_t *backgroundMusic[5]={};
    obs_source_t *activeMusic=nullptr; // Borrowed; output channel 2 owns its active reference.
    obs_encoder_t *videoEncoder = nullptr;
    obs_encoder_t *audioEncoder = nullptr;
    std::atomic<bool> stopComplete{false};
    std::atomic<int> stopCode{0};
    bool stopping = false;
    bool muted = false;
    NSInteger beauty = 0;
    bool comparison = false;
    double strength=0, skinAmount=0.65, shape=0.25, eyes=0.20, brows=0.35;
    bool testFace=false;
    bool faceGuide=false;
    uint64_t lastBeautyLog=0;
    uint64_t statBytes=0, statTime=0;       // 송출 비트레이트 계산용
    double statKbps=0;
};
struct PixelProbe {
    bool wholeFrame=false;
    bool comparePanels=false;
    std::mutex mutex;
    std::vector<uint8_t> latest;
    uint64_t received=0,rejected=0;
};
void captureProbe(void *opaque, struct video_data *frame) {
    auto *probe = static_cast<PixelProbe *>(opaque);
    {
        std::lock_guard<std::mutex> lock(probe->mutex);
        ++probe->received;
        if(!frame->data[0] || frame->linesize[0]<CanvasWidth) { ++probe->rejected; return; }
    }
    std::vector<uint8_t> sample;
    // Comparison probe pairs the same position in each 640px pane.
    if (probe->comparePanels) {
        for (uint32_t y=24; y<CanvasHeight-24; y+=3)
            for (uint32_t x=24; x<CanvasWidth/2-24; x+=3) {
                sample.push_back(frame->data[0][y*frame->linesize[0]+x]);
                sample.push_back(frame->data[0][y*frame->linesize[0]+x+CanvasWidth/2]);
            }
        std::lock_guard<std::mutex> lock(probe->mutex);
        probe->latest.swap(sample);
        return;
    }
    // Main output is NV12; sample luma in the generated skin-texture panel.
    for (uint32_t y=24; y<CanvasHeight-24; y+=3)
        for (uint32_t x=24; x<(probe->wholeFrame ? CanvasWidth-24 : 296); x+=3)
            sample.push_back(frame->data[0][y*frame->linesize[0]+x]);
    std::lock_guard<std::mutex> lock(probe->mutex);
    probe->latest.swap(sample);
}
// The OBS wrapper also increments the canvas raw-output activity count.
// Connecting video_output directly installs a listener but leaves readback idle.
struct ProbeConnection {
    PixelProbe *probe=nullptr;
    bool connected=false;
    explicit ProbeConnection(PixelProbe &target) : probe(&target) {
        if(obs_get_video()) {
            obs_add_raw_video_callback(nullptr,captureProbe,probe);
            connected=true;
        }
    }
    ProbeConnection(const ProbeConnection &)=delete;
    ProbeConnection &operator=(const ProbeConnection &)=delete;
    void stop() {
        if(connected) { obs_remove_raw_video_callback(captureProbe,probe); connected=false; }
    }
    ~ProbeConnection() { stop(); }
};
void reportProbe(const char *name, PixelProbe &probe) {
    std::lock_guard<std::mutex> lock(probe.mutex);
    fprintf(stderr,"Video probe %s: callbacks=%llu rejected=%llu sample_bytes=%zu\n",name,
      static_cast<unsigned long long>(probe.received),static_cast<unsigned long long>(probe.rejected),probe.latest.size());
}
std::vector<uint8_t> snapshot(PixelProbe &probe) {
    std::lock_guard<std::mutex> lock(probe.mutex);
    return probe.latest;
}
void pumpProbe(double seconds) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
    do { [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]]; } while (end.timeIntervalSinceNow>0);
}

bool waitForProbeFrame(PixelProbe &probe,double seconds) {
    const double deadline=NSProcessInfo.processInfo.systemUptime+seconds;
    do {
        if(!snapshot(probe).empty()) return true;
        pumpProbe(0.02);
    } while(NSProcessInfo.processInfo.systemUptime<deadline);
    return !snapshot(probe).empty();
}

void drawPreview(void *opaque, uint32_t width, uint32_t height) {
    if (!width || !height) return;
    const double scale = std::min(double(width) / CanvasWidth, double(height) / CanvasHeight);
    const int w = int(CanvasWidth * scale), h = int(CanvasHeight * scale);
    struct vec4 black;
    vec4_set(&black, 0, 0, 0, 1);
    gs_clear(GS_CLEAR_COLOR, &black, 0, 0);
    gs_viewport_push();
    gs_projection_push();
    gs_set_viewport((int(width) - w) / 2, (int(height) - h) / 2, w, h);
    gs_ortho(0, CanvasWidth, 0, CanvasHeight, -100, 100);
    auto *graph=static_cast<WSGraphState *>(opaque);
    obs_source_t *editing=nullptr;
    if(graph) { std::lock_guard<std::mutex> guard(graph->previewMutex); editing=obs_source_get_ref(graph->preview); }
    if(editing) { obs_source_video_render(editing); obs_source_release(editing); }
    else if(!graph || !graph->studioMode.load()) obs_render_main_texture();
    gs_projection_pop();
    gs_viewport_pop();
}
// 송출 화면: 항상 출력 0번(실제로 나가는 화면)만 그린다
void drawProgram(void *opaque, uint32_t width, uint32_t height) {
    (void)opaque;
    if (!width || !height) return;
    const double scale = std::min(double(width) / CanvasWidth, double(height) / CanvasHeight);
    const int w = int(CanvasWidth * scale), h = int(CanvasHeight * scale);
    struct vec4 black;
    vec4_set(&black, 0, 0, 0, 1);
    gs_clear(GS_CLEAR_COLOR, &black, 0, 0);
    gs_viewport_push();
    gs_projection_push();
    gs_set_viewport((int(width) - w) / 2, (int(height) - h) / 2, w, h);
    gs_ortho(0, CanvasWidth, 0, CanvasHeight, -100, 100);
    obs_render_main_texture();
    gs_projection_pop();
    gs_viewport_pop();
}
// 출력 창: 프로젝터 장면을 고르면 그 장면, 아니면 송출 화면
void drawProjector(void *opaque, uint32_t width, uint32_t height) {
    if (!width || !height) return;
    const double scale = std::min(double(width) / CanvasWidth, double(height) / CanvasHeight);
    const int w = int(CanvasWidth * scale), h = int(CanvasHeight * scale);
    struct vec4 black;
    vec4_set(&black, 0, 0, 0, 1);
    gs_clear(GS_CLEAR_COLOR, &black, 0, 0);
    gs_viewport_push();
    gs_projection_push();
    gs_set_viewport((int(width) - w) / 2, (int(height) - h) / 2, w, h);
    gs_ortho(0, CanvasWidth, 0, CanvasHeight, -100, 100);
    auto *graph = static_cast<WSGraphState *>(opaque);
    obs_source_t *own = nullptr;
    if (graph) { std::lock_guard<std::mutex> guard(graph->previewMutex); own = obs_source_get_ref(graph->projector); }
    if (own) { obs_source_video_render(own); obs_source_release(own); }
    else obs_render_main_texture();
    gs_projection_pop();
    gs_viewport_pop();
}
void recordStopped(void *opaque, calldata_t *data) {
    auto *core = static_cast<EngineCore *>(opaque);
    core->stopCode.store(int(calldata_int(data, "code")));
    core->stopComplete.store(true);
}
void streamStopped(void *opaque, calldata_t *data) {
    auto *core=static_cast<EngineCore *>(opaque);
    core->streamCode.store(int(calldata_int(data,"code")));
    core->streamStopped.store(true);
}
void releaseStream(EngineCore *core) {
    if(core->stream) {
        signal_handler_disconnect(obs_output_get_signal_handler(core->stream),"stop",streamStopped,core);
        obs_output_release(core->stream); core->stream=nullptr;
    }
    if(core->service) obs_service_release(core->service);
    if(core->streamVideo) obs_encoder_release(core->streamVideo);
    if(core->streamAudio) obs_encoder_release(core->streamAudio);
    core->service=nullptr; core->streamVideo=core->streamAudio=nullptr;
    core->streamStopping=false;
}
void releaseRecording(EngineCore *core) {
    if (core->record) {
        signal_handler_disconnect(obs_output_get_signal_handler(core->record), "stop", recordStopped, core);
        obs_output_release(core->record);
        core->record = nullptr;
    }
    if (core->videoEncoder) obs_encoder_release(core->videoEncoder);
    if (core->audioEncoder) obs_encoder_release(core->audioEncoder);
    core->videoEncoder = core->audioEncoder = nullptr;
    core->stopping = false;
}
NSString *stringFromUTF8(const char *text) {
    return text ? ([NSString stringWithUTF8String:text] ?: @"") : @"";
}
bool hasInput(const char *wanted) {
    const char *id = nullptr;
    for (size_t i = 0; obs_enum_input_types(i, &id); ++i) if (strcmp(id, wanted) == 0) return true;
    return false;
}
}

@interface WSEngine () {
    EngineCore *_core;
    NSString *_status;
    NSString *_lastError;
    NSString *_recordingPath;
    NSWindow *_projectorWindow;
    BOOL _projectorBuild;   // applyGraph 가 프로젝터 장면을 만드는 중
    id _projectorCloseObserver;
}
- (BOOL)installCamera:(obs_source_t *)camera;
- (void)applyBeautySettings;
- (void)applyLookSettings;
- (BOOL)fail:(NSString *)message;
@end
@implementation WSEngine
- (instancetype)init {
    self = [super init];
    if (self) { _core = new EngineCore(); _status = WSL(@"엔진 시작 전"); _lastError = @""; _recordingPath = @""; }
    return self;
}
- (void)dealloc { [self shutdown]; delete _core; }
- (BOOL)ready { return _core->initialized && _core->display && _core->scene; }
- (BOOL)recording { return _core->record && obs_output_active(_core->record); }
- (BOOL)stopping { return _core->stopping; }
- (BOOL)streaming { return _core->stream!=nullptr; }
// 송출 상태: 실제 올라가는 속도(kbps), 끊긴 프레임, 혼잡도(0~1), 재연결 중
- (NSDictionary *)streamStats {
    obs_output_t *out=_core->stream;
    if(!out || !obs_output_active(out)) { _core->statBytes=0; _core->statTime=0; _core->statKbps=0; return @{@"active":@NO}; }
    const uint64_t bytes=obs_output_get_total_bytes(out), now=os_gettime_ns();
    if(_core->statTime && now>_core->statTime+400000000ULL) {
        const double seconds=(double)(now-_core->statTime)/1e9;
        const double kbps=bytes>=_core->statBytes ? (double)(bytes-_core->statBytes)*8.0/1000.0/seconds : 0;
        _core->statKbps=_core->statKbps>0 ? _core->statKbps*0.6+kbps*0.4 : kbps;
        _core->statBytes=bytes; _core->statTime=now;
    } else if(!_core->statTime) { _core->statBytes=bytes; _core->statTime=now; }
    const int dropped=obs_output_get_frames_dropped(out), total=obs_output_get_total_frames(out);
    return @{@"active":@YES,@"kbps":@(_core->statKbps),@"dropped":@(dropped),@"frames":@(total),
             @"congestion":@(obs_output_get_congestion(out)),@"reconnecting":@(obs_output_reconnecting(out)),
             @"targetKbps":@(3500+160)};
}
- (BOOL)streamConnected { return _core->stream && !_core->streamStopping && !obs_output_reconnecting(_core->stream) && obs_output_get_total_bytes(_core->stream)>0; }
- (BOOL)hasCamera { return _core->camera != nullptr; }
- (BOOL)hasMicrophone { return _core->microphone != nullptr; }
- (NSString *)status { return _status; }
- (NSString *)lastError { return _lastError; }
- (NSString *)recordingPath { return _recordingPath; }
- (NSDictionary<NSString *, NSNumber *> *)beautyDiagnostics {
    if(!_core->skin) return @{};
    calldata_t data; calldata_init(&data);
    const bool ok=proc_handler_call(obs_source_get_proc_handler(_core->skin),"churchobs_skin_status",&data);
    NSMutableDictionary<NSString *,NSNumber *> *result=[NSMutableDictionary dictionary];
    for(NSString *key in @[@"state",@"tracking",@"frames",@"raw_frames",@"analysed",@"detected",@"elapsed_ms",@"error_code",@"gain"])
        result[key]=@(calldata_int(&data,key.UTF8String));
    result[@"available"]=@(ok); calldata_free(&data);
    return result;
}
- (NSString *)beautyStatus {
    if (!_core->skin) return WSL(@"카메라 연결 후 사용할 수 있습니다.");
    NSDictionary<NSString *,NSNumber *> *d=self.beautyDiagnostics;
    if(!d[@"available"].boolValue) return WSL(@"보정 상태 확인 실패");
    if(d[@"state"].intValue==1) return WSL(@"보정 끔 · 자연스럽게를 선택하세요");
    if(d[@"state"].intValue==4) return WSL(@"GPU 영상 처리 실패 · 보정 미적용");
    switch(d[@"tracking"].intValue) {
        case 1:
            if(d[@"gain"].intValue<10) return WSL(@"얼굴 감지됨 · 보정 준비 중");
            return _core->comparison ? WSL(@"중앙 크롭 비교 · 왼쪽 원본 / 오른쪽 보정") : WSL(@"얼굴 추적 중 · 자연 보정 적용");
        case 2: return WSL(@"얼굴을 찾는 중 · 정면을 바라봐 주세요");
        case 3: return [NSString stringWithFormat:WSL(@"영상 변환기 초기화 실패 (%@)"),d[@"error_code"]];
        case 4: return [NSString stringWithFormat:WSL(@"분석 영상 메모리 준비 실패 (%@)"),d[@"error_code"]];
        case 5: return WSL(@"카메라 영상 변환 실패 · 보정 대기");
        case 6: return [NSString stringWithFormat:WSL(@"Vision 얼굴 분석 실패 (%@)"),d[@"error_code"]];
        case 7: return WSL(@"얼굴 분석 지연 · 보정 잠시 중지");
        case 8: return WSL(@"정면을 바라보면 보정이 켜집니다");
        default: return d[@"raw_frames"].intValue ? WSL(@"얼굴 분석 시작 중") : WSL(@"카메라 원본 프레임 대기 중");
    }
}
- (BOOL)fail:(NSString *)message { _lastError = message; _status = message; return NO; }

- (BOOL)startWithPreview:(NSView *)view {
    NSAssert([NSThread isMainThread], @"Engine lifecycle must run on the main thread");
    if (self.ready) return YES;
    NSBundle *bundle = NSBundle.mainBundle;
    NSString *configPath = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"ChurchOBS/Modules"];
    NSError *directoryError = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:configPath withIntermediateDirectories:YES attributes:nil error:&directoryError]) return [self fail:directoryError.localizedDescription];
    if (!obs_startup("ko-KR", configPath.fileSystemRepresentation, nullptr)) return [self fail:WSL(@"libobs 초기화에 실패했습니다.")];
    _core->initialized = true;
    NSString *graphics = [bundle.privateFrameworksPath stringByAppendingPathComponent:@"libobs-opengl.dylib"];
    if (![NSFileManager.defaultManager fileExistsAtPath:graphics]) { [self shutdown]; return [self fail:WSL(@"앱 내부의 GPU 렌더러가 없습니다. 빌드 번들을 확인하세요.")]; }
    if (WSFullHD()) { CanvasWidth = 1920; CanvasHeight = 1080; } else { CanvasWidth = 1280; CanvasHeight = 720; }
    struct obs_video_info video = {};
    video.graphics_module = graphics.fileSystemRepresentation;
    video.fps_num = 30; video.fps_den = 1;
    video.base_width = video.output_width = CanvasWidth;
    video.base_height = video.output_height = CanvasHeight;
    video.output_format = VIDEO_FORMAT_NV12;
    video.colorspace = VIDEO_CS_709; video.range = VIDEO_RANGE_PARTIAL;
    video.scale_type = OBS_SCALE_BICUBIC; video.gpu_conversion = true;
    const int code = obs_reset_video(&video);
    if (code != OBS_VIDEO_SUCCESS) { [self shutdown]; return [self fail:[NSString stringWithFormat:WSL(@"영상 엔진 초기화 실패 (%d)"), code]]; }
    struct obs_audio_info audio = {};
    audio.samples_per_sec = 48000; audio.speakers = SPEAKERS_STEREO;
    if (!obs_reset_audio(&audio)) { [self shutdown]; return [self fail:WSL(@"오디오 엔진 초기화에 실패했습니다.")]; }

    // Only our bundled modules are loaded; no OBS app, WebSocket or user plugins.
    NSArray<NSString *> *modules = @[@"mac-avcapture", @"mac-capture", @"obs-filters", @"obs-x264", @"obs-ffmpeg", @"obs-outputs", @"rtmp-services", @"obs-transitions", @"image-source"];
    for (NSString *name in modules) {
        NSString *plugin = [bundle.builtInPlugInsPath stringByAppendingPathComponent:[name stringByAppendingString:@".plugin"]];
        NSString *binary = [[plugin stringByAppendingPathComponent:@"Contents/MacOS"] stringByAppendingPathComponent:name];
        NSString *data = [plugin stringByAppendingPathComponent:@"Contents/Resources"];
        obs_module_t *module = nullptr;
        const int result = obs_open_module(&module, binary.fileSystemRepresentation, data.fileSystemRepresentation);
        if (result != MODULE_SUCCESS || !obs_init_module(module)) { [self shutdown]; return [self fail:[NSString stringWithFormat:WSL(@"필수 엔진 모듈을 불러올 수 없습니다: %@ (%d)"), name, result]]; }
    }
    // 하드웨어 인코더는 있으면 쓰고, 없어도 x264로 계속한다
    {
        NSString *plugin = [bundle.builtInPlugInsPath stringByAppendingPathComponent:@"mac-videotoolbox.plugin"];
        NSString *binary = [plugin stringByAppendingPathComponent:@"Contents/MacOS/mac-videotoolbox"];
        obs_module_t *module = nullptr;
        if ([NSFileManager.defaultManager fileExistsAtPath:binary] &&
            obs_open_module(&module, binary.fileSystemRepresentation, [plugin stringByAppendingPathComponent:@"Contents/Resources"].fileSystemRepresentation) == MODULE_SUCCESS)
            obs_init_module(module);
    }
    obs_post_load_modules();
    NSString *effect = [bundle pathForResource:@"skin-soften" ofType:@"effect"];
    if (!effect) { [self shutdown]; return [self fail:WSL(@"피부 보정 셰이더 파일이 없습니다.")]; }
    ws_register_skin_filter(effect.fileSystemRepresentation);
    ws_register_test_pattern();
    ws_register_stage_card();
    ws_vcam_register();
    NSString *shapeEffect = [bundle pathForResource:@"shape-mask" ofType:@"effect"];
    ws_register_shape(shapeEffect ? shapeEffect.fileSystemRepresentation : "");
    ws_register_captions();
    ws_register_slides();
    ws_register_app_audio();
    NSString *lookEffect = [bundle pathForResource:@"camera-look" ofType:@"effect"];
    ws_register_look_filter(lookEffect ? lookEffect.fileSystemRepresentation : "");
    NSString *faceFrame=[bundle pathForResource:@"face-reference" ofType:@"bgra"];
    if(!faceFrame) { [self shutdown]; return [self fail:WSL(@"얼굴 추적 검사 영상이 없습니다.")]; }
    ws_register_face_test_input(faceFrame.fileSystemRepresentation);
    if (!hasInput("macos-avcapture") || !hasInput("coreaudio_input_capture")) { [self shutdown]; return [self fail:WSL(@"카메라 또는 오디오 소스가 등록되지 않았습니다.")]; }
    _core->scene = obs_scene_create("Camera");
    _core->blank = obs_scene_create("Black");
    if (!_core->scene || !_core->blank) { [self shutdown]; return [self fail:WSL(@"장면을 생성하지 못했습니다.")]; }
    obs_set_output_source(0, obs_scene_get_source(_core->scene));
    struct gs_init_data display = {};
    NSRect pixels = [view convertRectToBacking:view.bounds];
    display.window.view = view;
    display.cx = std::max(1u, (uint32_t)pixels.size.width);
    display.cy = std::max(1u, (uint32_t)pixels.size.height);
    display.format = GS_BGRA; display.zsformat = GS_ZS_NONE;
    _core->display = obs_display_create(&display, 0xff101712);
    if (!_core->display) { [self shutdown]; return [self fail:WSL(@"GPU 미리보기 화면을 만들지 못했습니다.")]; }
    obs_display_add_draw_callback(_core->display, drawPreview, &_core->graph);
    _lastError = @"";
    _status = [NSString stringWithFormat:WSL(@"libobs %s · %dp / 30fps · 엔진 준비됨"), obs_get_version_string(), int(CanvasHeight)];
    return YES;
}
// 가상 카메라: 송출 화면(출력 0번)을 OBS Virtual Camera 장치로 보낸다
- (BOOL)setVirtualCameraEnabled:(BOOL)enabled {
    if (!self.ready) return [self fail:WSL(@"영상 엔진을 먼저 시작하세요.")];
    if (!enabled) {
        if (_core->virtualCam && obs_output_active(_core->virtualCam)) obs_output_stop(_core->virtualCam);
        _lastError = @""; return YES;
    }
    if (!ws_vcam_device_available())
        return [self fail:WSL(@"가상 카메라 장치가 없습니다. OBS Studio를 설치하고 OBS에서 ‘가상 카메라 시작’을 한 번 눌러 확장을 허용하세요.")];
    if (!_core->virtualCam) _core->virtualCam = obs_output_create("church_virtualcam", "Church OBS Virtual Camera", nullptr, nullptr);
    if (!_core->virtualCam) return [self fail:WSL(@"가상 카메라 출력을 만들지 못했습니다.")];
    if (obs_output_active(_core->virtualCam)) { _lastError = @""; return YES; }
    if (!obs_output_start(_core->virtualCam)) {
        const char *error = obs_output_get_last_error(_core->virtualCam);
        return [self fail:error && *error ? [NSString stringWithUTF8String:error] : WSL(@"가상 카메라를 시작하지 못했습니다.")];
    }
    _lastError = @""; return YES;
}
- (BOOL)virtualCameraActive { return _core->virtualCam && obs_output_active(_core->virtualCam); }
- (BOOL)virtualCameraAvailable {
    // 장치 목록 조회는 가볍지 않으므로 3초마다만 확인
    static NSTimeInterval checkedAt = 0; static BOOL cached = NO;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (now - checkedAt > 3) { cached = ws_vcam_device_available(); checkedAt = now; }
    return cached || self.virtualCameraActive;
}
- (BOOL)attachProgramView:(NSView *)view {
    if (!self.ready || !view) return NO;
    if (_core->programDisplay) { [self resizeProgram:view]; return YES; }
    struct gs_init_data display = {};
    NSRect pixels = [view convertRectToBacking:view.bounds];
    display.window.view = view;
    display.cx = std::max(1u, (uint32_t)pixels.size.width);
    display.cy = std::max(1u, (uint32_t)pixels.size.height);
    display.format = GS_BGRA; display.zsformat = GS_ZS_NONE;
    _core->programDisplay = obs_display_create(&display, 0xff000000);
    if (!_core->programDisplay) return [self fail:WSL(@"송출 화면 미리보기를 만들지 못했습니다.")];
    obs_display_add_draw_callback(_core->programDisplay, drawProgram, nullptr);
    blog(LOG_INFO, "[studio] program monitor attached");
    return YES;
}
// ── 출력 창: 송출 화면을 다른 모니터(프로젝터)나 별도 창에 그대로 띄운다 ──
- (BOOL)openProjectorOnDisplay:(NSString *)displayUUID windowed:(BOOL)windowed {
    if (!self.ready) return [self fail:WSL(@"영상 엔진을 먼저 시작하세요.")];
    [self closeProjector];
    NSScreen *target = nil;
    for (NSScreen *screen in NSScreen.screens) {
        NSNumber *number = screen.deviceDescription[@"NSScreenNumber"];
        CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID((CGDirectDisplayID)number.unsignedIntValue);
        if (!uuid) continue;
        NSString *text = CFBridgingRelease(CFUUIDCreateString(nullptr, uuid)); CFRelease(uuid);
        if ([text isEqualToString:displayUUID]) { target = screen; break; }
    }
    if (!target) target = NSScreen.screens.count > 1 ? NSScreen.screens[1] : NSScreen.mainScreen;
    NSRect frame = windowed ? NSMakeRect(0, 0, 960, 540) : target.frame;
    NSWindowStyleMask style = windowed ? (NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable) : NSWindowStyleMaskBorderless;
    NSWindow *window = [[NSWindow alloc] initWithContentRect:frame styleMask:style backing:NSBackingStoreBuffered defer:NO screen:target];
    window.title = WSL(@"Church OBS 출력");
    window.backgroundColor = NSColor.blackColor;
    window.releasedWhenClosed = NO;
    window.hasShadow = windowed;
    if (!windowed) {
        window.level = NSScreenSaverWindowLevel - 1;   // 전체 화면: 메뉴 막대·독 위
        window.collectionBehavior = NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorStationary;
    } else {
        window.collectionBehavior = NSWindowCollectionBehaviorFullScreenAuxiliary;
        [window center];
        if (windowed) window.contentAspectRatio = NSMakeSize(16, 9);
    }
    WSPreviewView *view = [[WSPreviewView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, frame.size.height)];
    view.wantsLayer = YES; view.layer.backgroundColor = NSColor.blackColor.CGColor;
    window.contentView = view;
    struct gs_init_data display = {};
    NSRect pixels = [view convertRectToBacking:view.bounds];
    display.window.view = view;
    display.cx = std::max(1u, (uint32_t)pixels.size.width);
    display.cy = std::max(1u, (uint32_t)pixels.size.height);
    display.format = GS_BGRA; display.zsformat = GS_ZS_NONE;
    _core->projectorDisplay = obs_display_create(&display, 0xff000000);
    if (!_core->projectorDisplay) { [window close]; return [self fail:WSL(@"출력 창을 만들지 못했습니다.")]; }
    obs_display_add_draw_callback(_core->projectorDisplay, drawProjector, &_core->graph);
    __weak WSEngine *weakSelf = self;
    view.sizeChanged = ^(NSView *changed) {
        WSEngine *strongSelf = weakSelf; if (!strongSelf || !strongSelf->_core->projectorDisplay) return;
        NSRect size = [changed convertRectToBacking:changed.bounds];
        obs_display_resize(strongSelf->_core->projectorDisplay, std::max(1u, (uint32_t)size.size.width), std::max(1u, (uint32_t)size.size.height));
    };
    _projectorWindow = window;
    _projectorCloseObserver = [NSNotificationCenter.defaultCenter addObserverForName:NSWindowWillCloseNotification object:window queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *) {
        WSEngine *strongSelf = weakSelf; if (strongSelf) [strongSelf closeProjector];
    }];
    if (windowed) [window makeKeyAndOrderFront:nil]; else [window orderFront:nil];
    blog(LOG_INFO, "[studio] projector opened (%s)", windowed ? "window" : "fullscreen");
    return YES;
}
- (void)closeProjector {
    if (_projectorCloseObserver) { [NSNotificationCenter.defaultCenter removeObserver:_projectorCloseObserver]; _projectorCloseObserver = nil; }
    if (_core->projectorDisplay) {
        obs_display_remove_draw_callback(_core->projectorDisplay, drawProjector, &_core->graph);
        obs_display_destroy(_core->projectorDisplay); _core->projectorDisplay = nullptr;
    }
    if (_projectorWindow) { NSWindow *window = _projectorWindow; _projectorWindow = nil; ((WSPreviewView *)window.contentView).sizeChanged = nil; [window orderOut:nil]; }
}
- (BOOL)projectorOpen { return _projectorWindow != nil; }
- (void)resizeProgram:(NSView *)view {
    if (!_core->programDisplay) return;
    NSRect pixels = [view convertRectToBacking:view.bounds];
    obs_display_resize(_core->programDisplay, std::max(1u, (uint32_t)pixels.size.width), std::max(1u, (uint32_t)pixels.size.height));
}
- (void)setStudioMode:(BOOL)enabled { _core->graph.studioMode.store(enabled); }
- (void)resizePreview:(NSView *)view {
    if (!_core->display) return;
    NSRect pixels = [view convertRectToBacking:view.bounds];
    obs_display_resize(_core->display, std::max(1u, (uint32_t)pixels.size.width), std::max(1u, (uint32_t)pixels.size.height));
}
- (NSArray<NSDictionary<NSString *, NSString *> *> *)cameras {
    NSMutableArray *items = [NSMutableArray array];
    // Device IDs are passed directly to OBS's macos-avcapture 'device' setting.
    // This API also works on macOS 13; newer discovery APIs are a follow-up.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    for (AVCaptureDevice *device in [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo]) [items addObject:@{@"id":device.uniqueID, @"name":device.localizedName}];
#pragma clang diagnostic pop
    return items;
}
- (NSArray<NSDictionary<NSString *, NSString *> *> *)microphones {
    NSMutableArray *items = [NSMutableArray array];
    if (!self.ready) return items;
    obs_properties_t *properties = obs_get_source_properties("coreaudio_input_capture");
    obs_property_t *list = properties ? obs_properties_get(properties, "device_id") : nullptr;
    if (list) for (size_t i = 0; i < obs_property_list_item_count(list); ++i) {
        NSString *id = stringFromUTF8(obs_property_list_item_string(list, i));
        if (id.length) [items addObject:@{@"id":id, @"name":stringFromUTF8(obs_property_list_item_name(list, i))}];
    }
    if (properties) obs_properties_destroy(properties);
    return items;
}
- (BOOL)selectCamera:(NSString *)device {
    if (!self.ready || !device.length) return [self fail:WSL(@"카메라를 선택하세요.")];
    if (self.recording || self.stopping || self.streaming) return [self fail:WSL(@"녹화 중에는 카메라 장치를 바꿀 수 없습니다.")];
    obs_data_t *settings = obs_get_source_defaults("macos-avcapture");
    if (!settings) settings = obs_data_create();
    obs_data_set_string(settings, "device", device.UTF8String);
    obs_data_set_bool(settings, "use_preset", true);
    obs_data_set_string(settings, "preset", AVCaptureSessionPresetHigh.UTF8String);
    obs_data_set_bool(settings, "enable_audio", false);
    obs_data_set_bool(settings, "buffering", false);
    obs_source_t *camera = obs_source_create("macos-avcapture", "Church OBS Camera", settings, nullptr);
    obs_data_release(settings);
    if (!camera) return [self fail:WSL(@"카메라 소스 생성 실패. 권한과 장치 사용 상태를 확인하세요.")];
    return [self installCamera:camera];
}
- (BOOL)selectTestPattern {
    if (!self.ready || self.recording || self.stopping || self.streaming) return NO;
    obs_source_t *source = obs_source_create("churchobs_test_pattern", "Generated Test Pattern", nullptr, nullptr);
    if (!source) return [self fail:WSL(@"엔진 테스트 소스 생성 실패")];
    return [self installCamera:source];
}
- (BOOL)selectFaceTestInput {
    if(!self.ready || self.recording || self.stopping || self.streaming) return NO;
    obs_source_t *source=obs_source_create("churchobs_face_test_input","Reference Face",nullptr,nullptr);
    if(!source) return [self fail:WSL(@"얼굴 추적 검사 영상을 불러오지 못했습니다.")];
    return [self installCamera:source];
}
- (BOOL)installCamera:(obs_source_t *)camera {
    _core->testFace=strcmp(obs_source_get_unversioned_id(camera),"churchobs_test_pattern")==0;
    obs_source_t *skin = obs_source_create("churchobs_skin_soften", "Natural Skin", nullptr, nullptr);
    if (!skin) { obs_source_release(camera); return [self fail:WSL(@"피부 보정 셰이더를 초기화하지 못했습니다.")]; }
    obs_source_filter_add(camera, skin);
    obs_source_t *look = obs_source_create_private("church_camera_look", "Camera look", nullptr);
    if (look) obs_source_filter_add(camera, look);
    if (_core->look) obs_source_release(_core->look);
    _core->look = look;
    if (_core->cameraItem) { obs_sceneitem_remove(_core->cameraItem); _core->cameraItem = nullptr; }
    if (_core->skin) obs_source_release(_core->skin);
    if (_core->camera) obs_source_release(_core->camera);
    _core->camera = camera; _core->skin = skin;
    _core->cameraItem = obs_scene_add(_core->scene, camera);
    struct vec2 bounds; vec2_set(&bounds, CanvasWidth, CanvasHeight);
    obs_sceneitem_set_bounds_type(_core->cameraItem, OBS_BOUNDS_SCALE_INNER);
    obs_sceneitem_set_bounds(_core->cameraItem, &bounds);
    obs_sceneitem_set_alignment(_core->cameraItem, OBS_ALIGN_LEFT | OBS_ALIGN_TOP);
    obs_sceneitem_set_bounds_alignment(_core->cameraItem, 0);
    obs_sceneitem_set_visible(_core->cameraItem,_core->stage==1 || _core->stage==2);
    if(_core->cardItem) obs_sceneitem_set_order(_core->cardItem,OBS_ORDER_MOVE_TOP);
    [self applyBeautySettings];
    [self applyLookSettings];
    [self applyCaptureComposition];
    _lastError = @""; _status = WSL(@"카메라 소스 생성됨 · 화면이 검으면 권한과 장치를 확인하세요.");
    return YES;
}
- (BOOL)selectMicrophone:(NSString *)device {
    if (!self.ready || !device.length) return [self fail:WSL(@"마이크를 선택하세요.")];
    if (self.recording || self.stopping || self.streaming) return [self fail:WSL(@"녹화 중에는 마이크 장치를 바꿀 수 없습니다.")];
    obs_data_t *settings = obs_data_create();
    obs_data_set_string(settings, "device_id", device.UTF8String);
    obs_source_t *microphone = obs_source_create("coreaudio_input_capture", "Church OBS Microphone", settings, nullptr);
    obs_data_release(settings);
    if (!microphone) return [self fail:WSL(@"마이크 소스를 만들지 못했습니다.")];
    obs_set_output_source(1, microphone);
    if (_core->microphone) obs_source_release(_core->microphone);
    _core->microphone = microphone;
    auto meter=std::make_unique<WSGraphInput>(); meter->source=obs_source_get_ref(microphone);
    meter->meter=obs_volmeter_create(OBS_FADER_LOG);
    if(meter->meter) { obs_volmeter_add_callback(meter->meter,ws_graph_meter,meter.get()); obs_volmeter_attach_source(meter->meter,microphone); }
    _core->graph.mainMic=std::move(meter);
    obs_source_set_muted(microphone, _core->muted);
    _lastError = @""; _status = WSL(@"마이크 연결됨 · 테스트 녹화로 소리를 확인하세요.");
    return YES;
}
- (void)setCameraSceneVisible:(BOOL)visible {
    if (self.ready) obs_set_output_source(0, obs_scene_get_source(visible ? _core->scene : _core->blank));
}
- (BOOL)setLoopMediaAtPath:(NSString *)path scene:(NSInteger)scene {
    return [self setSceneMedia:path scene:scene music:NO];
}
- (BOOL)setBackgroundMusicAtPath:(NSString *)path scene:(NSInteger)scene {
    return [self setSceneMedia:path scene:scene music:YES];
}
- (BOOL)setSceneMedia:(NSString *)path scene:(NSInteger)scene music:(BOOL)music {
    if(!self.ready || (scene!=0 && scene!=4) || self.recording || self.stopping || self.streaming) return NO;
    if(path.length && ![NSFileManager.defaultManager fileExistsAtPath:path]) return [self fail:WSL(@"선택한 미디어 파일이 없습니다.")];
    obs_source_t *source=nullptr; obs_sceneitem_t *item=nullptr;
    if(path.length) {
        obs_data_t *settings=obs_data_create();
        obs_data_set_bool(settings,"is_local_file",true); obs_data_set_string(settings,"local_file",path.UTF8String);
        obs_data_set_bool(settings,"looping",true); obs_data_set_bool(settings,"restart_on_activate",true);
        obs_data_set_bool(settings,"close_when_inactive",true);
        NSString *name=[NSString stringWithFormat:@"Worship %@ %ld",music ? @"music" : @"video",(long)scene];
        source=obs_source_create_private("ffmpeg_source",name.UTF8String,settings); obs_data_release(settings);
        if(!source) return [self fail:WSL(@"미디어를 열 수 없습니다. 파일 형식을 확인하세요.")];
        obs_source_set_volume(source,music ? 0.25f : 1.0f);
        // Audio uses its own output channel: MP3 cover art can never cover the video.
        if(!music) {
            item=obs_scene_add(_core->scene,source);
            if(!item) { obs_source_release(source); return [self fail:WSL(@"미디어 레이어를 만들지 못했습니다.")]; }
        }
    }
    obs_sceneitem_t **items=music ? nullptr : _core->windowItems;
    obs_source_t **sources=music ? _core->backgroundMusic : _core->windowCapture;
    if(items && items[scene]) obs_sceneitem_remove(items[scene]);
    if(sources[scene]) obs_source_release(sources[scene]);
    if(items) items[scene]=item;
    sources[scene]=source;
    if(!music) _core->windowEnabled[scene]=source!=nullptr;
    if(_core->windowCapture[scene]) obs_source_set_muted(_core->windowCapture[scene],_core->backgroundMusic[scene]!=nullptr);
    [self applyCaptureComposition]; _lastError=@""; return YES;
}
- (BOOL)selectCaptureWindow:(uint32_t)windowID scene:(NSInteger)scene {
    if(!self.ready || scene<1 || scene>3 || !windowID || self.recording || self.stopping || self.streaming) return NO;
    obs_data_t *settings=obs_data_create();
    obs_data_set_int(settings,"type",1); // ScreenCaptureKit window mode.
    obs_data_set_int(settings,"window",windowID);
    obs_data_set_bool(settings,"show_cursor",false);
    obs_data_set_bool(settings,"hide_obs",false);
    NSString *name=[NSString stringWithFormat:@"Church OBS window %ld",(long)scene];
    obs_source_t *source=obs_source_create_private("screen_capture",name.UTF8String,settings);
    obs_data_release(settings);
    if(!source) return [self fail:WSL(@"윈도우 캡처를 시작하지 못했습니다. 화면 녹화 권한과 선택한 창을 확인하세요.")];
    obs_source_set_muted(source,true); // Window sources may capture app audio; use only the explicit microphone/music mix.
    obs_sceneitem_t *item=obs_scene_add(_core->scene,source);
    if(!item) { obs_source_release(source); return [self fail:WSL(@"캡처 레이어를 만들지 못했습니다.")]; }
    if(_core->windowItems[scene]) obs_sceneitem_remove(_core->windowItems[scene]);
    if(_core->windowCapture[scene]) obs_source_release(_core->windowCapture[scene]);
    _core->windowCapture[scene]=source; _core->windowItems[scene]=item; _core->windowEnabled[scene]=true;
    [self applyCaptureComposition]; _lastError=@""; return YES;
}
- (void)setWindowCaptureEnabled:(BOOL)enabled scene:(NSInteger)scene {
    if(scene<1 || scene>3 || self.recording || self.stopping || self.streaming) return;
    _core->windowEnabled[scene]=enabled && _core->windowCapture[scene]; [self applyCaptureComposition];
}
- (void)setCaptureLayout:(NSInteger)layout scene:(NSInteger)scene {
    if(scene<1 || scene>3 || self.recording || self.stopping || self.streaming) return;
    _core->captureLayout[scene]=std::clamp<NSInteger>(layout,0,2); [self applyCaptureComposition];
}
- (void)placeItem:(obs_sceneitem_t *)item x:(float)x y:(float)y width:(float)width height:(float)height {
    if(!item) return;
    // 좌표는 1280×720 기준으로 적혀 있다 → 실제 방송 크기(720p/1080p)에 맞춰 늘린다
    const float k=float(CanvasWidth)/1280.0f;
    struct vec2 position,bounds; vec2_set(&position,x*k,y*k); vec2_set(&bounds,width*k,height*k);
    obs_sceneitem_set_pos(item,&position);
    obs_sceneitem_set_alignment(item,OBS_ALIGN_LEFT|OBS_ALIGN_TOP);
    obs_sceneitem_set_bounds_type(item,OBS_BOUNDS_SCALE_INNER);
    obs_sceneitem_set_bounds_alignment(item,0); obs_sceneitem_set_bounds(item,&bounds);
}
- (void)applyCaptureComposition {
    if(!self.ready || !_core->scene) return;
    NSInteger stage=_core->stage;
    bool capture=_core->windowEnabled[stage] && _core->windowItems[stage];
    for(NSInteger i=0;i<5;i++) {
        if(_core->windowItems[i]) obs_sceneitem_set_visible(_core->windowItems[i],capture && i==stage);

    }
    if(_core->activeMusic!=_core->backgroundMusic[stage]) {
        obs_set_output_source(2,_core->backgroundMusic[stage]);
        _core->activeMusic=_core->backgroundMusic[stage];
    }
    NSInteger layout=_core->captureLayout[stage];
    if(capture) {
        [self placeItem:_core->windowItems[stage] x:0 y:0 width:layout==2 ? 896 : 1280 height:720];
        obs_sceneitem_set_order(_core->windowItems[stage],OBS_ORDER_MOVE_TOP);
        if(_core->cameraItem) {
            obs_sceneitem_set_visible(_core->cameraItem,layout!=0);
            if(layout==1) [self placeItem:_core->cameraItem x:930 y:494 width:320 height:180];
            else [self placeItem:_core->cameraItem x:896 y:0 width:384 height:720];
            obs_sceneitem_set_order(_core->cameraItem,OBS_ORDER_MOVE_TOP);
        }
    } else if(_core->cameraItem) {
        [self placeItem:_core->cameraItem x:0 y:0 width:1280 height:720];
        obs_sceneitem_set_visible(_core->cameraItem,stage==1 || stage==2);
    }
    if(_core->cardItem) obs_sceneitem_set_order(_core->cardItem,OBS_ORDER_MOVE_TOP);
}
- (BOOL)setWorshipScene:(NSInteger)scene text:(NSString *)text imagePath:(NSString *)path {
    if(!self.ready || scene<0 || scene>4) return [self fail:WSL(@"예배 장면을 선택하세요.")];
    const bool capture=_core->windowEnabled[scene] && _core->windowCapture[scene];
    NSInteger cardScene=capture ? (scene==0 ? 5 : scene==4 ? 6 : scene==3 ? 2 : scene) : scene;
    NSString *cardText=capture && scene==3 ? @"" : text;
    NSString *cardPath=capture ? @"" : path;
    if(_core->stageCard) {
        if(!ws_update_stage_card(_core->stageCard,cardScene,cardText,cardPath)) return [self fail:WSL(@"장면을 갱신하지 못했습니다. 이미지 파일을 확인하세요.")];
    } else {
        obs_source_t *card=ws_create_stage_card(cardScene,cardText,cardPath);
        if(!card) return [self fail:WSL(@"장면을 만들지 못했습니다. 이미지 파일을 확인하세요.")];
        obs_sceneitem_t *item=obs_scene_add(_core->scene,card);
        if(!item) { obs_source_release(card); return [self fail:WSL(@"장면을 추가하지 못했습니다.")]; }
        _core->cardItem=item; _core->stageCard=card;
    }
    _core->stage=scene;
    if(_core->cameraItem) obs_sceneitem_set_visible(_core->cameraItem,scene==1 || scene==2);
    [self applyCaptureComposition];
    obs_set_output_source(0,obs_scene_get_source(_core->scene));
    _lastError=@"";
    return YES;
}
- (void)setMicrophoneMuted:(BOOL)muted {
    _core->muted = muted;
    if (_core->microphone) obs_source_set_muted(_core->microphone, muted || (_core->graph.program && _core->graph.sceneMicMuted));
}
- (void)applyBeautySettings {
    // 추가 카메라도 같은 보정 (비교 화면·검사용 얼굴은 주 카메라에서만)
    for(auto &pair:_core->graph.inputs) {
        if(!pair.second || !pair.second->skin) continue;
        WSGraphInput *input=pair.second.get();
        // 이 카메라만의 설정이면 그 단계(끔·자연스럽게·조금 더)의 값, 아니면 공통 값
        const int own=input->ownBeauty;
        const double strength=input->ownLook ? (own==0 ? 0 : own==1 ? 0.70 : 1.0) : _core->strength;
        const double skin=input->ownLook ? (own==2 ? 0.78 : 0.65) : _core->skinAmount;
        const double shape=input->ownLook ? (own==2 ? 0.40 : 0.25) : _core->shape;
        const double eyes=input->ownLook ? (own==2 ? 0.35 : 0.20) : _core->eyes;
        const double brows=input->ownLook ? (own==2 ? 0.55 : 0.35) : _core->brows;
        obs_data_t *extra=obs_data_create();
        obs_data_set_double(extra,"strength",strength);
        obs_data_set_double(extra,"skin",skin);
        obs_data_set_double(extra,"shape",shape);
        obs_data_set_double(extra,"eyes",eyes);
        obs_data_set_double(extra,"brows",brows);
        obs_data_set_bool(extra,"comparison",false);
        obs_data_set_bool(extra,"test_face",false);
        obs_data_set_bool(extra,"face_guide",_core->faceGuide);
        obs_source_update(pair.second->skin,extra); obs_data_release(extra);
    }
    if (!_core->skin) return;
    obs_data_t *settings=obs_data_create();
    obs_data_set_double(settings,"strength",_core->strength);
    obs_data_set_double(settings,"skin",_core->skinAmount);
    obs_data_set_double(settings,"shape",_core->shape);
    obs_data_set_double(settings,"eyes",_core->eyes);
    obs_data_set_double(settings,"brows",_core->brows);
    obs_data_set_bool(settings,"comparison",_core->comparison);
    obs_data_set_bool(settings,"test_face",_core->testFace);
    obs_data_set_bool(settings,"face_guide",_core->faceGuide);
    obs_source_update(_core->skin,settings); obs_data_release(settings);
}
- (void)applyLookSettings {
    auto apply=[&](obs_source_t *filter,int tone,double amount,double blur) {
        if(!filter) return;
        obs_data_t *settings=obs_data_create();
        obs_data_set_int(settings,"tone",tone);
        obs_data_set_double(settings,"tone_amount",amount);
        obs_data_set_double(settings,"blur",blur);
        obs_source_update(filter,settings); obs_data_release(settings);
    };
    apply(_core->look,_core->lookTone,_core->lookToneAmount,_core->lookBlur);
    for(auto &pair:_core->graph.inputs) {
        WSGraphInput *input=pair.second.get();
        if(!input || !input->look) continue;
        if(input->ownLook) apply(input->look,input->ownTone,input->ownToneAmount,input->ownBlur);
        else apply(input->look,_core->lookTone,_core->lookToneAmount,_core->lookBlur);
    }
}
- (void)setLookTone:(NSInteger)tone amount:(double)amount blur:(double)blur {
    auto clamp=[](double value) { return std::isfinite(value) ? std::clamp(value,0.0,1.0) : 0.0; };
    _core->lookTone=(int)std::clamp<NSInteger>(tone,0,4);
    _core->lookToneAmount=clamp(amount);
    _core->lookBlur=clamp(blur);
    [self applyLookSettings];
}
- (NSInteger)lookTone { return _core->lookTone; }
- (double)lookToneAmount { return _core->lookToneAmount; }
- (double)lookBlur { return _core->lookBlur; }
- (void)setBeautyPreset:(NSInteger)preset {
    _core->beauty=std::clamp<NSInteger>(preset,0,2);
    _core->strength=_core->beauty==0 ? 0 : _core->beauty==1 ? 0.70 : 1.0;
    _core->skinAmount=_core->beauty==2 ? 0.78 : 0.65;
    _core->shape=_core->beauty==2 ? 0.40 : 0.25;
    _core->eyes=_core->beauty==2 ? 0.35 : 0.20;
    _core->brows=_core->beauty==2 ? 0.55 : 0.35;
    [self applyBeautySettings];
}
- (void)setBeautyStrength:(double)strength skin:(double)skin shape:(double)shape eyes:(double)eyes brows:(double)brows {
    auto clamp=[](double value) { return std::isfinite(value) ? std::clamp(value,0.0,1.0) : 0.0; };
    _core->strength=clamp(strength); _core->skinAmount=clamp(skin); _core->shape=clamp(shape);
    _core->eyes=clamp(eyes); _core->brows=clamp(brows);
    [self applyBeautySettings];
}
- (void)setFaceGuide:(BOOL)enabled {
    _core->faceGuide=enabled; [self applyBeautySettings];
}
- (void)setBeautyComparison:(BOOL)enabled {
    _core->comparison=enabled;
    [self applyBeautySettings];
}
- (BOOL)verifyBeautyOnTestPattern {
    if (!_core->camera || strcmp(obs_source_get_unversioned_id(_core->camera),"churchobs_test_pattern")!=0)
        return [self fail:WSL(@"보정 픽셀 검사는 생성 테스트 영상에서만 실행합니다.")];
    const double savedStrength=_core->strength,savedSkin=_core->skinAmount,savedShape=_core->shape,savedEyes=_core->eyes,savedBrows=_core->brows;
    const bool comparison = _core->comparison;
    PixelProbe probe;
    ProbeConnection probeConnection(probe);
    if(!probeConnection.connected) return [self fail:WSL(@"보정 검사 영상 출력이 준비되지 않았습니다.")];
    [self setBeautyComparison:NO]; [self setBeautyPreset:0];
    pumpProbe(0.8);
    if(!waitForProbeFrame(probe,5.0)) {
        reportProbe("beauty baseline",probe);
        [self setBeautyStrength:savedStrength skin:savedSkin shape:savedShape eyes:savedEyes brows:savedBrows];
        [self setBeautyComparison:comparison];
        return [self fail:WSL(@"GPU 검사 프레임을 받지 못했습니다. 엔진 로그의 Video probe 항목을 확인하세요.")];
    }
    auto original=snapshot(probe); reportProbe("beauty baseline",probe);
    auto difference=[&](const std::vector<uint8_t> &pixels) {
        if(original.empty() || pixels.size()!=original.size()) return -1.0;
        double total=0;
        for(size_t i=0;i<original.size();i++) total+=std::abs(int(original[i])-int(pixels[i]));
        return total/original.size();
    };
    bool passed=!original.empty();
    // Exercise each GPU control independently; synthetic geometry is confined to
    // the generated source. These checks do not claim to test Vision detection.
    const char *names[]={"skin","shape","eyes","brows"};
    for(int i=0;i<4;i++) {
        [self setBeautyStrength:1 skin:(i==0?0.78:0) shape:(i==1?1:0) eyes:(i==2?1:0) brows:(i==3?1:0)];
        pumpProbe(0.8);
        const double mean=difference(snapshot(probe));
        fprintf(stderr,"Beauty GPU control %s: mean_luma_difference=%.4f\n",names[i],mean);
        if(mean < (i==0 ? 0.20 : 0.003)) passed=false;
    }
    // With beauty off, the two central crops must contain identical pixels.
    // The old left/right slicing fails this check on the multicolour pattern.
    PixelProbe pairedProbe;
    pairedProbe.comparePanels=true;
    ProbeConnection pairedConnection(pairedProbe);
    if(pairedConnection.connected) {
        [self setBeautyPreset:0]; [self setBeautyComparison:YES];
        pumpProbe(0.8);
        auto pairs=snapshot(pairedProbe);
        double pairMean=-1.0;
        if (!pairs.empty() && pairs.size()%2==0) {
            double total=0;
            for (size_t i=0;i<pairs.size();i+=2) total+=std::abs(int(pairs[i])-int(pairs[i+1]));
            pairMean=total/(pairs.size()/2);
        }
        fprintf(stderr,"Comparison identical centre crops: mean_luma_difference=%.4f\n",pairMean);
        if (pairMean<0 || pairMean>0.03) passed=false;
        pairedConnection.stop();
    } else passed=false;
    [self setBeautyComparison:NO];
    // With no tracked face, even maximum settings must become a pass-through.
    _core->testFace=false;
    [self setBeautyStrength:1 skin:1 shape:1 eyes:1 brows:1];
    pumpProbe(1.2);
    const double noFace=difference(snapshot(probe));
    fprintf(stderr,"Beauty no-face bypass: mean_luma_difference=%.4f\n",noFace);
    if(noFace<0 || noFace>0.03) passed=false;
    _core->testFace=true;
    probeConnection.stop();
    [self setBeautyStrength:savedStrength skin:savedSkin shape:savedShape eyes:savedEyes brows:savedBrows];
    [self setBeautyComparison:comparison];
    if(!passed) return [self fail:WSL(@"얼굴 보정 GPU 검사 실패 · logs/engine-smoke.log를 확인하세요.")];
    return YES;
}
- (BOOL)verifyFaceTrackingPipeline {
    if(!_core->camera || strcmp(obs_source_get_unversioned_id(_core->camera),"churchobs_face_test_input")!=0)
        return [self fail:WSL(@"실제 얼굴 경로 검사는 기준 사진에서만 실행합니다.")];
    [self setFaceGuide:NO]; [self setBeautyComparison:NO]; [self setBeautyPreset:0];
    PixelProbe probe; probe.wholeFrame=true;
    ProbeConnection probeConnection(probe);
    if(!probeConnection.connected) return [self fail:WSL(@"얼굴 보정 검사 영상 출력이 준비되지 않았습니다.")];
    pumpProbe(0.8);
    if(!waitForProbeFrame(probe,5.0)) { reportProbe("face baseline",probe); return [self fail:WSL(@"실제 얼굴 검사 프레임을 받지 못했습니다.")]; }
    auto original=snapshot(probe); reportProbe("face baseline",probe);
    [self setBeautyPreset:2];
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:12.0];
    NSDictionary<NSString *,NSNumber *> *d=nil;
    do {
        pumpProbe(0.1); d=self.beautyDiagnostics;
        if(d[@"tracking"].intValue==1 && d[@"gain"].intValue>=500 && d[@"analysed"].intValue>=3) break;
    } while(deadline.timeIntervalSinceNow>0);
    pumpProbe(0.4); auto processed=snapshot(probe);
    probeConnection.stop();
    double mean=-1;
    if(!original.empty() && original.size()==processed.size()) {
        double total=0;
        for(size_t i=0;i<original.size();i++) total+=std::abs(int(original[i])-int(processed[i]));
        mean=total/original.size();
    }
    d=self.beautyDiagnostics;
    fprintf(stderr,"Real face pipeline: raw=%lld analysed=%lld detected=%lld tracking=%d gain=%d latency_ms=%d mean_Y_difference=%.4f error=%d\n",
      d[@"raw_frames"].longLongValue,d[@"analysed"].longLongValue,d[@"detected"].longLongValue,
      d[@"tracking"].intValue,d[@"gain"].intValue,d[@"elapsed_ms"].intValue,mean,d[@"error_code"].intValue);
    if(d[@"tracking"].intValue!=1 || d[@"gain"].intValue<500 || d[@"analysed"].intValue<3 || mean<0.015)
        return [self fail:[WSL(@"실제 얼굴 처리 경로 검사 실패: ") stringByAppendingString:self.beautyStatus]];
    return YES;
}
- (BOOL)verifyStreamingComponents {
    // Construct the actual output and service, but do not start a connection.
    obs_data_t *settings=obs_data_create();
    obs_data_set_string(settings,"server","rtmps://127.0.0.1/live");
    obs_data_set_string(settings,"key","unused-local-smoke-key");
    obs_service_t *service=obs_service_create("rtmp_custom","Smoke RTMPS",settings,nullptr);
    obs_data_release(settings);
    obs_output_t *output=obs_output_create("rtmp_output","Smoke RTMP Output",nullptr,nullptr);
    const bool valid=service && output && strcmp(obs_service_get_protocol(service),"RTMPS")==0;
    if(output) obs_output_release(output);
    if(service) obs_service_release(service);
    if(!valid) return [self fail:WSL(@"RTMPS 서비스/출력 모듈 검사 실패")];
    fprintf(stderr,"PASS RTMPS service/output construction (no network connection)\n");
    return YES;
}
- (BOOL)verifyWorshipScenes {
    PixelProbe probe; probe.wholeFrame=true;
    ProbeConnection probeConnection(probe);
    if(!probeConnection.connected) return [self fail:WSL(@"장면 검사 영상 출력이 준비되지 않았습니다.")];
    bool passed=true; std::vector<uint8_t> previous;
    NSArray<NSString *> *texts=@[WSL(@"Welcome · 예배 대기"),WSL(@"Praise · 찬양 가사"),WSL(@"Sermon · 오늘의 말씀"),WSL(@"Scripture · 성경 본문"),WSL(@"Thank you · 예배 종료")];
    obs_source_t *sharedCard=nullptr;
    for(NSInteger scene=0;scene<5;scene++) {
        if(![self setWorshipScene:scene text:texts[scene] imagePath:@""]) { passed=false; break; }
        if(sharedCard && sharedCard!=_core->stageCard) passed=false;
        sharedCard=_core->stageCard;
        pumpProbe(0.35);
        if(!waitForProbeFrame(probe,5.0)) { reportProbe("worship scene",probe); passed=false; break; }
        auto pixels=snapshot(probe);
        double delta=0;
        if(pixels.empty()) passed=false;
        if(!previous.empty() && pixels.size()==previous.size()) {
            for(size_t i=0;i<pixels.size();i++) delta+=std::abs(int(pixels[i])-int(previous[i]));
            delta/=pixels.size();
            if(delta<0.01) passed=false;
        }
        fprintf(stderr,"Worship scene %ld: samples=%zu previous_mean_Y_difference=%.4f\n",(long)scene,pixels.size(),delta);
        previous=std::move(pixels);
    }
    // The countdown changes pixels while retaining the SAME scene/source instance.
    if([self setWorshipScene:0 text:@"COUNTDOWN 05:00" imagePath:@""]) {
        pumpProbe(0.35); auto before=snapshot(probe);
        if(![self setWorshipScene:0 text:@"COUNTDOWN 00:01" imagePath:@""]) passed=false;
        pumpProbe(0.35); auto after=snapshot(probe);
        double delta=0;
        if(before.empty() || before.size()!=after.size()) passed=false;
        else {
            for(size_t i=0;i<before.size();i++) delta+=std::abs(int(before[i])-int(after[i]));
            delta/=before.size();
            if(delta<0.01) passed=false;
        }
        if(_core->stageCard!=sharedCard) passed=false;
        fprintf(stderr,"Same-source countdown pixel difference: %.4f\n",delta);
    } else passed=false;
    probeConnection.stop();
    if(![self setWorshipScene:2 text:@"" imagePath:@""]) passed=false;
    if(!passed) return [self fail:WSL(@"예배 장면 GPU 출력 검사 실패")];
    return YES;
}
- (BOOL)startRecordingAtPath:(NSString *)path {
    if (!self.ready || !self.hasCamera) return [self fail:WSL(@"카메라를 먼저 연결하세요.")];
    if (self.recording || self.stopping) return NO;
    [self setBeautyComparison:NO]; [self setFaceGuide:NO];
    if (_core->record) releaseRecording(_core);
    _core->stopComplete.store(false); _core->stopCode.store(0);
    _core->videoEncoder = WSCreateVideoEncoder("Recording Video", true);
    obs_data_t *asettings = obs_data_create();
    obs_data_set_int(asettings, "bitrate", 160);
    _core->audioEncoder = obs_audio_encoder_create("ffmpeg_aac", "Recording Audio", asettings, 0, nullptr);
    obs_data_release(asettings);
    if (!_core->videoEncoder || !_core->audioEncoder) { releaseRecording(_core); return [self fail:WSL(@"H.264 또는 AAC 인코더를 만들지 못했습니다.")]; }
    obs_encoder_set_video(_core->videoEncoder, obs_get_video());
    obs_encoder_set_audio(_core->audioEncoder, obs_get_audio());
    obs_data_t *settings = obs_data_create();
    obs_data_set_string(settings, "path", path.fileSystemRepresentation);
    _core->record = obs_output_create("ffmpeg_muxer", "Local Recording", settings, nullptr);
    obs_data_release(settings);
    if (!_core->record) { releaseRecording(_core); return [self fail:WSL(@"MKV 녹화 출력을 만들지 못했습니다.")]; }
    obs_output_set_video_encoder(_core->record, _core->videoEncoder);
    obs_output_set_audio_encoder(_core->record, _core->audioEncoder, 0);
    signal_handler_connect(obs_output_get_signal_handler(_core->record), "stop", recordStopped, _core);
    if (!obs_output_start(_core->record)) {
        NSString *detail = stringFromUTF8(obs_output_get_last_error(_core->record));
        releaseRecording(_core);
        return [self fail:[WSL(@"녹화 시작 실패: ") stringByAppendingString:detail.length ? detail : WSL(@"출력 경로 또는 인코더를 확인하세요.")]];
    }
    _recordingPath = [path copy]; _lastError = @""; _status = WSL(@"로컬 녹화 중");
    return YES;
}
- (void)stopRecording {
    if (!_core->record || _core->stopping) return;
    _core->stopping = true; _status = WSL(@"녹화 파일을 마무리하는 중…");
    obs_output_stop(_core->record);
}
- (BOOL)startStreamToServer:(NSString *)server key:(NSString *)key {
    if(!self.ready || !self.hasCamera || !self.hasMicrophone) return [self fail:WSL(@"카메라와 마이크를 먼저 연결하세요.")];
    if(self.streaming || ![server hasPrefix:@"rtmps://"] || !key.length) return [self fail:WSL(@"송출 상태 또는 RTMPS 주소를 확인하세요.")];
    [self setBeautyComparison:NO]; [self setFaceGuide:NO];
    _core->streamVideo=WSCreateVideoEncoder("Stream Video",false);
    obs_data_t *audio=obs_data_create(); obs_data_set_int(audio,"bitrate",160);
    _core->streamAudio=obs_audio_encoder_create("ffmpeg_aac","Stream Audio",audio,0,nullptr); obs_data_release(audio);
    obs_data_t *settings=obs_data_create();
    obs_data_set_string(settings,"server",server.UTF8String); obs_data_set_string(settings,"key",key.UTF8String);
    _core->service=obs_service_create("rtmp_custom","YouTube",settings,nullptr); obs_data_release(settings);
    _core->stream=obs_output_create("rtmp_output","YouTube Stream",nullptr,nullptr);
    if(!_core->streamVideo || !_core->streamAudio || !_core->service || !_core->stream) {
        releaseStream(_core); return [self fail:WSL(@"RTMPS 출력 또는 인코더 생성에 실패했습니다.")];
    }
    obs_encoder_set_video(_core->streamVideo,obs_get_video()); obs_encoder_set_audio(_core->streamAudio,obs_get_audio());
    obs_output_set_video_encoder(_core->stream,_core->streamVideo);
    obs_output_set_audio_encoder(_core->stream,_core->streamAudio,0); obs_output_set_service(_core->stream,_core->service);
    obs_output_set_reconnect_settings(_core->stream,3,2);
    _core->streamStopped.store(false); _core->streamCode.store(0);
    signal_handler_connect(obs_output_get_signal_handler(_core->stream),"stop",streamStopped,_core);
    if(!obs_output_start(_core->stream)) { releaseStream(_core); return [self fail:WSL(@"YouTube 송출을 시작하지 못했습니다.")]; }
    _lastError=@""; _status=WSL(@"YouTube에 영상 연결 중…"); return YES;
}
- (void)stopStream {
    if(!_core->stream || _core->streamStopping) return;
    _core->streamStopping=true; obs_output_stop(_core->stream);
}
- (void)poll {
    if(_core->stream && _core->streamStopped.exchange(false)) {
        const int code=_core->streamCode.load(); releaseStream(_core);
        if(code!=OBS_OUTPUT_SUCCESS) [self fail:[NSString stringWithFormat:WSL(@"YouTube 송출 연결 종료 (%d) · 방송 상태를 확인하세요."),code]];
    }
    const uint64_t now=os_gettime_ns();
    if(_core->skin && now-_core->lastBeautyLog>2000000000ULL) {
        _core->lastBeautyLog=now;
        NSDictionary<NSString *,NSNumber *> *d=self.beautyDiagnostics;
        fprintf(stderr,"[face-status] state=%d tracking=%d raw=%lld analysed=%lld detected=%lld gain=%d duration_ms=%d error=%d\n",
          d[@"state"].intValue,d[@"tracking"].intValue,d[@"raw_frames"].longLongValue,
          d[@"analysed"].longLongValue,d[@"detected"].longLongValue,d[@"gain"].intValue,
          d[@"elapsed_ms"].intValue,d[@"error_code"].intValue);
    }
    if (_core->record && _core->stopComplete.exchange(false)) {
        const int code = _core->stopCode.load();
        NSString *detail = stringFromUTF8(obs_output_get_last_error(_core->record));
        releaseRecording(_core);
        if (code == OBS_OUTPUT_SUCCESS) { _status = WSL(@"녹화 저장 완료"); _lastError = @""; }
        else [self fail:[NSString stringWithFormat:WSL(@"녹화 종료 오류 (%d): %@"), code, detail]];
    }
}
#include "GraphEngine.inc"
- (void)shutdown {
    if (!_core || !_core->initialized) return;
    if(_core->stream) {
        signal_handler_disconnect(obs_output_get_signal_handler(_core->stream),"stop",streamStopped,_core);
        if(obs_output_active(_core->stream)) obs_output_force_stop(_core->stream);
        releaseStream(_core);
    }
    [self clearGraphPreview];
    [self clearProjectorGraph];
    obs_set_output_source(0,nullptr);
    for(uint32_t channel=2;channel<MAX_CHANNELS;channel++) obs_set_output_source(channel,nullptr);
    if(_core->graph.transition) { obs_transition_clear(_core->graph.transition); obs_source_release(_core->graph.transition); _core->graph.transition=nullptr; }
    if(_core->graph.program) { obs_scene_release(_core->graph.program); _core->graph.program=nullptr; }
    _core->graph.mainMic.reset();
    _core->graph.probe.reset();
    _core->graph.inputs.clear();
    obs_set_output_source(2,nullptr); _core->activeMusic=nullptr;
    for(NSInteger i=0;i<5;i++) {
        if(_core->windowItems[i]) { obs_sceneitem_remove(_core->windowItems[i]); _core->windowItems[i]=nullptr; }
        if(_core->windowCapture[i]) { obs_source_release(_core->windowCapture[i]); _core->windowCapture[i]=nullptr; }
        if(_core->backgroundMusic[i]) { obs_source_release(_core->backgroundMusic[i]); _core->backgroundMusic[i]=nullptr; }
        _core->windowEnabled[i]=false;
    }
    if(_core->cardItem) { obs_sceneitem_remove(_core->cardItem); _core->cardItem=nullptr; }
    if(_core->stageCard) { obs_source_release(_core->stageCard); _core->stageCard=nullptr; }
    if (_core->record) {
        signal_handler_disconnect(obs_output_get_signal_handler(_core->record), "stop", recordStopped, _core);
        if (obs_output_active(_core->record)) obs_output_force_stop(_core->record);
        releaseRecording(_core);
    }
    if (_core->virtualCam) {
        if (obs_output_active(_core->virtualCam)) obs_output_stop(_core->virtualCam);
        obs_output_release(_core->virtualCam); _core->virtualCam = nullptr;
    }
    [self closeProjector];
    if (_core->programDisplay) {
        obs_display_remove_draw_callback(_core->programDisplay, drawProgram, nullptr);
        obs_display_destroy(_core->programDisplay); _core->programDisplay = nullptr;
    }
    if (_core->display) {
        obs_display_remove_draw_callback(_core->display, drawPreview, &_core->graph);
        obs_display_destroy(_core->display); _core->display = nullptr;
    }
    ws_release_owned_sources(&_core->scene, &_core->blank, &_core->cameraItem,
                             &_core->camera, &_core->skin, &_core->microphone);
    if(!_core->graph.cacheDirectory.empty()) { [NSFileManager.defaultManager removeItemAtPath:[NSString stringWithUTF8String:_core->graph.cacheDirectory.c_str()] error:nil]; _core->graph.cacheDirectory.clear(); }
    obs_shutdown(); _core->initialized = false;
}
@end
