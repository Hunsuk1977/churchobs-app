// SPDX-License-Identifier: GPL-2.0-or-later
// Included in WSEngine's implementation; graph previews never select output 0.
NS_ASSUME_NONNULL_BEGIN
// 위치·크기·회전: 회전이 있으면 중심 기준으로 놓고 돌린다 (OBS는 위치 기준점을 축으로 회전)
static inline void ws_graph_place(obs_sceneitem_t *layer,const WSGraphRect &rect,NSNumber *rotation) {
    double angle=[rotation isKindOfClass:NSNumber.class] ? rotation.doubleValue : 0;
    if(!std::isfinite(angle)) angle=0;
    struct vec2 position,bounds;
    vec2_set(&bounds,rect.width*CanvasWidth,rect.height*CanvasHeight);
    if(fabs(angle)>0.01) {
        obs_sceneitem_set_alignment(layer,OBS_ALIGN_CENTER);
        vec2_set(&position,(rect.x+rect.width/2)*CanvasWidth,(rect.y+rect.height/2)*CanvasHeight);
    } else {
        obs_sceneitem_set_alignment(layer,OBS_ALIGN_LEFT|OBS_ALIGN_TOP);
        vec2_set(&position,rect.x*CanvasWidth,rect.y*CanvasHeight);
    }
    obs_sceneitem_set_pos(layer,&position);
    obs_sceneitem_set_bounds_type(layer,OBS_BOUNDS_SCALE_INNER);
    obs_sceneitem_set_bounds_alignment(layer,0);
    obs_sceneitem_set_bounds(layer,&bounds);
    obs_sceneitem_set_rot(layer,(float)angle);
}
// 크롭: 각 변 0~0.9, 좌+우 / 위+아래 합계 0.9 이하 (원본 크기 대비 비율)
static inline void ws_graph_crop_values(NSDictionary *crop,double &l,double &t,double &r,double &b) {
    l=0; r=0; t=0; b=0;
    if([crop isKindOfClass:NSDictionary.class]) {
        l=std::clamp([crop[@"left"] doubleValue],0.0,0.9); r=std::clamp([crop[@"right"] doubleValue],0.0,0.9);
        t=std::clamp([crop[@"top"] doubleValue],0.0,0.9); b=std::clamp([crop[@"bottom"] doubleValue],0.0,0.9);
        if(!std::isfinite(l)) l=0; if(!std::isfinite(r)) r=0; if(!std::isfinite(t)) t=0; if(!std::isfinite(b)) b=0;
        if(l+r>0.9) { double s=0.9/(l+r); l*=s; r*=s; }
        if(t+b>0.9) { double s=0.9/(t+b); t*=s; b*=s; }
    }
}
static inline void ws_graph_apply_crop(obs_sceneitem_t *layer,obs_source_t *source,NSDictionary *crop) {
    double l,t,r,b; ws_graph_crop_values(crop,l,t,r,b);
    // 모양 레이어는 감싼 소스 안에서 소수 단위로 자른다 (드래그가 픽셀 단위로 튀지 않음)
    if(ws_shape_is(source)) {
        ws_shape_set_crop(source,l,t,r,b);
        struct obs_sceneitem_crop none={};
        obs_sceneitem_set_crop(layer,&none);
        return;
    }
    const double w=obs_source_get_width(source),h=obs_source_get_height(source);
    struct obs_sceneitem_crop clipping={};
    clipping.left=(int)(l*w); clipping.right=(int)(r*w); clipping.top=(int)(t*h); clipping.bottom=(int)(b*h);
    obs_sceneitem_set_crop(layer,&clipping);
}
- (float)microphoneLevel { return _core->graph.mainMic ? _core->graph.mainMic->peak.load() : 0; }
- (void)settleGraphMedia {
    for(auto &pair:_core->graph.inputs) {
        obs_source_t *source=pair.second->source;
        if(strcmp(obs_source_get_unversioned_id(source),"ffmpeg_source")) continue;
        if(!obs_source_showing(source) && !obs_source_active(source)) obs_source_media_stop(source);
        else if(obs_source_showing(source) && !obs_source_active(source)) {
            enum obs_media_state state=obs_source_media_get_state(source);
            if(state==OBS_MEDIA_STATE_NONE || state==OBS_MEDIA_STATE_STOPPED) obs_source_media_restart(source);
        }
    }
}
- (void)clearGraphPreview {
    obs_source_t *previous=nullptr;
    { std::lock_guard<std::mutex> guard(_core->graph.previewMutex); previous=_core->graph.preview; _core->graph.preview=nullptr; }
    if(previous) { obs_source_dec_showing(previous); obs_source_release(previous); }
    [self settleGraphMedia];
}
- (NSDictionary<NSString *,NSNumber *> *)graphAudioLevels {
    NSMutableDictionary *levels=[NSMutableDictionary new];
    for(auto &pair:_core->graph.inputs) levels[[NSString stringWithUTF8String:pair.first.c_str()]]=@(pair.second->peak.load());
    return levels;
}
// 편집 중 드래그: 미리보기 장면을 새로 만들지 않고 태그된 레이어의 위치·크기·크롭만 바꾼다.
- (BOOL)updateGraphPreviewLayout:(NSArray<NSDictionary<NSString *,id> *> *)items {
    if(!self.ready || self.streaming || self.recording || self.stopping || ![items isKindOfClass:NSArray.class]) return NO;
    obs_source_t *previewSource=nullptr;
    { std::lock_guard<std::mutex> guard(_core->graph.previewMutex); if(_core->graph.preview) previewSource=obs_source_get_ref(_core->graph.preview); }
    if(!previewSource) return NO;
    obs_scene_t *scene=obs_scene_from_source(previewSource);
    if(!scene) { obs_source_release(previewSource); return NO; }
    NSMutableDictionary<NSString *,NSDictionary *> *byID=[NSMutableDictionary new];
    for(NSDictionary *item in items) if([item isKindOfClass:NSDictionary.class] && [item[@"id"] isKindOfClass:NSString.class]) byID[item[@"id"]]=item;
    struct Context { __unsafe_unretained NSDictionary *byID; int updated; } context{byID,0};
    obs_scene_enum_items(scene,[](obs_scene_t *,obs_sceneitem_t *layer,void *opaque) -> bool {
        auto *ctx=static_cast<Context *>(opaque);
        obs_data_t *tag=obs_sceneitem_get_private_settings(layer);
        const char *identity=obs_data_get_string(tag,"wsItem");
        NSDictionary *item=(identity && *identity) ? ctx->byID[[NSString stringWithUTF8String:identity]] : nil;
        obs_data_release(tag);
        if(!item) return true;
        WSGraphRect rect;
        if(!ws_graph_rect([item[@"x"] doubleValue],[item[@"y"] doubleValue],[item[@"width"] doubleValue],[item[@"height"] doubleValue],&rect)) return true;
        obs_sceneitem_defer_update_begin(layer);
        ws_graph_place(layer,rect,item[@"rotation"]);
        ws_graph_apply_crop(layer,obs_sceneitem_get_source(layer),item[@"crop"]);
        obs_sceneitem_defer_update_end(layer);
        ctx->updated++;
        return true;
    },&context);
    obs_source_release(previewSource);
    return context.updated>0;
}
// 미리보기에도 송출에도 없는 소스를 닫는다 (장면이 들고 있는 참조는 그대로라 화면에는 영향 없음)
// 영상·음악 소리가 나가는 곳: broadcast 방송만 · both 방송+현장 스피커 · room 현장 스피커만
static obs_monitoring_type ws_monitor_type(id mode) {
    if(![mode isKindOfClass:NSString.class]) return OBS_MONITORING_TYPE_NONE;
    if([mode isEqualToString:@"both"]) return OBS_MONITORING_TYPE_MONITOR_AND_OUTPUT;
    if([mode isEqualToString:@"room"]) return OBS_MONITORING_TYPE_MONITOR_ONLY;
    return OBS_MONITORING_TYPE_NONE;
}

