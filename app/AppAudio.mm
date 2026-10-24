// SPDX-License-Identifier: GPL-2.0-or-later
// Church OBS가 띄운 WebKit 프로세스(유튜브 플레이어 소리는 보통 com.apple.WebKit.GPU)의 소리를
// Core Audio 프로세스 탭으로 받아 방송에 넣는다. macOS 14.2 이상.
//  - 설정 mute=true  : 탭하는 동안 현장 스피커에서는 끈다 (방송만)
//  - 설정 mute=false : 현장 스피커에서도 계속 들린다 (방송+현장)
// 앱 자신(영상 파일의 현장 모니터 소리)은 대상에서 빼서 되먹임을 막는다.
// 소리를 내는 WebKit 프로세스는 재생을 시작해야 나타나므로 2초마다 다시 찾는다.
#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#include <dlfcn.h>
#include <unistd.h>
#include <algorithm>
#include <vector>
#include <util/platform.h>
#include "AppAudio.h"

namespace {
typedef pid_t (*ws_responsible_fn)(pid_t);

struct AppAudio {
    obs_source_t *source=nullptr;
    bool mute=false;
    dispatch_queue_t queue=nullptr;
    dispatch_source_t timer=nullptr;
    AudioObjectID tap=0, aggregate=0;
    AudioDeviceIOProcID proc=nullptr;
    std::vector<AudioObjectID> targets;
    AudioStreamBasicDescription format={};
    bool warned=false;
};

AudioObjectPropertyAddress address(AudioObjectPropertySelector selector) {
    return {selector,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
}

/// 이 앱이 띄운(책임 프로세스가 이 앱인) 다른 프로세스 중 Core Audio에 소리를 내는 것
std::vector<AudioObjectID> findTargets() {
    std::vector<AudioObjectID> out;
    static ws_responsible_fn responsible=(ws_responsible_fn)dlsym(RTLD_DEFAULT,"responsibility_get_pid_responsible_for_pid");
    if(!responsible) return out;
    AudioObjectPropertyAddress list=address(kAudioHardwarePropertyProcessObjectList);
    UInt32 size=0;
    if(AudioObjectGetPropertyDataSize(kAudioObjectSystemObject,&list,0,nullptr,&size)!=noErr || !size) return out;
    std::vector<AudioObjectID> all(size/sizeof(AudioObjectID));
    if(AudioObjectGetPropertyData(kAudioObjectSystemObject,&list,0,nullptr,&size,all.data())!=noErr) return out;
    pid_t me=getpid();
    for(AudioObjectID object:all) {
        AudioObjectPropertyAddress pidAddress=address(kAudioProcessPropertyPID);
        pid_t pid=0; UInt32 pidSize=sizeof(pid);
        if(AudioObjectGetPropertyData(object,&pidAddress,0,nullptr,&pidSize,&pid)!=noErr || pid<=0 || pid==me) continue;
        if(responsible(pid)==me) out.push_back(object);
    }
    std::sort(out.begin(),out.end());
    return out;
}

NSString *defaultOutputUID() {
    AudioObjectPropertyAddress deviceAddress=address(kAudioHardwarePropertyDefaultOutputDevice);
    AudioObjectID device=0; UInt32 size=sizeof(device);
    if(AudioObjectGetPropertyData(kAudioObjectSystemObject,&deviceAddress,0,nullptr,&size,&device)!=noErr || !device) return nil;
    AudioObjectPropertyAddress uidAddress=address(kAudioDevicePropertyDeviceUID);
    CFStringRef uid=nullptr; size=sizeof(uid);
    if(AudioObjectGetPropertyData(device,&uidAddress,0,nullptr,&size,&uid)!=noErr || !uid) return nil;
    return CFBridgingRelease(uid);
}

void push(AppAudio *audio,const AudioBufferList *input) {
    if(!input || !input->mNumberBuffers || !audio->source) return;
    const AudioStreamBasicDescription &f=audio->format;
    if(!(f.mFormatFlags&kAudioFormatFlagIsFloat) || f.mSampleRate<=0) return;
    uint32_t channels=f.mChannelsPerFrame ? f.mChannelsPerFrame : 2;
    struct obs_source_audio out={};
    if(f.mFormatFlags&kAudioFormatFlagIsNonInterleaved) {
        for(UInt32 i=0;i<input->mNumberBuffers && i<MAX_AV_PLANES;i++) out.data[i]=(const uint8_t *)input->mBuffers[i].mData;
        out.frames=input->mBuffers[0].mDataByteSize/sizeof(float);
        out.format=AUDIO_FORMAT_FLOAT_PLANAR;
    } else {
        out.data[0]=(const uint8_t *)input->mBuffers[0].mData;
        out.frames=input->mBuffers[0].mDataByteSize/(sizeof(float)*channels);
        out.format=AUDIO_FORMAT_FLOAT;
    }
    if(!out.frames) return;
    out.speakers=channels==1 ? SPEAKERS_MONO : SPEAKERS_STEREO;
    out.samples_per_sec=(uint32_t)f.mSampleRate;
    out.timestamp=os_gettime_ns();
    obs_source_output_audio(audio->source,&out);
}

void stop(AppAudio *audio) {
    if(audio->aggregate) {
        if(audio->proc) { AudioDeviceStop(audio->aggregate,audio->proc); AudioDeviceDestroyIOProcID(audio->aggregate,audio->proc); audio->proc=nullptr; }
        AudioHardwareDestroyAggregateDevice(audio->aggregate); audio->aggregate=0;
    }
    if(audio->tap) {
        if(@available(macOS 14.2,*)) AudioHardwareDestroyProcessTap(audio->tap);
        audio->tap=0;
    }
    audio->targets.clear();
}

API_AVAILABLE(macos(14.2)) void start(AppAudio *audio,const std::vector<AudioObjectID> &targets) {
    NSMutableArray<NSNumber *> *processes=[NSMutableArray new];
    for(AudioObjectID object:targets) [processes addObject:@(object)];
    CATapDescription *description=[[CATapDescription alloc] initStereoMixdownOfProcesses:processes];
    description.name=@"Church OBS web audio";
    description.muteBehavior=audio->mute ? CATapMutedWhenTapped : CATapUnmuted;
    AudioObjectID tap=0;
    OSStatus status=AudioHardwareCreateProcessTap(description,&tap);
    if(status!=noErr || !tap) {
        if(!audio->warned) blog(LOG_WARNING,"[app-audio] process tap failed (%d). 시스템 설정 › 개인정보 보호 › 화면 및 시스템 오디오 녹음 권한을 확인하세요",(int)status);
        audio->warned=true; return;
    }
    AudioObjectPropertyAddress formatAddress=address(kAudioTapPropertyFormat);
    UInt32 size=sizeof(audio->format);
    AudioObjectGetPropertyData(tap,&formatAddress,0,nullptr,&size,&audio->format);
    NSMutableDictionary *settings=[@{
        @kAudioAggregateDeviceNameKey:@"Church OBS web audio",
        @kAudioAggregateDeviceUIDKey:NSUUID.UUID.UUIDString,
        @kAudioAggregateDeviceIsPrivateKey:@YES,
        @kAudioAggregateDeviceIsStackedKey:@NO,
        @kAudioAggregateDeviceTapAutoStartKey:@YES,
        @kAudioAggregateDeviceTapListKey:@[@{@kAudioSubTapUIDKey:description.UUID.UUIDString,@kAudioSubTapDriftCompensationKey:@YES}],
    } mutableCopy];
    if(NSString *output=defaultOutputUID()) {
        settings[@kAudioAggregateDeviceMainSubDeviceKey]=output;
        settings[@kAudioAggregateDeviceSubDeviceListKey]=@[@{@kAudioSubDeviceUIDKey:output}];
    }
    AudioObjectID aggregate=0;
    status=AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)settings,&aggregate);
    if(status!=noErr || !aggregate) { blog(LOG_WARNING,"[app-audio] aggregate device failed (%d)",(int)status); AudioHardwareDestroyProcessTap(tap); return; }
    audio->tap=tap; audio->aggregate=aggregate;
    status=AudioDeviceCreateIOProcIDWithBlock(&audio->proc,aggregate,audio->queue,^(const AudioTimeStamp *,const AudioBufferList *input,const AudioTimeStamp *,AudioBufferList *,const AudioTimeStamp *) {
        push(audio,input);
    });
    if(status!=noErr || !audio->proc) { blog(LOG_WARNING,"[app-audio] io proc failed (%d)",(int)status); stop(audio); return; }
    status=AudioDeviceStart(aggregate,audio->proc);
    if(status!=noErr) { blog(LOG_WARNING,"[app-audio] start failed (%d)",(int)status); stop(audio); return; }
    audio->targets=targets;
    blog(LOG_INFO,"[app-audio] tapping %zu web process(es), %.0f Hz, %u ch, room %s",targets.size(),audio->format.mSampleRate,(unsigned)audio->format.mChannelsPerFrame,audio->mute ? "muted" : "on");
}

