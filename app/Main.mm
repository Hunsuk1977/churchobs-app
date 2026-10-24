// SPDX-License-Identifier: GPL-2.0-or-later
#import <AppKit/AppKit.h>
#include "Captions.h"
#include "Slides.h"
#include <string>
#include <vector>
#import "Localize.h"
#import <AVFoundation/AVFoundation.h>
#import "Engine.h"
#import "PreviewView.h"
#import "SmokeTest.h"
#import "YouTubeBridge.h"
#import "StudioControls.h"
#import "StudioBridge.h"
#import <CoreGraphics/CoreGraphics.h>
#include "StudioTiming.h"
#include "StudioLayout.h"
#include <cstring>
#include <cmath>
#include <algorithm>
#include <cstdio>

static NSTextField *label(NSString *text, CGFloat size, NSFontWeight weight) {
    NSTextField *v = [NSTextField wrappingLabelWithString:text];
    v.font = [NSFont systemFontOfSize:MAX(size,12) weight:weight];
    v.textColor = NSColor.labelColor;
    return v;
}
static NSStackView *column(NSArray<NSView *> *views) {
    NSStackView *stack = [NSStackView stackViewWithViews:views];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 14;
    stack.distribution=NSStackViewDistributionFill;
    return stack;
}

@interface WSFlippedView : NSView
@end
@implementation WSFlippedView
- (BOOL)isFlipped { return YES; }
@end

@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate, NSToolbarDelegate, WSStudioNativeBridge>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) WSEngine *engine;
@property(nonatomic, strong) WSPreviewView *preview;
@property(nonatomic, strong) WSPreviewView *programPreview;
@property(nonatomic, strong) NSTextField *statusLabel;
@property(nonatomic, strong) NSTextField *errorLabel;
@property(nonatomic, strong) NSTextField *recordLabel;
@property(nonatomic, strong) NSPopUpButton *cameraMenu;
@property(nonatomic, strong) NSPopUpButton *microphoneMenu;
@property(nonatomic, strong) NSButton *startButton;
@property(nonatomic, strong) NSButton *cameraButton;
@property(nonatomic, strong) NSButton *microphoneButton;
@property(nonatomic, strong) NSButton *recordButton;
@property(nonatomic, strong) NSButton *muteButton;
@property(nonatomic, strong) NSSegmentedControl *sceneSelector;
@property(nonatomic, strong) NSSegmentedControl *beautySelector;
@property(nonatomic, strong) NSButton *compareButton;
@property(nonatomic, strong) NSButton *faceGuideButton;
@property(nonatomic, strong) NSTextField *beautyStatusLabel;
@property(nonatomic, strong) NSSlider *strengthSlider;
@property(nonatomic, strong) NSSlider *skinSlider;
@property(nonatomic, strong) NSSlider *shapeSlider;
@property(nonatomic, strong) NSSlider *eyeSlider;
@property(nonatomic, strong) NSSlider *browSlider;
@property(nonatomic, strong) NSStackView *detailControls;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, strong) WSYouTubeBridge *youtube;
@property(nonatomic, strong) NSButton *youtubeButton;
@property(nonatomic, strong) NSButton *createBroadcastButton;
@property(nonatomic, strong) NSButton *broadcastButton;
@property(nonatomic, strong) NSButton *broadcastStatusButton;
@property(nonatomic, strong) NSPopUpButton *broadcastMenu;
@property(nonatomic, strong) NSTextField *youtubeLabel;
@property(nonatomic, strong) NSMutableArray<NSString *> *sceneTexts;
@property(nonatomic, copy) NSString *materialPath;
@property(nonatomic, copy) NSString *activeBroadcastID;
@property(nonatomic, copy) NSString *broadcastState;
@property(nonatomic) BOOL youtubeConnected;
@property(nonatomic) BOOL broadcastAction;
/// 방송 시작·종료 진행 단계: 0 없음, 1 방송 만들기, 2 영상 보내기 시작, 3 YouTube 수신 확인, 5 종료 중
@property(nonatomic) NSInteger broadcastStep;
@property(nonatomic) BOOL isLive;

@property(nonatomic) BOOL performanceMode;
@property(nonatomic) NSInteger appliedScene;
@property(nonatomic,strong) NSTextField *modeTitle;
@property(nonatomic,strong) NSTextField *modeHint;
@property(nonatomic,strong) NSTextField *sceneNameLabel;
@property(nonatomic,strong) NSTextField *outputBadge;
@property(nonatomic,strong) NSTextField *reviewLabel;
@property(nonatomic,strong) NSTextField *performanceStatus;
@property(nonatomic,strong) NSTextField *broadcastFeedback;
@property(nonatomic,strong) NSTextField *captureLabel;
@property(nonatomic,strong) NSTextField *countdownLabel;
@property(nonatomic,strong) NSTextField *countdownMinutes;
@property(nonatomic,strong) NSButton *modeButton;
@property(nonatomic,strong) NSButton *nextStepButton;
@property(nonatomic,strong) NSButton *reviewCheck;
@property(nonatomic,strong) NSButton *countdownAuto;
@property(nonatomic,strong) NSButton *countdownButton;
@property(nonatomic,strong) NSButton *countdownResetButton;
@property(nonatomic,strong) NSSegmentedControl *preparationSteps;
@property(nonatomic,strong) NSStackView *connectionPage;
@property(nonatomic,strong) NSStackView *scenePage;
@property(nonatomic,strong) NSStackView *reviewPage;
@property(nonatomic,strong) NSStackView *settingsStack;
@property(nonatomic,strong) NSStackView *countdownRow;
@property(nonatomic,strong) NSScrollView *settingsScroll;
@property(nonatomic,strong) WSStudioWorkspace *workspace;
@property(nonatomic,strong) NSView *swiftStudioHost;
@property(nonatomic,strong) NSStackView *sceneSidebar;
@property(nonatomic,strong) NSArray<WSSceneButton *> *sidebarButtons;
@property(nonatomic,strong) NSTextField *connectionSummary;
@property(nonatomic,strong) NSTextField *deviceStatus;
@property(nonatomic,strong) NSTextField *cameraCheck;
@property(nonatomic,strong) NSTextField *microphoneCheck;
@property(nonatomic,strong) NSTextField *channelCheck;
@property(nonatomic,strong) NSTextField *layerSummary;
@property(nonatomic,strong) NSButton *nextSceneButton;
@property(nonatomic,strong) NSPopUpButton *sourceMenu;
@property(nonatomic,strong) NSPopUpButton *layoutMenu;
@property(nonatomic,strong) NSMutableArray<NSNumber *> *sourceModes;
@property(nonatomic,strong) NSMutableArray<NSNumber *> *sceneLayouts;
@property(nonatomic,strong) NSMutableArray<NSString *> *captureNames;
@property(nonatomic) NSTimeInterval countdownDeadline;
@property(nonatomic) NSInteger countdownRemaining;
@property(nonatomic) BOOL countdownVisible;
@property(nonatomic,strong) NSArray<WSSceneButton *> *sceneButtons;
@property(nonatomic,strong) NSStackView *sceneDock;
@property(nonatomic,strong) NSStackView *countdownSettings;
@property(nonatomic,strong) NSStackView *beautySettings;
@property(nonatomic,strong) NSStackView *captureOptions;
@property(nonatomic,strong) NSStackView *materialRow;
@property(nonatomic,strong) NSStackView *captureTools;
@property(nonatomic,strong) NSStackView *mediaTools;
@property(nonatomic,strong) NSTextField *mediaLabel;
@property(nonatomic,strong) NSMutableArray<NSString *> *sceneImages;
@property(nonatomic,strong) NSMutableArray<NSString *> *sceneVideos;
@property(nonatomic,strong) NSMutableArray<NSString *> *sceneMusic;