/// 진행 중에 소리 나가는 곳만 바꾼다 (영상을 다시 열지 않으므로 재생이 끊기지 않는다)
- (BOOL)setAudioMonitor:(NSString *)sourceID mode:(NSString *)mode {
    if(!sourceID.length) return NO;
    std::string key(sourceID.UTF8String);
    auto found=_core->graph.inputs.find(key);
    if(found==_core->graph.inputs.end() || !found->second->source) return YES;   // 아직 송출에 없음: 다음 전환 때 적용
    if(found->second->audio) {
        obs_source_set_muted(found->second->audio,found->second->webMuted || [mode isEqual:@"room"]);
        obs_data_t *update=obs_data_create(); obs_data_set_bool(update,"mute",[mode isEqual:@"broadcast"]);
        obs_source_update(found->second->audio,update); obs_data_release(update);
        blog(LOG_INFO,"[graph] web audio %s -> %s",key.c_str(),[mode UTF8String] ?: "");
        return YES;
    }
    obs_monitoring_type type=_core->graph.programKeys.count(key) ? ws_monitor_type(mode)
        : (_core->graph.projectorKeys.count(key) && ([mode isEqual:@"both"] || [mode isEqual:@"room"])) ? OBS_MONITORING_TYPE_MONITOR_ONLY
        : OBS_MONITORING_TYPE_NONE;
    obs_source_set_monitoring_type(found->second->source,type);
    blog(LOG_INFO,"[graph] audio monitor %s -> %s",key.c_str(),[mode UTF8String] ?: "");
    return YES;
}

/// 영상 파일 재생 상태: {소스 id: {state, time(ms), duration(ms), loop}}
- (NSDictionary<NSString *,NSDictionary *> *)graphMediaStates {
    NSMutableDictionary *out=[NSMutableDictionary new];
    for(auto &pair:_core->graph.inputs) {
        obs_source_t *source=pair.second->source;
        if(!source || strcmp(obs_source_get_unversioned_id(source),"ffmpeg_source")) continue;
        obs_data_t *settings=obs_source_get_settings(source);
        bool loop=obs_data_get_bool(settings,"looping");
        obs_data_release(settings);
        out[[NSString stringWithUTF8String:pair.first.c_str()]]=@{@"state":@((int)obs_source_media_get_state(source)),
            @"time":@(obs_source_media_get_time(source)),@"duration":@(obs_source_media_get_duration(source)),@"loop":@(loop)};
    }
    return out;
}
/// 영상 파일 조작: play · pause · restart · stop · loop(반복 켜기/끄기)
- (BOOL)mediaControl:(NSString *)sourceID action:(NSString *)action loop:(BOOL)loop {
    if(!sourceID.length) return NO;
    auto found=_core->graph.inputs.find(std::string(sourceID.UTF8String));
    if(found==_core->graph.inputs.end() || !found->second->source) return NO;
    obs_source_t *source=found->second->source;
    if(strcmp(obs_source_get_unversioned_id(source),"ffmpeg_source")) return NO;
    enum obs_media_state state=obs_source_media_get_state(source);
    if([action isEqualToString:@"play"]) {
        if(state==OBS_MEDIA_STATE_ENDED || state==OBS_MEDIA_STATE_STOPPED || state==OBS_MEDIA_STATE_NONE || state==OBS_MEDIA_STATE_ERROR) obs_source_media_restart(source);
        else obs_source_media_play_pause(source,false);
    } else if([action isEqualToString:@"pause"]) obs_source_media_play_pause(source,true);
    else if([action isEqualToString:@"restart"]) obs_source_media_restart(source);
    else if([action isEqualToString:@"stop"]) obs_source_media_stop(source);
    else if([action isEqualToString:@"loop"]) {
        obs_data_t *update=obs_data_create(); obs_data_set_bool(update,"looping",loop);
        obs_source_update(source,update); obs_data_release(update);
    } else return NO;
    blog(LOG_INFO,"[graph] media %s %s",sourceID.UTF8String,action.UTF8String);
    return YES;
}

/// 출력 창에 띄울 장면. sceneID가 비어 있으면 송출 화면을 그대로 띄운다
- (BOOL)applyProjectorGraph:(NSDictionary<NSString *,id> *)graph {
    if(![graph isKindOfClass:NSDictionary.class] || ![graph[@"sceneID"] isKindOfClass:NSString.class] || ![graph[@"sceneID"] length]) {
        [self clearProjectorGraph]; return YES;
    }
    NSMutableDictionary *studio=[graph mutableCopy]; studio[@"studio"]=@YES;   // 방송 중에도 허용
    _projectorBuild=YES;
    BOOL okay=[self applyGraph:studio preview:YES];
    _projectorBuild=NO;
    return okay;
}
- (void)clearProjectorGraph {
    obs_source_t *previous=nullptr;
    { std::lock_guard<std::mutex> guard(_core->graph.previewMutex); previous=_core->graph.projector; _core->graph.projector=nullptr; }
    if(previous) { obs_source_dec_active(previous); obs_source_dec_showing(previous); obs_source_release(previous); }
    for(const std::string &key:_core->graph.projectorKeys) {
        if(_core->graph.programKeys.count(key)) continue;
        auto found=_core->graph.inputs.find(key);
        if(found!=_core->graph.inputs.end() && found->second->source && found->second->source!=_core->microphone)
            obs_source_set_monitoring_type(found->second->source,OBS_MONITORING_TYPE_NONE);
    }
    _core->graph.projectorKeys.clear();
    [self pruneGraphInputs];
}
- (BOOL)projectorFollowsProgram { std::lock_guard<std::mutex> guard(_core->graph.previewMutex); return _core->graph.projector==nullptr; }

