// SPDX-License-Identifier: GPL-2.0-or-later
#import <AppKit/AppKit.h>
#import "Localize.h"
#import "Engine.h"
#import "SmokeTest.h"
#include "FaceTracker.h"
#include <cstdio>
static void pumpFor(NSTimeInterval duration) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:duration];
    do { [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]]; } while (until.timeIntervalSinceNow > 0);
}
int ws_run_smoke_test(NSString *path) {
    // Run from the compiled app bundle. Uses a generated source and silent AAC,
    // so this test never asks for camera or microphone permissions.
    NSApplication *app = NSApplication.sharedApplication;
    [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [app finishLaunching];
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,640,360) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    [window orderFront:nil];
    if(!ws_face_tracker_self_test()) {
        fprintf(stderr,"FAIL Vision/conversion no-face integration check\n"); return 6;
    }
    fprintf(stderr,"PASS Vision/conversion integration (blank NV12/BGRA; face quality not tested)\n");
    WSEngine *engine = [WSEngine new];
    if (![engine startWithPreview:window.contentView] || ![engine selectTestPattern]) {
        fprintf(stderr,"FAIL engine/source: %s\n",engine.lastError.UTF8String); [engine shutdown]; return 1;
    }
    [engine setBeautyPreset:1];
    pumpFor(0.5);
    if (![engine verifyBeautyOnTestPattern]) {
        fprintf(stderr,"FAIL beauty pixel check: %s\n",engine.lastError.UTF8String); [engine shutdown]; return 5;
    }
    if(![engine selectFaceTestInput] || ![engine verifyFaceTrackingPipeline]) {
        fprintf(stderr,"FAIL real face pipeline: %s\n",engine.lastError.UTF8String); [engine shutdown]; return 7;
    }
    fprintf(stderr,"PASS real face detection and GPU pixel path (reference photograph)\n");
    if(![engine verifyStreamingComponents] || ![engine verifyWorshipScenes]) {
        fprintf(stderr,"FAIL worship/stream modules: %s\n",engine.lastError.UTF8String); [engine shutdown]; return 8;
    }
    if(![engine verifySwiftGraph]) { fprintf(stderr,"FAIL SwiftUI graph integration: %s\n",engine.lastError.UTF8String); [engine shutdown]; return 9; }
    if (![engine startRecordingAtPath:path]) {
        fprintf(stderr,"FAIL recording start: %s\n",engine.lastError.UTF8String); [engine shutdown]; return 2;
    }
    pumpFor(5.0); [engine poll];
    if (!engine.recording) { fprintf(stderr,"FAIL recording ended early: %s\n",engine.lastError.UTF8String); [engine shutdown]; return 3; }
    [engine stopRecording];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:15.0];
    do { pumpFor(0.1); [engine poll]; } while ((engine.recording || engine.stopping) && deadline.timeIntervalSinceNow > 0);
    const BOOL stopped = !engine.recording && !engine.stopping;
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    const BOOL nonempty = [attributes[NSFileSize] unsignedLongLongValue] > 1024;
    const BOOL passed = stopped && nonempty && !engine.lastError.length;
    fprintf(stderr,"Recording stage: stopped=%d nonempty=%d path=%s error=%s\n",stopped,nonempty,path.fileSystemRepresentation,engine.lastError.UTF8String);
    [engine shutdown]; [window orderOut:nil];
    fprintf(stderr,"Engine shutdown returned normally.\n");
    return passed ? 0 : 4;
}