@end

@implementation AppDelegate
#include "StudioUI.inc"
#include "StudioSources.inc"
#include "StudioUITest.inc"
#include "SwiftBridge.inc"
- (NSButton *)button:(NSString *)title action:(SEL)action {
    WSActionButton *b=[[WSActionButton alloc] initWithFrame:NSZeroRect];
    b.title=title; b.target=self; b.action=action;
    b.bordered=YES; b.bezelStyle=NSBezelStyleRounded;
    [b setButtonType:NSButtonTypeMomentaryPushIn];
    b.font=[NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    b.controlSize=NSControlSizeLarge;
    return b;
}
- (NSSlider *)beautySlider:(double)value {
    NSSlider *slider=[NSSlider sliderWithValue:value minValue:0 maxValue:100 target:self action:@selector(adjustBeauty:)];
    slider.continuous=YES;
    [slider.widthAnchor constraintEqualToConstant:230].active=YES;
    return slider;
}
- (void)saveBeautySettings {
    [NSUserDefaults.standardUserDefaults setObject:@{
      @"strength":@(self.strengthSlider.doubleValue),@"skin":@(self.skinSlider.doubleValue),
      @"shape":@(self.shapeSlider.doubleValue),@"eyes":@(self.eyeSlider.doubleValue),
      @"brows":@(self.browSlider.doubleValue),@"preset":@(self.beautySelector.selectedSegment)
    } forKey:@"WSBeautySettingsV1"];
}
- (void)restoreBeautySettings {
    id stored=[NSUserDefaults.standardUserDefaults objectForKey:@"WSBeautySettingsV1"];
    if(![stored isKindOfClass:NSDictionary.class]) return;
    NSDictionary *values=(NSDictionary *)stored;
    NSArray<NSString *> *keys=@[@"strength",@"skin",@"shape",@"eyes",@"brows"];
    NSArray<NSSlider *> *sliders=@[self.strengthSlider,self.skinSlider,self.shapeSlider,self.eyeSlider,self.browSlider];
    for(NSUInteger i=0;i<keys.count;i++) {
        id value=values[keys[i]];
        if([value isKindOfClass:NSNumber.class] && std::isfinite([value doubleValue])) sliders[i].doubleValue=std::clamp([value doubleValue],0.0,100.0);
    }
    id preset=values[@"preset"];
    self.beautySelector.selectedSegment=[preset isKindOfClass:NSNumber.class] ? std::clamp<NSInteger>([preset integerValue],-1,2) : -1;
    [self.engine setBeautyStrength:self.strengthSlider.doubleValue/100 skin:self.skinSlider.doubleValue/100
      shape:self.shapeSlider.doubleValue/100 eyes:self.eyeSlider.doubleValue/100 brows:self.browSlider.doubleValue/100];
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    self.engine = [WSEngine new]; self.youtube=[WSYouTubeBridge new];
    self.activeBroadcastID=[NSUserDefaults.standardUserDefaults stringForKey:@"WSActiveBroadcastID"] ?: @""; self.broadcastState=@""; self.materialPath=@"";
    self.sceneTexts=[@[WSL(@"잠시 후 예배를 시작합니다"),WSL(@"찬양 가사를 입력하세요"),WSL(@"오늘의 말씀"),WSL(@"성경 본문이나 안내 문구를 입력하세요"),WSL(@"한 주간도 주님과 동행하세요")] mutableCopy];
    NSArray *savedScenes=[NSUserDefaults.standardUserDefaults arrayForKey:@"WSSceneTextsV1"];
    if(savedScenes.count==5) for(NSUInteger i=0;i<5;i++) if([savedScenes[i] isKindOfClass:NSString.class]) self.sceneTexts[i]=savedScenes[i];
    self.materialPath=[NSUserDefaults.standardUserDefaults stringForKey:@"WSMaterialPath"] ?: @"";
    self.sceneImages=[@[@"",@"",@"",@"",@""] mutableCopy];
    NSArray *images=[NSUserDefaults.standardUserDefaults arrayForKey:@"WSSceneImagesV1"];
    if(images.count==5) for(NSUInteger i=0;i<5;i++) if([images[i] isKindOfClass:NSString.class] && [NSFileManager.defaultManager fileExistsAtPath:images[i]]) self.sceneImages[i]=images[i];
    if(!self.sceneImages[3].length && [NSFileManager.defaultManager fileExistsAtPath:self.materialPath]) self.sceneImages[3]=self.materialPath;
    // Follow the Mac appearance, contrast and transparency preferences.
    self.sceneVideos=[@[@"",@"",@"",@"",@""] mutableCopy];
    self.sceneMusic=[@[@"",@"",@"",@"",@""] mutableCopy];
    for(NSString *key in @[@"WSSceneVideosV1",@"WSSceneMusicV1"]) {
        NSArray *stored=[NSUserDefaults.standardUserDefaults arrayForKey:key];
        NSMutableArray *target=[key isEqualToString:@"WSSceneVideosV1"] ? self.sceneVideos : self.sceneMusic;
        if(stored.count==5) for(NSNumber *number in @[@0,@4]) {
            NSUInteger index=number.unsignedIntegerValue;
            if([stored[index] isKindOfClass:NSString.class] && [NSFileManager.defaultManager fileExistsAtPath:stored[index]]) target[index]=stored[index];
        }
    }
    self.sourceModes=[@[@0,@0,@0,@0,@0] mutableCopy];
    self.sceneLayouts=[@[@0,@0,@0,@0,@0] mutableCopy];
    self.captureNames=[@[@"",@"",@"",@"",@""] mutableCopy];
    NSMenu *menu = [NSMenu new];
    NSMenuItem *appItem = [NSMenuItem new];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"Church OBS"];
    [appMenu addItemWithTitle:WSL(@"Church OBS 정보") action:@selector(showAbout:) keyEquivalent:@""];
    [appMenu addItemWithTitle:WSL(@"YouTube 다시 연결") action:@selector(connectYouTube:) keyEquivalent:@""];
    [appMenu addItemWithTitle:WSL(@"YouTube Studio 열기") action:@selector(openYouTubeStudio:) keyEquivalent:@""];
    [appMenu addItemWithTitle:WSL(@"YouTube 연결 해제") action:@selector(disconnectYouTube:) keyEquivalent:@""];
    [appMenu addItemWithTitle:WSL(@"YouTube 설정 파일(JSON) 바꾸기…") action:@selector(replaceYouTubeConfiguration:) keyEquivalent:@""];
    [appMenu addItemWithTitle:WSL(@"최근 녹화 파일 보기") action:@selector(showRecording:) keyEquivalent:@""];
    [appMenu addItemWithTitle:WSL(@"방송 상태 확인") action:@selector(checkBroadcast:) keyEquivalent:@""];
    [appMenu addItem:NSMenuItem.separatorItem];
    [appMenu addItemWithTitle:WSL(@"종료") action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu; [menu addItem:appItem];
    NSMenuItem *editItem = [NSMenuItem new];
    NSMenu *edit = [[NSMenu alloc] initWithTitle:WSL(@"편집")];
    [edit addItemWithTitle:WSL(@"복사") action:@selector(copy:) keyEquivalent:@"c"];
    [edit addItemWithTitle:WSL(@"붙여넣기") action:@selector(paste:) keyEquivalent:@"v"];
    [edit addItemWithTitle:WSL(@"전체 선택") action:@selector(selectAll:) keyEquivalent:@"a"];
    editItem.submenu = edit; [menu addItem:editItem]; NSApp.mainMenu = menu;

    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1220, 820) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    self.window.delegate=self;
    [self.window center];
    [self buildStudioUI];
    [self.window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.25 target:self selector:@selector(updateStatus:) userInfo:nil repeats:YES];
    [self restoreBeautySettings];
    [self updateStatus:nil];
    if(self.activeBroadcastID.length) {
        // A recovered broadcast must expose its stop/status controls immediately.
        self.performanceMode=YES;
        self.settingsScroll.hidden=YES; self.workspace.performance=YES; [self.workspace refreshLayout];
        self.preparationSteps.selectedSegment=2; self.modeTitle.stringValue=WSL(@"예배 진행");
        self.modeButton.title=WSL(@"장면 편집"); [self updateStudioStatus];
        [self checkBroadcast:nil];
    }
    if(![NSProcessInfo.processInfo.arguments containsObject:@"--ui-smoke-test"]) {
        Class<WSSwiftStudioFactory> factory=(Class<WSSwiftStudioFactory>)NSClassFromString(@"WSSwiftStudioHost");
        if(factory) {
            [self.preview removeFromSuperview];
            self.swiftStudioHost=[factory makeViewWithBridge:self previewView:self.preview];
            self.window.toolbar=nil;
            self.window.contentView=self.swiftStudioHost;
            self.window.minSize=NSMakeSize(1240,820);
            [self.window setContentSize:NSMakeSize(1360,900)];
        } else {
            NSAlert *alert=[NSAlert new]; alert.messageText=WSL(@"새 화면 모듈을 불러오지 못했습니다.");
            alert.informativeText=WSL(@"업데이트 빌드 기록 logs/build.log와 UI 검사 logs/ui-smoke.log를 확인하세요.");
            [alert runModal]; [NSApp terminate:nil]; return;
        }
    }
    dispatch_async(dispatch_get_main_queue(), ^{ [self startEngine:nil]; });
}
- (void)showAbout:(id)sender {
    (void)sender; NSAlert *alert = [NSAlert new];
    NSString *version=[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"";
    NSString *build=[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"";
    alert.messageText = [NSString stringWithFormat:@"Church OBS %@ (%@)",version,build];
    alert.informativeText = WSL(@"교회를 위한 간편 YouTube 방송 소프트웨어\n\nOBS Studio 엔진(libobs 32.2.2) 기반 · GPL-2.0-or-later 자유 소프트웨어입니다.\n소스 코드와 오픈소스 고지: github.com/Hunsuk1977/churchobs-app\nOBS Project와는 관계없는 독립 프로젝트입니다.");
    [alert addButtonWithTitle:WSL(@"확인")];
    [alert addButtonWithTitle:WSL(@"소스 코드 보기")];
    [alert addButtonWithTitle:WSL(@"개인정보 처리방침")];
    NSModalResponse response=[alert runModal];
    if(response==NSAlertSecondButtonReturn) [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"https://github.com/Hunsuk1977/churchobs-app"]];
    else if(response==NSAlertThirdButtonReturn) [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"https://churchobs.app/privacy"]];
}
- (void)reportFailure {
    self.errorLabel.stringValue = self.engine.lastError;
}
- (void)startEngine:(id)sender {
    (void)sender;
    if(self.engine.ready) return;
    self.startButton.enabled = NO;
    if (![self.engine startWithPreview:self.preview]) [self reportFailure];
    [self refreshDevices:nil];
    if(self.engine.ready) {
        // Local file paths are restored; window IDs must be chosen afresh.
        for(NSNumber *number in @[@0,@4]) {
            NSInteger scene=number.integerValue;
            if(self.sceneVideos[scene].length) [self.engine setLoopMediaAtPath:self.sceneVideos[scene] scene:scene];
            if(self.sceneMusic[scene].length) [self.engine setBackgroundMusicAtPath:self.sceneMusic[scene] scene:scene];
        }
        [self applyScene];
    }
    [self updateStatus:nil];
}
- (void)fillMenu:(NSPopUpButton *)menu devices:(NSArray<NSDictionary<NSString *,NSString *> *> *)devices {
    NSString *previous = menu.selectedItem.representedObject;
    if(!previous.length) previous=[NSUserDefaults.standardUserDefaults stringForKey:(menu==self.cameraMenu ? @"WSLastCamera" : @"WSLastMicrophone")];
    [menu removeAllItems];
    for (NSDictionary *item in devices) { [menu addItemWithTitle:item[@"name"]]; menu.lastItem.representedObject = item[@"id"]; }
    for (NSMenuItem *item in menu.itemArray) if ([item.representedObject isEqual:previous]) [menu selectItem:item];
}
- (void)refreshDevices:(id)sender {
    (void)sender;
    [self fillMenu:self.cameraMenu devices:self.engine.cameras];
    [self fillMenu:self.microphoneMenu devices:self.engine.microphones];
}
- (void)withPermission:(AVMediaType)type action:(void (^)(void))action {
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:type];
    if (status == AVAuthorizationStatusAuthorized) { action(); return; }
    if (status == AVAuthorizationStatusNotDetermined) {
        [AVCaptureDevice requestAccessForMediaType:type completionHandler:^(BOOL allowed) {
            dispatch_async(dispatch_get_main_queue(), ^{ if (allowed) action(); else self.errorLabel.stringValue = WSL(@"접근 권한이 거절되었습니다. 시스템 설정 → 개인정보 보호 및 보안에서 권한을 확인하세요."); });
        }];
    } else self.errorLabel.stringValue = WSL(@"시스템 설정 → 개인정보 보호 및 보안에서 카메라 또는 마이크 접근을 허용하세요.");
}
- (void)connectCamera:(id)sender {
    if(![self canEditPreparation]) return;
    [self invalidateReview];
    (void)sender;
    [self withPermission:AVMediaTypeVideo action:^{
        if(![self canEditPreparation]) return;
        [self invalidateReview];
        [self refreshDevices:nil]; NSString *id = self.cameraMenu.selectedItem.representedObject;
        if (!id.length) { self.errorLabel.stringValue = WSL(@"사용 가능한 카메라가 없습니다."); return; }
        if (![self.engine selectCamera:id]) [self reportFailure];
        else { self.errorLabel.stringValue = @""; [NSUserDefaults.standardUserDefaults setObject:id forKey:@"WSLastCamera"]; }
        [self updateStatus:nil];
    }];
}
- (void)connectMicrophone:(id)sender {
    if(![self canEditPreparation]) return;
    [self invalidateReview];
    (void)sender;
    [self withPermission:AVMediaTypeAudio action:^{
        if(![self canEditPreparation]) return;
        [self invalidateReview];
        [self refreshDevices:nil]; NSString *id = self.microphoneMenu.selectedItem.representedObject;
        if (!id.length) { self.errorLabel.stringValue = WSL(@"사용 가능한 마이크가 없습니다."); return; }
        if (![self.engine selectMicrophone:id]) [self reportFailure];
        else { self.errorLabel.stringValue = @""; [NSUserDefaults.standardUserDefaults setObject:id forKey:@"WSLastMicrophone"]; }
        [self updateStatus:nil];
    }];
}
- (void)applyScene {
    NSInteger scene=self.sceneSelector.selectedSegment;
    if(scene<0 || scene>4 || !self.engine.ready) return;
    NSString *text=self.sceneTexts[scene];
    if(scene==0 && self.countdownVisible) text=[NSString stringWithFormat:@"%@\n%@",text,[self countdownText]];
    if(![self.engine setWorshipScene:scene text:text imagePath:self.sceneImages[scene]]) {
        self.sceneSelector.selectedSegment=self.appliedScene;
        [self reportFailure]; [self updateStudioStatus]; return;
    }
    self.appliedScene=scene; self.errorLabel.stringValue=@"";
    [self.sourceMenu selectItemAtIndex:self.sourceModes[scene].integerValue];
    [self.layoutMenu selectItemAtIndex:self.sceneLayouts[scene].integerValue];
    self.captureLabel.stringValue=self.captureNames[scene].length ? self.captureNames[scene] : WSL(@"이 장면에 사용할 PPT·자료 창을 선택하세요.");
    [self updateStudioStatus];
}
- (void)changeScene:(NSSegmentedControl *)sender {
    (void)sender;
    if(self.sceneSelector.selectedSegment!=0 && self.countdownDeadline>0) [self pauseCountdown];
    [self applyScene];
}
- (void)editScene:(id)sender {
    if(![self canEditPreparation]) return;
    [self invalidateReview];
    (void)sender; NSInteger index=self.sceneSelector.selectedSegment;
    if(index<0 || index>4) return;
    NSAlert *alert=[NSAlert new]; alert.messageText=WSL(@"현재 장면 문구·가사");
    alert.informativeText=WSL(@"준비 화면에서 선택한 장면에 적용됩니다. 자료 이미지가 있으면 문구 대신 이미지가 표시됩니다.");
    NSScrollView *scroll=[[NSScrollView alloc] initWithFrame:NSMakeRect(0,0,440,170)]; scroll.hasVerticalScroller=YES;
    NSTextView *editor=[[NSTextView alloc] initWithFrame:scroll.bounds]; editor.richText=NO; editor.string=self.sceneTexts[index]; scroll.documentView=editor;
    alert.accessoryView=scroll; [alert addButtonWithTitle:WSL(@"적용")]; [alert addButtonWithTitle:WSL(@"취소")];
    if([alert runModal]!=NSAlertFirstButtonReturn) return;
    self.sceneTexts[index]=[editor.string substringToIndex:MIN(editor.string.length,(NSUInteger)4000)];
    [NSUserDefaults.standardUserDefaults setObject:self.sceneTexts forKey:@"WSSceneTextsV1"];
    [self applyScene];
}
- (void)clearMaterial:(id)sender {
    (void)sender; if(![self canEditPreparation]) return;
    NSInteger scene=self.sceneSelector.selectedSegment;
    if(scene!=0 && scene!=3 && scene!=4) return;
    self.sceneImages[scene]=@"";
    if(scene==0 || scene==4) { [self.engine setLoopMediaAtPath:@"" scene:scene]; self.sceneVideos[scene]=@""; }
    [NSUserDefaults.standardUserDefaults setObject:self.sceneImages forKey:@"WSSceneImagesV1"];
    [NSUserDefaults.standardUserDefaults setObject:self.sceneVideos forKey:@"WSSceneVideosV1"];
    if(scene==3) { self.materialPath=@""; [NSUserDefaults.standardUserDefaults removeObjectForKey:@"WSMaterialPath"]; }
    [self invalidateReview]; [self applyScene];
}
- (void)selectMaterial:(id)sender {
    (void)sender; if(![self canEditPreparation]) return;
    NSInteger scene=self.sceneSelector.selectedSegment;
    if(scene!=0 && scene!=3 && scene!=4) { self.errorLabel.stringValue=WSL(@"사진은 대기·말씀·종료 장면에서 선택하세요."); return; }
    NSOpenPanel *panel=[NSOpenPanel openPanel];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    panel.allowedFileTypes=@[@"png",@"jpg",@"jpeg"];
#pragma clang diagnostic pop
    panel.message=WSL(@"선택한 사진을 현재 장면 배경에 맞춰 표시합니다.");
    if([panel runModal]!=NSModalResponseOK) return;
    NSImage *image=[[NSImage alloc] initWithContentsOfURL:panel.URL];
    if(!image || image.size.width<=0 || image.size.height<=0) { self.errorLabel.stringValue=WSL(@"사진을 읽을 수 없습니다."); return; }
    self.sceneImages[scene]=panel.URL.path;
    if(scene==0 || scene==4) { [self.engine setLoopMediaAtPath:@"" scene:scene]; self.sceneVideos[scene]=@""; }
    else { self.materialPath=panel.URL.path; [NSUserDefaults.standardUserDefaults setObject:self.materialPath forKey:@"WSMaterialPath"]; self.sourceModes[scene]=@0; [self.engine setWindowCaptureEnabled:NO scene:scene]; }
    [NSUserDefaults.standardUserDefaults setObject:self.sceneImages forKey:@"WSSceneImagesV1"];
    [NSUserDefaults.standardUserDefaults setObject:self.sceneVideos forKey:@"WSSceneVideosV1"];
    [self invalidateReview]; [self applyScene];
}
- (void)loadBroadcasts:(NSDictionary *)result {
    self.youtubeConnected=YES;
    [self.broadcastMenu removeAllItems];
    for(NSDictionary *item in result[@"broadcasts"]) {
        [self.broadcastMenu addItemWithTitle:[NSString stringWithFormat:@"%@ · %@",item[@"title"],item[@"privacy"]]];
        self.broadcastMenu.lastItem.representedObject=item;
    }
    if(!self.broadcastMenu.numberOfItems) [self.broadcastMenu addItemWithTitle:WSL(@"새 예배를 만들어주세요")];
    self.youtubeLabel.stringValue=[NSString stringWithFormat:WSL(@"연결된 채널: %@"),result[@"channel"] ?: @""];
    [self updateStatus:nil];
}
- (void)openYouTubeStudio:(id)sender {
    (void)sender; [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"https://studio.youtube.com"]];
}
// 새 Google OAuth JSON으로 바꾸기: 로그인 정보와 예전 설정 파일을 지우고 파일 고르기부터 다시
- (void)replaceYouTubeConfiguration:(id)sender {
    (void)sender;
    if(![self canEditPreparation]) return;
    if(self.activeBroadcastID.length || self.youtube.busy || self.engine.streaming) { self.youtubeLabel.stringValue=WSL(@"방송 또는 연결 작업을 먼저 마쳐주세요."); return; }
    [self.youtube disconnect];
    [NSFileManager.defaultManager removeItemAtURL:self.youtube.configurationURL error:nil];
    self.youtubeConnected=NO; [self.broadcastMenu removeAllItems];
    [self.broadcastMenu addItemWithTitle:WSL(@"계정을 다시 연결하세요")];
    [self connectYouTube:nil];
}
- (void)disconnectYouTube:(id)sender {
    if(![self canEditPreparation]) return;
    [self invalidateReview];
    (void)sender;
    if(self.activeBroadcastID.length || self.youtube.busy) { self.youtubeLabel.stringValue=WSL(@"방송 또는 연결 작업을 먼저 마쳐주세요."); return; }
    if([self.youtube disconnect]) {
        self.youtubeConnected=NO; [self.broadcastMenu removeAllItems];
        [self.broadcastMenu addItemWithTitle:WSL(@"계정을 다시 연결하세요")];
        self.youtubeLabel.stringValue=WSL(@"이 Mac의 로그인 정보를 지웠습니다. 다시 연결할 수 있습니다.");
    } else self.youtubeLabel.stringValue=WSL(@"키체인의 연결 정보를 지우지 못했습니다.");
}
- (void)connectYouTube:(id)sender {
    if(self.engine.streaming || self.broadcastAction || self.youtube.busy) return;
    [self invalidateReview];
    (void)sender;
    if(self.youtube.busy || self.broadcastAction) return;
    if(!self.youtube.configured) {
        NSOpenPanel *panel=[NSOpenPanel openPanel];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        panel.allowedFileTypes=@[@"json"];
#pragma clang diagnostic pop
        panel.message=WSL(@"개발용 최초 설정: Google Cloud에서 Desktop app으로 만든 OAuth JSON을 선택하세요. 개인 Google 비밀번호 파일이 아닙니다.");
        if([panel runModal]!=NSModalResponseOK) return;
        NSError *error=nil;
        if(![self.youtube importConfiguration:panel.URL error:&error]) { self.youtubeLabel.stringValue=error.localizedDescription; return; }
    }
    self.youtubeLabel.stringValue=WSL(@"YouTube 연결 중 · 처음 연결은 브라우저에서 승인하세요.");
    // 이번 실행에서 이미 성공한 연결이면 목록만 새로 받고, 아니면(다른 계정·실패 후) 항상 Google 로그인부터
    [self.youtube run:(self.youtubeConnected && self.youtube.connected && !self.activeBroadcastID.length) ? @"list" : @"login" arguments:@{} completion:^(NSDictionary *result,NSString *error) {
        if(error) { self.youtubeLabel.stringValue=error; [self updateStatus:nil]; return; }
        // 로그인·목록이 성공했으면 남아 있는 방송 기록과 상관없이 연결됨으로 표시하고, 기록은 따로 확인·정리
        [self loadBroadcasts:result];
        if(self.activeBroadcastID.length) [self checkBroadcast:nil];
    }];
}
- (void)createBroadcast:(id)sender {
    if(![self canEditPreparation]) return;
    [self invalidateReview];
    (void)sender; if(self.youtube.busy || self.activeBroadcastID.length) return;
    NSAlert *alert=[NSAlert new]; alert.messageText=WSL(@"새 YouTube 예배");
    alert.informativeText=WSL(@"예약 방송을 만듭니다. ‘방송 시작’을 누르기 전에는 영상이 공개되지 않습니다.");
    NSTextField *title=[NSTextField textFieldWithString:WSL(@"주일 예배")];
    [title.widthAnchor constraintEqualToConstant:370].active=YES;
    NSPopUpButton *privacy=[NSPopUpButton new]; [privacy addItemsWithTitles:@[WSL(@"일부 공개 · 링크가 있는 사람"),WSL(@"공개 · 누구나"),WSL(@"비공개")]];
    NSButton *kids=[NSButton checkboxWithTitle:WSL(@"YouTube 아동용 콘텐츠에 해당함") target:nil action:nil];
    NSStackView *form=column(@[title,privacy,kids]); form.frame=NSMakeRect(0,0,390,120); alert.accessoryView=form;
    [alert addButtonWithTitle:WSL(@"예배 만들기")]; [alert addButtonWithTitle:WSL(@"취소")];
    if([alert runModal]!=NSAlertFirstButtonReturn) return;
    NSArray *values=@[@"unlisted",@"public",@"private"];
    [self.youtube run:@"create" arguments:@{@"title":title.stringValue,@"privacy":values[privacy.indexOfSelectedItem],@"kids":@(kids.state==NSControlStateValueOn)} completion:^(NSDictionary *result,NSString *error) {
        if(error) { self.youtubeLabel.stringValue=error; return; }
        [self.broadcastMenu addItemWithTitle:[NSString stringWithFormat:@"%@ · %@",result[@"title"],result[@"privacy"]]];
        self.broadcastMenu.lastItem.representedObject=result; [self.broadcastMenu selectItem:self.broadcastMenu.lastItem];
        self.youtubeLabel.stringValue=WSL(@"예배가 준비되었습니다. 화면과 마이크를 확인한 뒤 방송을 시작하세요.");
    }];
}
// 선택한 예배의 공개 범위 바꾸기 (방송 전 · 방송 중 모두 YouTube가 허용)
- (void)setBroadcastPrivacy:(NSString *)privacy {
    // 다음 방송의 기본값으로 저장하고, 방송 중이면 지금 방송에도 바로 적용
    if(![privacy isKindOfClass:NSString.class] || ![@[@"public",@"unlisted",@"private"] containsObject:privacy]) return;
    [NSUserDefaults.standardUserDefaults setObject:privacy forKey:@"WSBroadcastPrivacy"];
    if(!self.activeBroadcastID.length || self.youtube.busy) return;
    self.youtubeLabel.stringValue=WSL(@"공개 범위를 바꾸는 중…");
    [self.youtube run:@"privacy" arguments:@{@"id":self.activeBroadcastID,@"privacy":privacy} completion:^(NSDictionary *result,NSString *error) {
        if(error) { self.youtubeLabel.stringValue=error; [self updateStatus:nil]; return; }
        NSDictionary *names=@{@"public":WSL(@"공개"),@"unlisted":WSL(@"일부 공개"),@"private":WSL(@"비공개")};
        NSString *value=result[@"privacy"] ?: privacy;
        self.youtubeLabel.stringValue=[NSString stringWithFormat:WSL(@"공개 범위: %@"),names[value] ?: value];
        [self updateStatus:nil];
    }];
}
- (void)checkBroadcast:(id)sender {
    (void)sender; if(!self.activeBroadcastID.length || self.youtube.busy) return;
    [self.youtube run:@"status" arguments:@{@"id":self.activeBroadcastID} completion:^(NSDictionary *result,NSString *error) {
        if(error) {
            if([error containsString:@"notFound"] || [error containsString:@"404"]) { [self finishBroadcast]; self.youtubeLabel.stringValue=WSL(@"YouTube에 해당 방송이 없어 정리했습니다."); return; }
            self.youtubeLabel.stringValue=error; return;
        }
        self.broadcastState=result[@"state"]; self.isLive=[self.broadcastState isEqualToString:@"live"];
        self.youtubeLabel.stringValue=[NSString stringWithFormat:WSL(@"YouTube 상태: %@"),self.broadcastState];
        const BOOL notStarted=[@[@"created",@"ready",@"revoked"] containsObject:self.broadcastState ?: @""] && !self.engine.streamConnected;
        if([self.broadcastState isEqualToString:@"complete"] || notStarted) { [self finishBroadcast]; }
    }];
}
- (void)setBroadcastAction:(BOOL)value { _broadcastAction=value; if(!value) _broadcastStep=0; }
/// ‘방송 시작’마다 새로 만드는 YouTube 방송의 제목 (오늘 날짜로 정해 둔 제목이 있으면 그것)
- (NSString *)broadcastTitleForToday {
    NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;
    NSDateFormatter *day=[NSDateFormatter new]; day.dateFormat=@"yyyy-MM-dd";
    NSString *today=[day stringFromDate:NSDate.date];
    NSString *saved=[defaults stringForKey:@"WSBroadcastTitle"];
    if(saved.length && [[defaults stringForKey:@"WSBroadcastTitleDate"] isEqualToString:today]) return saved;
    NSDateFormatter *nice=[NSDateFormatter new]; nice.dateStyle=NSDateFormatterLongStyle; nice.timeStyle=NSDateFormatterNoStyle;
    return [NSString stringWithFormat:@"%@ %@",[nice stringFromDate:NSDate.date],WSL(@"예배")];
}
- (void)finishBroadcast {
    [self.engine stopStream]; self.activeBroadcastID=@""; self.isLive=NO; self.broadcastAction=NO;
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"WSActiveBroadcastID"];
    self.youtubeLabel.stringValue=WSL(@"YouTube 방송이 종료되었습니다.");
    [self updateStatus:nil];
}
- (void)toggleBroadcast:(id)sender {
    (void)sender;
    if(self.youtube.busy || self.broadcastAction) return;
    if(self.activeBroadcastID.length) {
        NSAlert *alert=[NSAlert new]; alert.messageText=WSL(@"YouTube 방송을 종료할까요?");
        [alert addButtonWithTitle:WSL(@"방송 종료")]; [alert addButtonWithTitle:WSL(@"계속 방송")];
        if(!self.swiftStudioHost) [alert addButtonWithTitle:WSL(@"종료 화면 먼저 보기")];
        NSModalResponse response=[alert runModal];
        if(response==NSAlertThirdButtonReturn) { self.sceneSelector.selectedSegment=4; [self changeScene:self.sceneSelector]; return; }
        if(response!=NSAlertFirstButtonReturn) return;
        self.broadcastAction=YES; self.broadcastStep=5; self.youtubeLabel.stringValue=WSL(@"방송을 마치는 중…");
        [self.youtube run:@"status" arguments:@{@"id":self.activeBroadcastID} completion:^(NSDictionary *state,NSString *error) {
            if(error) { self.broadcastAction=NO; self.youtubeLabel.stringValue=error; return; }
            NSString *value=state[@"state"];
            if([@[@"complete",@"ready",@"created"] containsObject:value]) { [self finishBroadcast]; return; }
            [self.youtube run:@"complete" arguments:@{@"id":self.activeBroadcastID} completion:^(NSDictionary *result,NSString *failure) {
                if(failure || ![result[@"state"] isEqualToString:@"complete"]) {
                    self.broadcastAction=NO; self.youtubeLabel.stringValue=failure ?: WSL(@"종료 확인이 지연됩니다. 방송 상태를 확인하세요."); return;
                }
                [self finishBroadcast];
            }];
        }];
        return;
    }
    if(!self.performanceMode) { self.errorLabel.stringValue=WSL(@"준비 확인을 마치고 진행 화면에서 방송을 시작하세요."); return; }
    if(!self.youtubeConnected || !self.engine.hasCamera || !self.engine.hasMicrophone) { self.youtubeLabel.stringValue=WSL(@"YouTube 계정과 카메라·마이크 연결을 먼저 완료하세요."); return; }
    // YouTube 예약 방송은 한 번 쓰면 다시 쓸 수 없다 → 시작할 때마다 새로 만든다
    NSString *title=[self broadcastTitleForToday];
    NSString *privacy=[NSUserDefaults.standardUserDefaults stringForKey:@"WSBroadcastPrivacy"] ?: @"unlisted";
    if(![@[@"public",@"unlisted",@"private"] containsObject:privacy]) privacy=@"unlisted";
    NSDictionary *names=@{@"public":WSL(@"공개"),@"unlisted":WSL(@"일부 공개"),@"private":WSL(@"비공개")};
    NSAlert *alert=[NSAlert new]; alert.messageText=WSL(@"YouTube 방송을 시작할까요?");
    alert.informativeText=[NSString stringWithFormat:WSL(@"%@\n공개 범위: %@\n현재 장면과 마이크 소리가 YouTube로 송출됩니다."),title,names[privacy]];
    [alert addButtonWithTitle:WSL(@"방송 시작")]; [alert addButtonWithTitle:WSL(@"취소")];
    if([alert runModal]!=NSAlertFirstButtonReturn) return;
    self.broadcastAction=YES; self.broadcastStep=1; self.youtubeLabel.stringValue=WSL(@"YouTube 방송 만드는 중…");
    [self.youtube run:@"create" arguments:@{@"title":title,@"privacy":privacy,@"kids":@NO} completion:^(NSDictionary *created,NSString *createError) {
        if(createError || ![created[@"id"] isKindOfClass:NSString.class]) { self.broadcastAction=NO; self.youtubeLabel.stringValue=createError ?: WSL(@"YouTube 방송을 만들지 못했습니다."); return; }
        NSString *broadcastID=created[@"id"];
        self.broadcastStep=2; self.youtubeLabel.stringValue=WSL(@"YouTube로 영상 보내기 시작…");
        [self.youtube run:@"prepare" arguments:@{@"id":broadcastID} completion:^(NSDictionary *result,NSString *error) {
            if(error) { self.broadcastAction=NO; self.youtubeLabel.stringValue=error; return; }
            if(![self.engine startStreamToServer:result[@"server"] key:result[@"key"]]) {
                self.broadcastAction=NO; self.youtubeLabel.stringValue=self.engine.lastError; return;
            }
            self.compareButton.state=NSControlStateValueOff; self.faceGuideButton.state=NSControlStateValueOff;
            self.activeBroadcastID=broadcastID; self.broadcastState=@"connecting";
            [NSUserDefaults.standardUserDefaults setObject:self.activeBroadcastID forKey:@"WSActiveBroadcastID"];
            self.broadcastStep=3; self.youtubeLabel.stringValue=WSL(@"YouTube 영상 수신 확인 중…");
            [self.youtube run:@"live" arguments:@{@"id":self.activeBroadcastID} completion:^(NSDictionary *live,NSString *failure) {
                self.broadcastAction=NO;
                if(failure) {
                    // 채널 라이브 꺼짐·권한 없음 등으로 시작 자체가 안 된 경우: 방송 중 상태로 남지 않게 정리
                    if([failure containsString:@"liveStreamingNotEnabled"] || [failure containsString:@"livePermissionBlocked"] ||
                       [failure containsString:@"403"] || [failure containsString:@"forbidden"]) {
                        [self finishBroadcast];
                    }
                    self.youtubeLabel.stringValue=failure; return;
                }
                self.broadcastState=live[@"state"]; self.isLive=[self.broadcastState isEqualToString:@"live"];
                self.youtubeLabel.stringValue=self.isLive ? WSL(@"● YouTube 방송 중") : WSL(@"방송 상태 확인이 필요합니다.");
            }];
        }];
    }];
}