- (void)pruneGraphInputs {
    for(auto it=_core->graph.inputs.begin(); it!=_core->graph.inputs.end();) {
        if(_core->graph.previewKeys.count(it->first) || _core->graph.programKeys.count(it->first) || _core->graph.projectorKeys.count(it->first)) ++it;
        else it=_core->graph.inputs.erase(it);
    }
}
// 소스 추가 창: 고른 오디오 입력의 소리를 바로 보여 준다 (출력에는 보내지 않음)
- (void)setAudioProbe:(NSString *)device {
    if(!self.ready) return;
    std::string wanted=device.length ? std::string(device.UTF8String) : std::string();
    if(_core->graph.probe && _core->graph.probeDevice==wanted) return;
    _core->graph.probe.reset();
    _core->graph.probeDevice=wanted;
    if(wanted.empty()) return;
    obs_data_t *settings=obs_data_create();
    obs_data_set_string(settings,"device_id",wanted.c_str());
    obs_source_t *source=obs_source_create_private("coreaudio_input_capture","Audio check",settings);
    obs_data_release(settings);
    if(!source) return;
    auto probe=std::make_unique<WSGraphInput>(); probe->source=source;
    probe->meter=obs_volmeter_create(OBS_FADER_LOG);
    if(probe->meter) { obs_volmeter_add_callback(probe->meter,ws_graph_meter,probe.get()); obs_volmeter_attach_source(probe->meter,source); }
    _core->graph.probe=std::move(probe);
}
- (float)audioProbeLevel { return _core->graph.probe ? _core->graph.probe->peak.load() : 0; }
// 마지막 장면 적용에서 건너뛴 소스와 이유
- (NSDictionary<NSString *,NSString *> *)graphWarnings {
    NSMutableDictionary *out=[NSMutableDictionary new];
    for(auto &entry:_core->graph.warnings) out[[NSString stringWithUTF8String:entry.first.c_str()]]=[NSString stringWithUTF8String:entry.second.c_str()];
    return out;
}
// 소스 원본 픽셀 크기 (편집기가 상자를 실제 화면 비율에 맞추는 데 사용)
- (NSDictionary<NSString *,NSArray<NSNumber *> *> *)graphSourceSizes {
    NSMutableDictionary *sizes=[NSMutableDictionary new];
    for(auto &entry:_core->graph.inputs) {
        if(!entry.second || !entry.second->source) continue;
        uint32_t w=obs_source_get_width(entry.second->source),h=obs_source_get_height(entry.second->source);
        if(w && h) sizes[[NSString stringWithUTF8String:entry.first.c_str()]]=@[@(w),@(h)];
    }
    return sizes;
}
- (BOOL)applyGraph:(NSDictionary<NSString *,id> *)graph preview:(BOOL)preview {
    if(!self.ready) return [self fail:WSL(@"영상 엔진을 먼저 시작하세요.")];
    // 진행 화면의 "다음 장면" 미리보기는 송출과 분리되어 있으므로 방송 중에도 허용
    if(preview && ![graph[@"studio"] boolValue] && (self.streaming || self.recording || self.stopping)) return [self fail:WSL(@"방송·녹화 중에는 장면을 편집할 수 없습니다.")];
    _lastError=@"";
    NSArray *definitions=graph[@"sources"],*items=graph[@"items"];
    if(![definitions isKindOfClass:NSArray.class] || ![items isKindOfClass:NSArray.class] || items.count>64 || definitions.count>128) return [self fail:WSL(@"장면 데이터가 잘못되었습니다.")];
    NSMutableDictionary<NSString *,NSDictionary *> *sourceMap=[NSMutableDictionary new];
    for(NSDictionary *source in definitions) {
        if(![source isKindOfClass:NSDictionary.class] || ![source[@"id"] isKindOfClass:NSString.class] || ![source[@"kind"] isKindOfClass:NSString.class]) return [self fail:WSL(@"소스 정보가 잘못되었습니다.")];
        sourceMap[source[@"id"]]=source;
    }
    // Validate the complete transaction before touching program output or audio.
    for(NSDictionary *item in items) {
        if(![item isKindOfClass:NSDictionary.class] || ![item[@"source"] isKindOfClass:NSString.class] || !sourceMap[item[@"source"]]) return [self fail:WSL(@"장면이 참조하는 소스가 없습니다.")];
        NSDictionary *source=sourceMap[item[@"source"]]; NSString *kind=source[@"kind"];
        if([kind isEqualToString:@"browser"]) return [self fail:WSL(@"내장 브라우저는 아직 연결되지 않았습니다. 브라우저 창을 윈도우 캡처로 추가하세요.")];
        for(NSString *key in @[@"x",@"y",@"width",@"height",@"volume"]) if(![item[key] isKindOfClass:NSNumber.class] || !std::isfinite([item[key] doubleValue])) return [self fail:WSL(@"레이어 좌표나 음량이 잘못되었습니다.")];
        if([source[@"captureAudio"] boolValue]) return [self fail:WSL(@"앱 소리 캡처는 아직 연결되지 않았습니다. 별도 마이크 입력을 사용하세요.")];
    }
    obs_scene_t *scene=obs_scene_create_private("SwiftUI scene revision");
    if(!scene) return [self fail:WSL(@"편집 장면을 만들지 못했습니다.")];
    _core->graph.warnings.clear();
    std::set<std::string> usedKeys;
    NSMutableArray<NSDictionary *> *audioItems=[NSMutableArray new];
    bool okay=true;
    bool webAudioAdded=false;
    for(NSDictionary *item in items) {
        if(![item[@"visible"] boolValue]) continue;
        NSDictionary *definition=sourceMap[item[@"source"]]; NSString *kind=definition[@"kind"];
        NSString *path=definition[@"path"] ?: @"";
        if([kind isEqualToString:@"audio"] && !_core->microphone && !((NSString *)(definition[@"device"] ?: @"")).length) continue;
        if([kind isEqualToString:@"media"] && !path.length) continue; // unassigned template music
        NSString *identity=definition[@"id"];
        // 카메라별 보정·색 톤은 소스를 다시 열지 않고 필터만 바꾼다 → 서명에서 뺀다
        NSMutableDictionary *signed_=[definition mutableCopy]; [signed_ removeObjectForKey:@"look"]; [signed_ removeObjectForKey:@"monitor"]; [signed_ removeObjectForKey:@"loop"];
        NSData *encoded=[NSJSONSerialization dataWithJSONObject:signed_ options:NSJSONWritingSortedKeys error:nil];
        std::string signature(static_cast<const char *>(encoded.bytes),encoded.length);
        if([kind isEqualToString:@"camera"]) signature+=std::to_string(reinterpret_cast<uintptr_t>(_core->camera));
        if([kind isEqualToString:@"audio"]) signature+=std::to_string(reinterpret_cast<uintptr_t>(_core->microphone));
        std::string key(identity.UTF8String);
        auto found=_core->graph.inputs.find(key);
        if(found==_core->graph.inputs.end() || found->second->signature!=signature) {
            obs_source_t *source=nullptr;
            obs_data_t *settings=obs_data_create();
            if([kind isEqualToString:@"camera"]) {
                NSString *device=definition[@"device"] ?: @"";
                NSString *active=[NSUserDefaults.standardUserDefaults stringForKey:@"WSLastCamera"] ?: @"";
                if(_core->camera && (!device.length || [device isEqualToString:active])) source=obs_source_get_ref(_core->camera);
                else if(device.length) {
                    // 두 번째·세 번째 카메라 (보정 필터는 아래에서 붙인다)
                    obs_data_t *camera=obs_get_source_defaults("macos-avcapture");
                    obs_data_set_string(camera,"device",device.UTF8String);
                    obs_data_set_bool(camera,"use_preset",true);
                    obs_data_set_string(camera,"preset",AVCaptureSessionPresetHigh.UTF8String);
                    obs_data_set_bool(camera,"enable_audio",false);
                    obs_data_set_bool(camera,"buffering",false);
                    source=obs_source_create_private("macos-avcapture",identity.UTF8String,camera);
                    obs_data_release(camera);
                    if(!source) [self fail:WSL(@"이 카메라를 열지 못했습니다. 연결 상태를 확인하세요.")];
                }
                else [self fail:WSL(@"카메라는 준비 화면에서 먼저 연결하세요.")];
            } else if([kind isEqualToString:@"audio"]) {
                NSString *device=definition[@"device"] ?: @"";
                NSString *active=[NSUserDefaults.standardUserDefaults stringForKey:@"WSLastMicrophone"] ?: @"";
                if(_core->microphone && (!device.length || [device isEqualToString:active])) source=obs_source_get_ref(_core->microphone);
                else if(device.length) {
                    // 추가 오디오 입력 (믹서·두 번째 마이크 등)
                    obs_data_t *audio=obs_data_create();
                    obs_data_set_string(audio,"device_id",device.UTF8String);
                    source=obs_source_create_private("coreaudio_input_capture",identity.UTF8String,audio);
                    obs_data_release(audio);
                    if(!source) [self fail:WSL(@"이 오디오 입력을 열지 못했습니다.")];
                }
                else [self fail:WSL(@"마이크는 준비 화면에서 먼저 연결하세요.")];
            } else if([kind isEqualToString:@"window"]) {
                if(!CGPreflightScreenCaptureAccess()) [self fail:WSL(@"화면 녹화 권한을 허용한 뒤 자료 창을 다시 선택하세요.")];
                else {
                    NSArray *windows=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly|kCGWindowListExcludeDesktopElements,kCGNullWindowID));
                    uint32_t windowID=0; NSUInteger matches=0; uint32_t requested=[definition[@"windowID"] unsignedIntValue];
                    for(NSDictionary *window in windows) {
                        if([window[(NSString *)kCGWindowOwnerPID] intValue]==NSProcessInfo.processInfo.processIdentifier) continue;
                        NSRunningApplication *owner=[NSRunningApplication runningApplicationWithProcessIdentifier:[window[(NSString *)kCGWindowOwnerPID] intValue]];
                        NSString *title=definition[@"title"] ?: @"",*bundle=definition[@"bundle"] ?: @"";
                        if(title.length && [window[(NSString *)kCGWindowName] isEqualToString:title] && (!bundle.length || [owner.bundleIdentifier isEqualToString:bundle]) && (!requested || requested==[window[(NSString *)kCGWindowNumber] unsignedIntValue])) { windowID=[window[(NSString *)kCGWindowNumber] unsignedIntValue]; matches++; }
                    }
                    // 프레젠테이션 앱(PowerPoint·Keynote·ProPresenter): 파일을 바꾸면 창 제목도 바뀐다 →
                    // 정확히 맞는 창이 없으면 그 앱에서 가장 큰 창(보통 슬라이드 쇼 창)을 쓴다
                    NSString *wantBundle=definition[@"bundle"] ?: @"";
                    if([definition[@"anyWindow"] boolValue] && wantBundle.length && matches!=1) {
                        double best=0; windowID=0; matches=0;
                        for(NSDictionary *window in windows) {
                            if([window[(NSString *)kCGWindowLayer] intValue]!=0) continue;
                            NSRunningApplication *owner=[NSRunningApplication runningApplicationWithProcessIdentifier:[window[(NSString *)kCGWindowOwnerPID] intValue]];
                            if(![owner.bundleIdentifier isEqualToString:wantBundle]) continue;
                            CGRect frame=CGRectZero;
                            CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)window[(NSString *)kCGWindowBounds],&frame);
                            double area=frame.size.width*frame.size.height;
                            uint32_t number=[window[(NSString *)kCGWindowNumber] unsignedIntValue];
                            if(requested && number==requested) { windowID=number; matches=1; break; }   // 방금 고른 그 창
                            if(area>best && frame.size.width>=320 && frame.size.height>=180) { best=area; windowID=number; matches=1; }
                        }
                    }
                    if(windowID && matches==1) {
                        obs_data_set_int(settings,"type",1); obs_data_set_int(settings,"window",windowID);
                        obs_data_set_bool(settings,"show_cursor",false); obs_data_set_bool(settings,"hide_obs",false);
                        source=obs_source_create_private("screen_capture",identity.UTF8String,settings);
                        if(source) obs_source_set_muted(source,true);
                    } else if([definition[@"anyWindow"] boolValue] && wantBundle.length) [self fail:WSL(@"프레젠테이션 앱의 슬라이드 창을 찾지 못했습니다. 슬라이드 쇼를 창으로 시작했는지 확인하세요.")];
                    else if(!((NSString *)(definition[@"title"] ?: @"")).length) [self fail:WSL(@"아직 자료 창을 고르지 않았습니다. 속성에서 ‘자료 창 선택’을 누르세요.")];
                    else [self fail:matches>1 ? WSL(@"같은 이름의 창이 여러 개입니다. 자료 창을 다시 선택하세요.") : WSL(@"선택한 자료 창을 찾지 못했습니다. 창을 열고 소스를 다시 선택하세요.")];
                }
            } else if([kind isEqualToString:@"screen"]) {
                // 화면(모니터) 통째로: 프로젝터·두 번째 모니터에 띄운 PowerPoint·ProPresenter 출력
                if(!CGPreflightScreenCaptureAccess()) [self fail:WSL(@"화면 녹화 권한을 허용한 뒤 다시 시도하세요.")];
                else {
                    NSString *display=definition[@"display"] ?: @"";
                    obs_data_set_int(settings,"type",0);
                    if(display.length) obs_data_set_string(settings,"display_uuid",display.UTF8String);
                    obs_data_set_bool(settings,"show_cursor",false); obs_data_set_bool(settings,"hide_obs",true);
                    source=obs_source_create_private("screen_capture",identity.UTF8String,settings);
                    if(source) obs_source_set_muted(source,true);
                }
            } else if([kind isEqualToString:@"youtube"]) {
                // 앱 안 유튜브 플레이어 창(Swift가 만든다)을 창 캡처로 가져온다. 소리는 아래 church_app_audio 가 받는다
                uint32_t windowID=[definition[@"windowID"] unsignedIntValue];
                if(!CGPreflightScreenCaptureAccess()) [self fail:WSL(@"화면 녹화 권한을 허용한 뒤 다시 시도하세요.")];
                else if(!windowID) [self fail:WSL(@"유튜브 주소를 확인하세요. 영상 ID를 찾지 못했습니다.")];
                else {
                    obs_data_set_int(settings,"type",1); obs_data_set_int(settings,"window",windowID);
                    obs_data_set_bool(settings,"show_cursor",false); obs_data_set_bool(settings,"hide_obs",false);
                    obs_data_set_bool(settings,"show_hidden_windows",true);
                    source=obs_source_create_private("screen_capture",identity.UTF8String,settings);
                    if(source) obs_source_set_muted(source,true);
                }
            } else if([kind isEqualToString:@"media"]) {
                if(![NSFileManager.defaultManager fileExistsAtPath:path]) [self fail:WSL(@"미디어 파일을 찾지 못했습니다. 파일을 다시 선택하세요.")];
                else {
                    NSString *extension=path.pathExtension.lowercaseString;
                    BOOL image=[@[@"png",@"jpg",@"jpeg",@"heic",@"webp"] containsObject:extension];
                    obs_data_set_string(settings,image ? "file" : "local_file",path.fileSystemRepresentation);
                    obs_data_set_bool(settings,"is_local_file",true); obs_data_set_bool(settings,"looping",[definition[@"loop"] boolValue]);
                    obs_data_set_bool(settings,"restart_on_activate",true); obs_data_set_bool(settings,"close_when_inactive",true);
                    source=obs_source_create_private(image ? "image_source" : "ffmpeg_source",identity.UTF8String,settings);
                }
            } else if([kind isEqualToString:@"text"]) {
                NSBitmapImageRep *bitmap=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nullptr pixelsWide:1280 pixelsHigh:720 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bitmapFormat:0 bytesPerRow:1280*4 bitsPerPixel:32];
                if(bitmap) {
                    memset(bitmap.bitmapData,0,1280*720*4);
                    [NSGraphicsContext saveGraphicsState]; NSGraphicsContext.currentContext=[NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
                    if([definition[@"opaque"] boolValue]) { [[NSColor colorWithWhite:0.04 alpha:1] setFill]; NSRectFill(NSMakeRect(0,0,1280,720)); }
                    // corner=YES: 오른쪽 아래 작은 글씨 (무료 요금제 워터마크)
                    BOOL corner=[definition[@"corner"] boolValue];
                    double fontSize=[definition[@"fontSize"] doubleValue];
                    if(!std::isfinite(fontSize) || fontSize<8 || fontSize>200) fontSize=64;
                    NSMutableParagraphStyle *paragraph=[NSMutableParagraphStyle new]; paragraph.alignment=corner ? NSTextAlignmentRight : NSTextAlignmentCenter;
                    NSString *text=definition[@"text"] ?: @"";
                    NSShadow *shadow=[NSShadow new]; shadow.shadowColor=[NSColor colorWithWhite:0 alpha:0.6]; shadow.shadowBlurRadius=4; shadow.shadowOffset=NSMakeSize(0,-1);
                    NSRect area=corner ? NSMakeRect(40,26,1200,fontSize*1.6) : NSMakeRect(50,60,1180,600);
                    [text drawInRect:area withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:fontSize weight:NSFontWeightSemibold],NSForegroundColorAttributeName:[NSColor colorWithWhite:1 alpha:corner ? 0.8 : 1],NSParagraphStyleAttributeName:paragraph,NSShadowAttributeName:shadow}];
                    [NSGraphicsContext restoreGraphicsState];
                    if(_core->graph.cacheDirectory.empty()) _core->graph.cacheDirectory=[[NSTemporaryDirectory() stringByAppendingPathComponent:[@"churchobs-scene-" stringByAppendingString:NSUUID.UUID.UUIDString]] UTF8String];
                    NSString *folder=[NSString stringWithUTF8String:_core->graph.cacheDirectory.c_str()];
                    [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
                    NSString *file=[folder stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingString:@".png"]];
                    NSData *png=[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                    if([png writeToFile:file atomically:YES]) { obs_data_set_string(settings,"file",file.fileSystemRepresentation); source=obs_source_create_private("image_source",identity.UTF8String,settings); }
                }
            } else if([kind isEqualToString:@"captions"]) {
                // WORDaLIVE 번역 자막 띠. 글자는 Swift가 릴레이에서 받아 ws_captions_set_lines 로 넣는다
                obs_data_set_bool(settings,"show_source",[definition[@"showSource"] boolValue]);
                obs_data_set_bool(settings,"background",definition[@"background"] ? [definition[@"background"] boolValue] : true);
                obs_data_set_int(settings,"font_size",definition[@"fontSize"] ? [definition[@"fontSize"] intValue] : 56);
                obs_data_set_int(settings,"lines",definition[@"lines"] ? [definition[@"lines"] intValue] : 1);
                source=obs_source_create_private("church_captions",identity.UTF8String,settings);
            } else if([kind isEqualToString:@"slides"]) {
                // WORDaLIVE 스튜디오의 현재 슬라이드. 그림은 Swift가 내려받아 ws_slides_set 으로 넣는다
                source=obs_source_create_private("church_slides",identity.UTF8String,settings);
            } else [self fail:WSL(@"지원하지 않는 소스 종류입니다.")];
            obs_data_release(settings);
            if(!source) {
                // OBS처럼 이 소스만 건너뛰고 나머지 레이어는 그린다. 이유는 편집 화면에 표시된다.
                NSString *reason=_lastError.length ? _lastError : WSL(@"소스를 만들지 못했습니다.");
                _core->graph.warnings[key]=reason.UTF8String;
                _lastError=@"";
                continue;
            }
            auto input=std::make_unique<WSGraphInput>(); input->source=source; input->signature=signature;
            // 자료 배경 투명: 검정·흰색·초록 배경을 빼서 카메라 위에 글자만 올린다
            if(([kind isEqualToString:@"window"] || [kind isEqualToString:@"screen"]) && [definition[@"key"] isKindOfClass:NSString.class]) {
                NSString *keyName=definition[@"key"]; long color=-1;
                if([keyName isEqualToString:@"black"]) color=0x000000; else if([keyName isEqualToString:@"white"]) color=0xFFFFFF; else if([keyName isEqualToString:@"green"]) color=0x00FF00;
                if(color>=0) {
                    obs_data_t *keySettings=obs_data_create();
                    obs_data_set_string(keySettings,"key_color_type","custom");
                    obs_data_set_int(keySettings,"key_color",color);
                    obs_data_set_int(keySettings,"similarity",[keyName isEqualToString:@"green"] ? 400 : 120);   // 검정·흰색은 글자 테두리를 지키려고 좁게
                    obs_data_set_int(keySettings,"smoothness",80);
                    input->key=obs_source_create_private("color_key_filter","Transparent background",keySettings);
                    obs_data_release(keySettings);
                    if(input->key) obs_source_filter_add(source,input->key);
                }
            }
            // 두 번째·세 번째 카메라에도 자연 보정 필터를 붙인다
            if([kind isEqualToString:@"camera"] && source!=_core->camera && strcmp(obs_source_get_unversioned_id(source),"macos-avcapture")==0) {
                input->skin=obs_source_create_private("churchobs_skin_soften","Natural Skin (extra camera)",nullptr);
                if(input->skin) obs_source_filter_add(source,input->skin);
                input->look=obs_source_create_private("church_camera_look","Camera look (extra camera)",nullptr);
                if(input->look) obs_source_filter_add(source,input->look);
            }
            if([kind isEqualToString:@"youtube"]) {
                obs_data_t *audioSettings=obs_data_create();
                obs_data_set_bool(audioSettings,"mute",[definition[@"monitor"] isEqual:@"broadcast"]);
                input->audio=obs_source_create_private("church_app_audio",[identity stringByAppendingString:@" audio"].UTF8String,audioSettings);
                obs_data_release(audioSettings);
            }
            obs_source_t *audible=input->audio ? input->audio : source;
            if(obs_source_get_output_flags(audible)&OBS_SOURCE_AUDIO) {
                input->meter=obs_volmeter_create(OBS_FADER_LOG);
                if(input->meter) {
                    obs_volmeter_add_callback(input->meter,ws_graph_meter,input.get());
                    obs_volmeter_attach_source(input->meter,audible);
                }
            }
            _core->graph.inputs[key]=std::move(input);
            found=_core->graph.inputs.find(key);
            if(found->second->skin || found->second->look) { [self applyBeautySettings]; [self applyLookSettings]; }
        }
        obs_source_t *source=found->second->source;
        usedKeys.insert(key);
        // 반복 재생은 영상을 다시 열지 않고 바꾼다 (재생 위치 유지)
        if([kind isEqualToString:@"media"] && source && !strcmp(obs_source_get_unversioned_id(source),"ffmpeg_source")) {
            bool loop=[definition[@"loop"] boolValue];
            obs_data_t *current=obs_source_get_settings(source);
            if(obs_data_get_bool(current,"looping")!=loop) {
                obs_data_t *update=obs_data_create(); obs_data_set_bool(update,"looping",loop);
                obs_source_update(source,update); obs_data_release(update);
            }
            obs_data_release(current);
        }
        if(found->second->skin || found->second->look) {
            WSGraphInput *input=found->second.get();
            NSDictionary *look=[definition[@"look"] isKindOfClass:NSDictionary.class] ? definition[@"look"] : nil;
            auto number=[&](NSString *name,double fallback) { id v=look[name]; double d=[v isKindOfClass:NSNumber.class] ? [v doubleValue] : fallback; return std::isfinite(d) ? std::clamp(d,0.0,1.0) : fallback; };
            bool own=look!=nil;
            int beauty=look ? (int)std::clamp<NSInteger>([look[@"beauty"] integerValue],0,2) : 0;
            int tone=look ? (int)std::clamp<NSInteger>([look[@"tone"] integerValue],0,4) : 0;
            double amount=look ? number(@"amount",0.6) : 0.6, blur=look ? number(@"blur",0) : 0;
            if(own!=input->ownLook || beauty!=input->ownBeauty || tone!=input->ownTone || amount!=input->ownToneAmount || blur!=input->ownBlur) {
                input->ownLook=own; input->ownBeauty=beauty; input->ownTone=tone; input->ownToneAmount=amount; input->ownBlur=blur;
                [self applyBeautySettings]; [self applyLookSettings];
            }
        }
        BOOL route=[kind isEqualToString:@"audio"] || [definition[@"audioOnly"] boolValue];
        // 유튜브 소리: 앱 안 웹 소리 전체를 받으므로 한 장면에 하나만 넣는다 (겹치면 소리가 두 번 나간다)
        if(found->second->audio && !webAudioAdded) {
            webAudioAdded=true;
            obs_scene_add(scene,found->second->audio);
            [audioItems addObject:@{@"id":identity,@"volume":item[@"volume"],@"muted":item[@"muted"] ?: @NO,@"route":@NO,@"web":@YES,
                                    @"monitor":([definition[@"monitor"] isKindOfClass:NSString.class] ? definition[@"monitor"] : @"both")}];
        }
        if((obs_source_get_output_flags(source)&OBS_SOURCE_AUDIO) && ![kind isEqualToString:@"window"] && ![kind isEqualToString:@"camera"] && ![kind isEqualToString:@"youtube"]) [audioItems addObject:@{@"id":identity,@"volume":item[@"volume"],@"muted":item[@"muted"] ?: @NO,@"route":@(route),@"monitor":([definition[@"monitor"] isKindOfClass:NSString.class] ? definition[@"monitor"] : @"broadcast")}];
        if(route) continue;
        // 둥근 모서리·원·테두리: 이 레이어만 모양 소스로 감싼다 (같은 소스를 다른 장면에서 사각으로 써도 영향 없음)
        NSString *shapeName=[item[@"shape"] isKindOfClass:NSString.class] ? item[@"shape"] : @"rect";
        int shapeKind=[shapeName isEqualToString:@"rounded"] ? 1 : [shapeName isEqualToString:@"circle"] ? 2 : 0;
        BOOL border=[item[@"border"] boolValue];
        obs_source_t *wrapper=(shapeKind || border) ? ws_shape_create(source,identity.UTF8String) : nullptr;
        if(wrapper) ws_shape_set_style(wrapper,shapeKind,border);
        obs_sceneitem_t *layer=obs_scene_add(scene,wrapper ? wrapper : source);
        if(wrapper) obs_source_release(wrapper);   // 장면이 참조를 가진다
        if(!layer) { okay=false; [self fail:WSL(@"레이어 추가에 실패했습니다.")]; break; }
        WSGraphRect rect;
        if(!ws_graph_rect([item[@"x"] doubleValue],[item[@"y"] doubleValue],[item[@"width"] doubleValue],[item[@"height"] doubleValue],&rect)) { okay=false; break; }
        ws_graph_place(layer,rect,item[@"rotation"]);
        ws_graph_apply_crop(layer,obs_sceneitem_get_source(layer),item[@"crop"]);
        if([item[@"id"] isKindOfClass:NSString.class]) {
            // 편집 중 빠른 위치 갱신(updateGraphPreviewLayout)이 이 레이어를 찾을 수 있도록 표시
            obs_data_t *tag=obs_sceneitem_get_private_settings(layer);
            obs_data_set_string(tag,"wsItem",[item[@"id"] UTF8String]);
            obs_data_release(tag);
        }
    }
    if(!okay) { obs_scene_release(scene); return NO; }
    obs_source_t *sceneSource=obs_scene_get_source(scene);
    if(preview && _projectorBuild) {
        // 출력 창 전용 장면: 송출·미리보기와 따로 그린다. 소리는 방송에 섞지 않고, "현장"으로 고른 영상만 현장 스피커로
        obs_source_inc_showing(sceneSource); obs_source_inc_active(sceneSource); obs_source_t *previous=nullptr;
        { std::lock_guard<std::mutex> guard(_core->graph.previewMutex); previous=_core->graph.projector; _core->graph.projector=obs_source_get_ref(sceneSource); }
        if(previous) { obs_source_dec_active(previous); obs_source_dec_showing(previous); obs_source_release(previous); }
        for(NSDictionary *audio in audioItems) {
            std::string id([audio[@"id"] UTF8String]);
            if(_core->graph.programKeys.count(id)) continue;   // 송출에도 있으면 송출 설정을 따른다
            auto &input=_core->graph.inputs.at(id);
            if([audio[@"web"] boolValue] || input->source==_core->microphone) continue;
            NSString *mode=audio[@"monitor"];
            obs_monitoring_type type=([mode isEqual:@"both"] || [mode isEqual:@"room"]) ? OBS_MONITORING_TYPE_MONITOR_ONLY : OBS_MONITORING_TYPE_NONE;
            if(obs_source_get_monitoring_type(input->source)!=type) obs_source_set_monitoring_type(input->source,type);
        }
        _core->graph.projectorKeys=std::move(usedKeys);
        [self pruneGraphInputs];
        [self settleGraphMedia];
        obs_scene_release(scene); _lastError=@"";
        blog(LOG_INFO,"[graph] projector scene: %s",[graph[@"name"] ?: @"" UTF8String]);
        return YES;
    }
    if(preview) {
        obs_source_inc_showing(sceneSource); obs_source_t *previous=nullptr;
        { std::lock_guard<std::mutex> guard(_core->graph.previewMutex); previous=_core->graph.preview; _core->graph.preview=obs_source_get_ref(sceneSource); }
        if(previous) { obs_source_dec_showing(previous); obs_source_release(previous); }
        _core->graph.previewKeys=std::move(usedKeys);
        [self pruneGraphInputs];
        [self settleGraphMedia];
        obs_scene_release(scene); _lastError=@""; return YES;
    }
    NSString *style=graph[@"transition"] ?: @"cut";
    NSString *type=[style isEqualToString:@"slide"] ? @"slide_transition" : @"fade_transition";
    obs_source_t *transition=_core->graph.transition;
    if(!transition || _core->graph.transitionKind!=type.UTF8String) {
        obs_source_t *replacement=obs_source_create_private(type.UTF8String,"Church scene transition",nullptr);
        if(!replacement) { obs_scene_release(scene); return [self fail:WSL(@"장면 전환 모듈을 만들지 못했습니다.")]; }
        obs_transition_set_size(replacement,CanvasWidth,CanvasHeight);
        if(_core->graph.program) obs_transition_set(replacement,obs_scene_get_source(_core->graph.program));
        if(transition) obs_source_release(transition);
        _core->graph.transition=transition=replacement; _core->graph.transitionKind=type.UTF8String;
    }
    double duration=[graph[@"duration"] doubleValue];
    if(!std::isfinite(duration)) duration=0.5;
    bool started=true;
    if([style isEqualToString:@"cut"] || !_core->graph.program) obs_transition_set(transition,sceneSource);
    else started=obs_transition_start(transition,OBS_TRANSITION_MODE_AUTO,(uint32_t)(std::clamp(duration,0.1,3.0)*1000),sceneSource);
    if(!started) { obs_scene_release(scene); return [self fail:WSL(@"장면 전환을 시작하지 못했습니다.")]; }
    obs_set_output_source(0,transition);
    // 미리보기는 지우지 않는다: 스튜디오 모드에서 다음 장면을 계속 보여 준다
    std::vector<obs_source_t *> routes(MAX_CHANNELS,nullptr);
    _core->activeMusic=nullptr;
    uint32_t channel=2;
    _core->graph.sceneMicMuted=true;
    for(NSDictionary *audio in audioItems) {
        auto &input=_core->graph.inputs.at(std::string([audio[@"id"] UTF8String]));
        if([audio[@"web"] boolValue] && input->audio) {
            // 유튜브: 방송만 = 현장 스피커 끔(탭 mute) · 현장만 = 방송 믹스에서 뺌 · 방송+현장 = 둘 다
            NSString *mode=audio[@"monitor"];
            obs_source_set_volume(input->audio,std::clamp([audio[@"volume"] floatValue],0.0f,1.0f));
            obs_source_set_muted(input->audio,[audio[@"muted"] boolValue] || [mode isEqual:@"room"]);
            obs_data_t *update=obs_data_create(); obs_data_set_bool(update,"mute",[mode isEqual:@"broadcast"]);
            obs_source_update(input->audio,update); obs_data_release(update);
            input->webMuted=[audio[@"muted"] boolValue];
            continue;
        }
        obs_source_set_volume(input->source,std::clamp([audio[@"volume"] floatValue],0.0f,1.0f));
        if(input->source==_core->microphone) _core->graph.sceneMicMuted=[audio[@"muted"] boolValue];
        else obs_source_set_muted(input->source,[audio[@"muted"] boolValue]);
        if([audio[@"route"] boolValue] && input->source!=_core->microphone && channel<MAX_CHANNELS) routes[channel++]=input->source;
        if(input->source!=_core->microphone) {
            obs_monitoring_type type=ws_monitor_type(audio[@"monitor"]);
            if(obs_source_get_monitoring_type(input->source)!=type) obs_source_set_monitoring_type(input->source,type);
        }
    }
    // 송출 장면 밖의 소스는 현장 스피커로 소리를 내지 않는다 (미리보기에 올린 영상 포함)
    for(auto &entry:_core->graph.inputs) {
        if(usedKeys.count(entry.first) || _core->graph.projectorKeys.count(entry.first) || !entry.second->source || entry.second->source==_core->microphone) continue;
        if(obs_source_get_monitoring_type(entry.second->source)!=OBS_MONITORING_TYPE_NONE) obs_source_set_monitoring_type(entry.second->source,OBS_MONITORING_TYPE_NONE);
    }
    if(_core->microphone) obs_source_set_muted(_core->microphone,_core->muted || _core->graph.sceneMicMuted);
    for(uint32_t i=2;i<MAX_CHANNELS;i++) {
        obs_source_t *current=obs_get_output_source(i);
        if(current!=routes[i]) obs_set_output_source(i,routes[i]);
        if(current) obs_source_release(current);
    }
    if(_core->graph.program) obs_scene_release(_core->graph.program);
    _core->graph.program=scene;
    _core->graph.programKeys=std::move(usedKeys);
    [self pruneGraphInputs];
    blog(LOG_INFO,"[graph] program applied: %s, transition=%s, skipped=%zu",
         [graph[@"name"] ?: @"" UTF8String],[style UTF8String],_core->graph.warnings.size());
    _lastError=@""; return YES;
}