void rescan(AppAudio *audio) {
    if(@available(macOS 14.2,*)) {
        std::vector<AudioObjectID> targets=findTargets();
        if(targets==audio->targets && (audio->tap || targets.empty())) return;
        stop(audio);
        if(!targets.empty()) start(audio,targets);
    } else if(!audio->warned) {
        blog(LOG_WARNING,"[app-audio] macOS 14.2 이상에서만 웹 플레이어 소리를 방송에 넣을 수 있습니다");
        audio->warned=true;
    }
}

const char *appAudioName(void *) { return "Church OBS web audio"; }

void *appAudioCreate(obs_data_t *settings,obs_source_t *source) {
    auto *audio=new AppAudio();
    audio->source=source;
    audio->mute=obs_data_get_bool(settings,"mute");
    audio->queue=dispatch_queue_create("org.mmcnyc.churchobs.app-audio",DISPATCH_QUEUE_SERIAL);
    audio->timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,audio->queue);
    dispatch_source_set_timer(audio->timer,dispatch_time(DISPATCH_TIME_NOW,0),2*NSEC_PER_SEC,200*NSEC_PER_MSEC);
    dispatch_source_set_event_handler(audio->timer,^{ rescan(audio); });
    dispatch_resume(audio->timer);
    return audio;
}

void appAudioDestroy(void *data) {
    auto *audio=static_cast<AppAudio *>(data);
    if(audio->timer) dispatch_source_cancel(audio->timer);
    dispatch_sync(audio->queue,^{ stop(audio); audio->source=nullptr; });
    delete audio;
}

void appAudioUpdate(void *data,obs_data_t *settings) {
    auto *audio=static_cast<AppAudio *>(data);
    bool mute=obs_data_get_bool(settings,"mute");
    dispatch_async(audio->queue,^{
        if(audio->mute==mute) return;
        audio->mute=mute;
        stop(audio);          // 현장 스피커 끄기·켜기는 탭을 다시 만들어야 바뀐다
        rescan(audio);
    });
}
}

void ws_register_app_audio(void) {
    struct obs_source_info info={};
    info.id="church_app_audio";
    info.type=OBS_SOURCE_TYPE_INPUT;
    info.output_flags=OBS_SOURCE_AUDIO|OBS_SOURCE_DO_NOT_DUPLICATE|OBS_SOURCE_CAP_DISABLED;
    info.get_name=appAudioName;
    info.create=appAudioCreate;
    info.destroy=appAudioDestroy;
    info.update=appAudioUpdate;
    obs_register_source(&info);
}