- (void)changeBeauty:(NSSegmentedControl *)sender {
    if(![self canEditPreparation]) return;
    [self invalidateReview];
    const NSInteger preset=sender.selectedSegment;
    [self.engine setBeautyPreset:preset];
    self.strengthSlider.doubleValue=preset==0 ? 0 : preset==1 ? 70 : 100;
    self.skinSlider.doubleValue=preset==2 ? 78 : 65;
    self.shapeSlider.doubleValue=preset==2 ? 40 : 25;
    self.eyeSlider.doubleValue=preset==2 ? 35 : 20;
    self.browSlider.doubleValue=preset==2 ? 55 : 35;
    [self saveBeautySettings];
}
- (void)toggleBeautyDetails:(NSButton *)sender { self.detailControls.hidden=sender.state!=NSControlStateValueOn; }
- (void)adjustBeauty:(id)sender {
    if(![self canEditPreparation]) return;
    [self invalidateReview];
    (void)sender;
    self.beautySelector.selectedSegment=-1;
    [self.engine setBeautyStrength:self.strengthSlider.doubleValue/100 skin:self.skinSlider.doubleValue/100
      shape:self.shapeSlider.doubleValue/100 eyes:self.eyeSlider.doubleValue/100 brows:self.browSlider.doubleValue/100];
    [self saveBeautySettings];
}
- (void)changeFaceGuide:(NSButton *)sender { if(![self canEditPreparation]) return; [self.engine setFaceGuide:sender.state==NSControlStateValueOn]; }
- (void)changeComparison:(NSButton *)sender { if(![self canEditPreparation]) return; [self.engine setBeautyComparison:sender.state==NSControlStateValueOn]; }
- (void)toggleMute:(NSButton *)sender { [self.engine setMicrophoneMuted:sender.state == NSControlStateValueOn]; }
- (void)toggleRecording:(id)sender {
    (void)sender;
    if (self.engine.recording) { [self.engine stopRecording]; [self updateStatus:nil]; return; }
    NSSavePanel *panel = [NSSavePanel savePanel];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    panel.allowedFileTypes = @[@"mkv"];
#pragma clang diagnostic pop
    panel.canCreateDirectories = YES;
    NSDateFormatter *formatter = [NSDateFormatter new]; formatter.dateFormat = @"yyyy-MM-dd_HH-mm-ss";
    panel.nameFieldStringValue = [NSString stringWithFormat:@"Worship-%@.mkv",[formatter stringFromDate:NSDate.date]];
    panel.nameFieldStringValue = [panel.nameFieldStringValue stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
    panel.message = WSL(@"MKV 파일로 녹화합니다. 마이크가 연결되어 있는지 먼저 확인하세요.");
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK) { self.compareButton.state=NSControlStateValueOff; self.faceGuideButton.state=NSControlStateValueOff; if (![self.engine startRecordingAtPath:panel.URL.path]) [self reportFailure]; else self.errorLabel.stringValue = @""; [self updateStatus:nil]; }
    }];
}
- (void)showRecording:(id)sender {
    (void)sender;
    if (self.engine.recordingPath.length) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:self.engine.recordingPath]]];
}
- (void)updateStatus:(id)sender {
    (void)sender; [self.engine poll];
    [self tickCountdown];
    if (self.engine.ready) self.statusLabel.stringValue = self.engine.status;
    else if (self.engine.lastError.length) self.statusLabel.stringValue = self.engine.lastError;
    const BOOL locked = self.engine.recording || self.engine.stopping || self.engine.streaming || self.broadcastAction;
    const BOOL youtubeBusy=self.youtube.busy || self.broadcastAction;
    self.youtubeButton.enabled=!youtubeBusy;
    self.youtubeButton.title=self.activeBroadcastID.length ? WSL(@"YouTube 재인증") : WSL(@"YouTube 연결·새로고침");
    self.createBroadcastButton.enabled=self.youtubeConnected && !youtubeBusy && !self.activeBroadcastID.length;
    self.broadcastMenu.enabled=self.youtubeConnected && [self canEditPreparation];
    self.broadcastButton.enabled=!youtubeBusy && (self.activeBroadcastID.length || (self.youtubeConnected && self.engine.hasCamera && self.engine.hasMicrophone));
    self.broadcastButton.title=self.activeBroadcastID.length ? WSL(@"방송 종료") : WSL(@"방송 시작");
    self.broadcastStatusButton.enabled=self.activeBroadcastID.length && !youtubeBusy;
    if(self.isLive && !youtubeBusy && [self.youtubeLabel.stringValue hasPrefix:@"● "]) self.youtubeLabel.stringValue=self.engine.streamConnected ? WSL(@"● YouTube 방송 중") : WSL(@"● YouTube 방송 진행 중 · 송출 연결 확인 필요");
    self.startButton.enabled = !self.engine.ready;
    self.startButton.title = self.engine.ready ? WSL(@"엔진 실행 중") : WSL(@"영상 엔진 시작");
    self.cameraButton.enabled = self.microphoneButton.enabled = self.engine.ready && [self canEditPreparation];
    self.cameraMenu.enabled = self.microphoneMenu.enabled = self.engine.ready && [self canEditPreparation];
    self.muteButton.enabled = self.engine.hasMicrophone;
    self.sceneSelector.enabled = self.engine.ready;
    self.beautySelector.enabled = self.engine.hasCamera && [self canEditPreparation];
    for(NSSlider *slider in @[self.strengthSlider,self.skinSlider,self.shapeSlider,self.eyeSlider,self.browSlider]) slider.enabled=self.engine.hasCamera && [self canEditPreparation];
    self.compareButton.enabled = self.engine.hasCamera && !locked && !self.performanceMode;
    self.faceGuideButton.enabled=self.engine.hasCamera && !locked && !self.performanceMode;
    self.beautyStatusLabel.stringValue = self.engine.beautyStatus;
    self.recordButton.enabled = self.engine.ready && self.engine.hasCamera && !self.engine.stopping;
    self.recordButton.title = self.engine.stopping ? WSL(@"파일 저장 중…") : self.engine.recording ? WSL(@"녹화 종료") : WSL(@"녹화 시작…");
    if (self.engine.recordingPath.length) self.recordLabel.stringValue = [NSString stringWithFormat:@"%@\n%@",self.engine.stopping?WSL(@"녹화 마무리 중"):self.engine.recording?WSL(@"녹화 중"):WSL(@"마지막 녹화 파일"),self.engine.recordingPath];
    if (self.engine.lastError.length) self.errorLabel.stringValue = self.engine.lastError;
    [self updateStudioStatus];
}
- (BOOL)canQuit {
    if(self.youtube.busy || self.activeBroadcastID.length || self.engine.streaming) {
        NSAlert *alert=[NSAlert new];
        alert.messageText=self.engine.streaming ? WSL(@"YouTube로 송출 중입니다.") : WSL(@"YouTube 방송 기록이 남아 있습니다.");
        alert.informativeText=self.engine.streaming
            ? WSL(@"방송 종료 버튼으로 마무리하는 것이 안전합니다. 그래도 끝내면 송출이 멈추고, YouTube에서는 방송이 잠시 ‘연결 끊김’으로 남을 수 있습니다.")
            : WSL(@"방송이 시작되지 못했거나 이미 끝났을 수 있습니다. ‘상태 확인’으로 정리하거나, 그대로 끝낼 수 있습니다.");
        [alert addButtonWithTitle:WSL(@"상태 확인")];
        [alert addButtonWithTitle:WSL(@"그래도 종료")];
        [alert addButtonWithTitle:WSL(@"취소")];
        alert.buttons[1].hasDestructiveAction=YES;
        NSModalResponse response=[alert runModal];
        if(response==NSAlertFirstButtonReturn) { [self checkBroadcast:nil]; return NO; }
        if(response!=NSAlertSecondButtonReturn) return NO;
        if(self.engine.recording && !self.engine.stopping) [self.engine stopRecording];
        [self.engine stopStream];
        self.activeBroadcastID=@""; self.isLive=NO; self.broadcastAction=NO;
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"WSActiveBroadcastID"];
        if(self.engine.recording || self.engine.stopping) return NO;
        return YES;
    }
    if (!self.engine.recording && !self.engine.stopping) return YES;
    NSAlert *alert = [NSAlert new]; alert.messageText = WSL(@"녹화를 먼저 종료해주세요.");
    alert.informativeText = WSL(@"녹화 종료 버튼을 누르고 파일 저장이 끝난 뒤 앱을 종료할 수 있습니다.");
    [alert runModal]; return NO;
}
- (BOOL)windowShouldClose:(NSWindow *)sender { (void)sender; return [self canQuit]; }
// churchobs://auth (Google 로그인 완료), churchobs://billing (결제 완료) → Swift 계정 서비스로 전달
- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls {
    (void)application;
    for(NSURL *url in urls) [NSNotificationCenter.defaultCenter postNotificationName:@"WSOpenChurchOBSURL" object:nil userInfo:@{@"url":url}];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender { (void)sender; return [self canQuit] ? NSTerminateNow : NSTerminateCancel; }
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { (void)sender; return YES; }
- (void)applicationWillTerminate:(NSNotification *)notification { (void)notification; [self.timer invalidate]; self.preview.sizeChanged = nil; [self.engine shutdown]; }
@end

// 예전 이름(Worship Studio)에서 Church OBS로: 저장 폴더와 설정을 한 번 옮긴다
static void ws_migrate_from_worship_studio(void) {
    NSFileManager *files=NSFileManager.defaultManager;
    NSString *support=NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,NSUserDomainMask,YES).firstObject;
    NSString *target=[support stringByAppendingPathComponent:@"ChurchOBS"];
    [files createDirectoryAtPath:target withIntermediateDirectories:YES attributes:nil error:nil];
    for(NSString *oldName in @[@"WorshipStudio",@"Worship Studio"]) {
        NSString *old=[support stringByAppendingPathComponent:oldName];
        for(NSString *item in [files contentsOfDirectoryAtPath:old error:nil] ?: @[]) {
            NSString *to=[target stringByAppendingPathComponent:item];
            if(![files fileExistsAtPath:to]) [files moveItemAtPath:[old stringByAppendingPathComponent:item] toPath:to error:nil];
        }
    }
    NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;
    if(![defaults boolForKey:@"ChurchOBSMigratedDefaults"]) {
        NSDictionary *previous=[defaults persistentDomainForName:@"app.worshipstudio.native.dev"];
        for(NSString *key in previous) {
            if([key isEqualToString:@"WSActiveBroadcastID"]) continue;   // 예전 앱의 방송 기록은 옮기지 않음
            if(![defaults objectForKey:key]) [defaults setObject:previous[key] forKey:key];
        }
        [defaults setBool:YES forKey:@"ChurchOBSMigratedDefaults"];
    }
}