- (BOOL)verifySwiftGraph {
    if(!_core->camera) return [self fail:WSL(@"SwiftUI 합성 검사 카메라가 없습니다.")];
    [self setBeautyPreset:0]; [self setBeautyComparison:NO];
    NSDictionary *camera=@{@"id":@"graph-camera",@"kind":@"camera",@"device":@""};
    NSDictionary *full=@{@"source":@"graph-camera",@"x":@0,@"y":@0,@"width":@1,@"height":@1,@"visible":@YES,@"shape":@"rect",@"border":@NO,@"volume":@1,@"muted":@NO};
    NSMutableDictionary *graph=[@{@"sources":@[camera],@"items":@[full],@"transition":@"cut",@"duration":@0} mutableCopy];
    if(![self applyGraph:graph preview:NO]) return NO;
    PixelProbe probe; probe.wholeFrame=true; ProbeConnection connection(probe);
    if(!connection.connected || !waitForProbeFrame(probe,5)) return [self fail:WSL(@"SwiftUI 합성 검사 영상 수신 실패")];
    pumpProbe(0.7); auto baseline=snapshot(probe);
    NSMutableDictionary *small=[full mutableCopy]; small[@"x"]=@0.5; small[@"width"]=@0.5;
    graph[@"items"]=@[small];
    if(![self applyGraph:graph preview:YES]) return NO;
    pumpProbe(0.7); auto unchanged=snapshot(probe);
    auto mean=[](const std::vector<uint8_t>&a,const std::vector<uint8_t>&b) {
        if(a.empty() || a.size()!=b.size()) return -1.0;
        double sum=0; for(size_t i=0;i<a.size();i++) sum+=std::abs(int(a[i])-int(b[i])); return sum/a.size();
    };
    double isolated=mean(baseline,unchanged);
    if(![self applyGraph:graph preview:NO]) return NO;
    pumpProbe(0.7); auto moved=snapshot(probe); double difference=mean(baseline,moved);
    NSMutableDictionary *invalid=[small mutableCopy]; invalid[@"x"]=@(NAN); graph[@"items"]=@[invalid];
    BOOL rejected=![self applyGraph:graph preview:NO];
    pumpProbe(0.2); double preserved=mean(moved,snapshot(probe));
    graph[@"items"]=@[full];
    BOOL restored=[self applyGraph:graph preview:NO];
    fprintf(stderr,"SwiftUI graph GPU: preview_program_delta=%.4f moved_delta=%.4f invalid_rejected=%d preserved_delta=%.4f\n",isolated,difference,rejected,preserved);
    if(isolated<0 || isolated>0.03 || difference<0.05 || !rejected || preserved<0 || preserved>0.03 || !restored) return [self fail:WSL(@"SwiftUI 장면 배치·오프에어 미리보기 격리 검사 실패")];
    return YES;
}

NS_ASSUME_NONNULL_END