int main(int argc, const char *argv[]) {
    (void)argc; (void)argv;
    @autoreleasepool {
        ws_migrate_from_worship_studio();
        if (argc >= 3 && strcmp(argv[1], "--smoke-test") == 0) return ws_run_smoke_test([NSString stringWithUTF8String:argv[2]]);
        NSApplication *app = NSApplication.sharedApplication;
        AppDelegate * __attribute__((objc_precise_lifetime)) delegate = [AppDelegate new];
        app.delegate = delegate; [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        if(argc>=2 && strcmp(argv[1],"--ui-smoke-test")==0) {
            // No account calls or playback of a user's files in the UI test process.
            NSArray *empty=@[@"",@"",@"",@"",@""];
            [NSUserDefaults.standardUserDefaults setVolatileDomain:@{@"WSActiveBroadcastID":@"",@"WSSceneVideosV1":empty,@"WSSceneMusicV1":empty,@"WSSceneImagesV1":empty,@"WSMaterialPath":@""} forName:NSArgumentDomain];
            [app finishLaunching];
            if(!delegate.window) [delegate applicationDidFinishLaunching:[NSNotification notificationWithName:NSApplicationDidFinishLaunchingNotification object:app]];
            int result=[delegate verifyStudioUI];
            [delegate.timer invalidate]; delegate.preview.sizeChanged=nil;
            [delegate.engine shutdown]; [delegate.window orderOut:nil];
            return result;
        }
        [app run];
    }
    return 0;
}
