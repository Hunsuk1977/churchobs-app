// SPDX-License-Identifier: GPL-2.0-or-later
// Native commands keep the established permission, Keychain and YouTube flow.
NS_ASSUME_NONNULL_BEGIN
- (NSDictionary<NSString *,id> *)studioState {
    NSMutableArray *broadcasts=[NSMutableArray new];
    for(NSMenuItem *item in self.broadcastMenu.itemArray) {
        NSDictionary *value=item.representedObject;
        if([value isKindOfClass:NSDictionary.class] && value[@"id"]) [broadcasts addObject:@{@"id":value[@"id"],@"title":value[@"title"] ?: item.title,@"privacy":value[@"privacy"] ?: @""}];
    }
    NSDictionary *selected=self.broadcastMenu.selectedItem.representedObject;
    NSMutableArray *cameras=[NSMutableArray new],*microphones=[NSMutableArray new];
    for(NSMenuItem *item in self.cameraMenu.itemArray) if([item.representedObject isKindOfClass:NSString.class]) [cameras addObject:@{@"id":item.representedObject,@"name":item.title}];
    for(NSMenuItem *item in self.microphoneMenu.itemArray) if([item.representedObject isKindOfClass:NSString.class]) [microphones addObject:@{@"id":item.representedObject,@"name":item.title}];
    return @{@"ready":@(self.engine.ready),@"camera":@(self.engine.hasCamera),@"microphone":@(self.engine.hasMicrophone),
      @"youtube":@(self.youtubeConnected),@"busy":@(self.youtube.busy || self.broadcastAction),@"recording":@(self.engine.recording),
      @"stopping":@(self.engine.stopping),@"streaming":@(self.engine.streaming),@"live":@(self.isLive && self.engine.streamConnected),
      @"activeBroadcast":self.activeBroadcastID ?: @"",@"cameras":cameras,@"microphones":microphones,
      @"cameraID":self.cameraMenu.selectedItem.representedObject ?: @"",@"microphoneID":self.microphoneMenu.selectedItem.representedObject ?: @"",
      @"broadcasts":broadcasts,@"broadcastID":selected[@"id"] ?: @"",@"youtubeStatus":self.youtubeLabel.stringValue ?: @"",@"broadcastStep":@(self.broadcastStep),
      @"error":self.errorLabel.stringValue ?: @"",@"beautyStatus":self.engine.beautyStatus,@"recordingPath":self.engine.recordingPath,
      @"levels":self.engine.graphAudioLevels,@"media":self.engine.graphMediaStates,@"micLevel":@(self.engine.microphoneLevel),@"muted":@(self.muteButton.state==NSControlStateValueOn),
      @"beautyPreset":@(self.beautySelector.selectedSegment),@"strength":@(self.strengthSlider.doubleValue),@"skin":@(self.skinSlider.doubleValue),
      @"shape":@(self.shapeSlider.doubleValue),@"eyes":@(self.eyeSlider.doubleValue),@"brows":@(self.browSlider.doubleValue),
      @"sourceSizes":self.engine.graphSourceSizes,@"sourceWarnings":self.engine.graphWarnings,@"probeLevel":@(self.engine.audioProbeLevel),@"virtualCam":@(self.engine.virtualCameraActive),@"projector":@(self.engine.projectorOpen),@"virtualCamAvailable":@(self.engine.virtualCameraAvailable),@"lookTone":@(self.engine.lookTone),@"stream":[self.engine streamStats],@"lookToneAmount":@(self.engine.lookToneAmount*100),@"lookBlur":@(self.engine.lookBlur*100),@"legacyTexts":self.sceneTexts,@"legacyImages":self.sceneImages,@"legacyVideos":self.sceneVideos,@"legacyMusic":self.sceneMusic};
}
- (BOOL)studioCommand:(NSString *)command arguments:(NSDictionary<NSString *,id> *)arguments {
    if([command isEqualToString:@"mode"]) {
        BOOL performance=[arguments[@"performance"] boolValue];
        if(self.engine.recording || self.engine.stopping || self.engine.streaming || self.activeBroadcastID.length || self.broadcastAction || self.youtube.busy) return NO;
        self.performanceMode=performance;
        [self.engine setStudioMode:performance];
        if(performance) { [self.engine clearGraphPreview]; [self.engine setBeautyComparison:NO]; [self.engine setFaceGuide:NO]; self.compareButton.state=self.faceGuideButton.state=NSControlStateValueOff; }
        else [self.engine clearGraphPreview];
        [self updateStatus:nil]; return YES;
    }
    if([command isEqualToString:@"refresh"]) { if(![self canEditPreparation]) return NO; [self refreshDevices:nil]; [self updateStatus:nil]; return YES; }
    if([command isEqualToString:@"camera"] || [command isEqualToString:@"microphone"]) {
        if(![self canEditPreparation]) return NO;
        BOOL camera=[command isEqualToString:@"camera"]; NSPopUpButton *menu=camera ? self.cameraMenu : self.microphoneMenu;
        NSString *identity=arguments[@"id"];
        for(NSMenuItem *item in menu.itemArray) if([item.representedObject isEqual:identity]) [menu selectItem:item];
        if(camera) [self connectCamera:nil]; else [self connectMicrophone:nil];
    } else if([command isEqualToString:@"youtube"]) [self connectYouTube:nil];
    else if([command isEqualToString:@"youtubeDisconnect"]) [self disconnectYouTube:nil];
    else if([command isEqualToString:@"youtubeSwitch"]) {
        // 다른 Google 계정·채널로: 이 Mac의 YouTube 로그인을 지우고 계정 선택 화면부터 다시
        if(self.activeBroadcastID.length || self.youtube.busy || self.broadcastAction || self.engine.streaming) {
            self.youtubeLabel.stringValue=WSL(@"방송 또는 연결 작업을 먼저 마쳐주세요."); return NO;
        }
        [self.youtube disconnect];
        self.youtubeConnected=NO; [self.broadcastMenu removeAllItems];
        [self connectYouTube:nil];
    }
    else if([command isEqualToString:@"youtubeConfig"]) [self replaceYouTubeConfiguration:nil];
    else if([command isEqualToString:@"createBroadcast"]) [self createBroadcast:nil];
    else if([command isEqualToString:@"selectBroadcast"]) {
        if(![self canEditPreparation]) return NO;
        for(NSMenuItem *item in self.broadcastMenu.itemArray) if([item.representedObject[@"id"] isEqual:arguments[@"id"]]) [self.broadcastMenu selectItem:item];
    } else if([command isEqualToString:@"broadcastPrivacy"]) [self setBroadcastPrivacy:arguments[@"privacy"]];
    else if([command isEqualToString:@"broadcast"]) [self toggleBroadcast:nil];
    else if([command isEqualToString:@"broadcastStatus"]) [self checkBroadcast:nil];
    else if([command isEqualToString:@"record"]) [self toggleRecording:nil];
    else if([command isEqualToString:@"recordingFile"]) [self showRecording:nil];
    else if([command isEqualToString:@"captions"]) {
        // WORDaLIVE 자막: [{"t": 번역, "s": 원문}] 최신이 마지막
        NSArray *lines=[arguments[@"lines"] isKindOfClass:NSArray.class] ? arguments[@"lines"] : @[];
        std::vector<std::string> t,s;
        for(NSDictionary *line in lines) {
            if(![line isKindOfClass:NSDictionary.class] || t.size()>=4) continue;
            t.push_back([line[@"t"] isKindOfClass:NSString.class] ? [line[@"t"] UTF8String] : "");
            s.push_back([line[@"s"] isKindOfClass:NSString.class] ? [line[@"s"] UTF8String] : "");
        }
        std::vector<const char *> tp,sp;
        for(size_t i=0;i<t.size();i++) { tp.push_back(t[i].c_str()); sp.push_back(s[i].c_str()); }
        ws_captions_set_lines(tp.data(),sp.data(),(int)tp.size());
        return YES;
    }
    else if([command isEqualToString:@"captionStyle"]) {
        // WORDaLIVE 스튜디오의 자막 디자인. active=NO 면 각 자막 소스의 Church OBS 설정으로 돌아간다
        struct ws_caption_style style={};
        style.active=[arguments[@"active"] boolValue];
        NSString *family=[arguments[@"family"] isKindOfClass:NSString.class] ? arguments[@"family"] : @"";
        snprintf(style.family,sizeof(style.family),"%s",family.UTF8String ?: "");
        style.weight=arguments[@"weight"] ? [arguments[@"weight"] intValue] : 600;
        style.size=arguments[@"size"] ? [arguments[@"size"] doubleValue] : 26;
        style.lines=arguments[@"lines"] ? [arguments[@"lines"] intValue] : 3;
        style.content_pct=arguments[@"content"] ? [arguments[@"content"] doubleValue] : 100;
        NSArray *fg=arguments[@"fg"], *bg=arguments[@"bg"];
        for(int i=0;i<4;i++) {
            style.fg[i]=[fg isKindOfClass:NSArray.class] && fg.count==4 ? [fg[i] doubleValue] : 1;
            style.bg[i]=[bg isKindOfClass:NSArray.class] && bg.count==4 ? [bg[i] doubleValue] : (i==3 ? 0.55 : 0);
        }
        ws_captions_set_style(&style);
        return YES;
    }
    else if([command isEqualToString:@"slide"]) {
        // WORDaLIVE 슬라이드: path = 내려받은 PNG (빈 값 = 없음), blank = 화면 끄기
        NSString *path=[arguments[@"path"] isKindOfClass:NSString.class] ? arguments[@"path"] : @"";
        ws_slides_set(path.length ? path.fileSystemRepresentation : "",[arguments[@"blank"] boolValue]);
        return YES;
    }
    else if([command isEqualToString:@"media"]) {
        // {id, action: play|pause|restart|stop|loop, loop: bool}
        NSString *identity=[arguments[@"id"] isKindOfClass:NSString.class] ? arguments[@"id"] : @"";
        NSString *action=[arguments[@"action"] isKindOfClass:NSString.class] ? arguments[@"action"] : @"";
        return [self.engine mediaControl:identity action:action loop:[arguments[@"loop"] boolValue]];
    }
    else if([command isEqualToString:@"projectorScene"]) {
        // 장면 그래프 (sceneID 없음 = 송출 화면 그대로)
        BOOL okay=[self.engine applyProjectorGraph:arguments];
        if(!okay) self.errorLabel.stringValue=self.engine.lastError;
        return okay;
    }
    else if([command isEqualToString:@"audioMonitor"]) {
        // {id: 소스 UUID, mode: broadcast|both|room}
        NSString *identity=[arguments[@"id"] isKindOfClass:NSString.class] ? arguments[@"id"] : @"";
        NSString *mode=[arguments[@"mode"] isKindOfClass:NSString.class] ? arguments[@"mode"] : @"broadcast";
        return [self.engine setAudioMonitor:identity mode:mode];
    }
    else if([command isEqualToString:@"projector"]) {
        // {display: UUID, windowed: bool} → 열기 · {} → 닫기
        NSString *display=[arguments[@"display"] isKindOfClass:NSString.class] ? arguments[@"display"] : @"";
        if(!display.length && !arguments[@"windowed"]) { [self.engine closeProjector]; return YES; }
        BOOL okay=[self.engine openProjectorOnDisplay:display windowed:[arguments[@"windowed"] boolValue]];
        self.errorLabel.stringValue=okay ? @"" : self.engine.lastError;
        return okay;
    }
    else if([command isEqualToString:@"virtualCamera"]) {
        BOOL okay=[self.engine setVirtualCameraEnabled:[arguments[@"enabled"] boolValue]];
        self.errorLabel.stringValue=okay ? @"" : self.engine.lastError;
        return okay;
    }
    else if([command isEqualToString:@"audioProbe"]) {
        NSString *device=[arguments[@"id"] isKindOfClass:NSString.class] ? arguments[@"id"] : @"";
        [self.engine setAudioProbe:device]; return YES;
    }
    else if([command isEqualToString:@"mute"]) { self.muteButton.state=self.muteButton.state==NSControlStateValueOn ? NSControlStateValueOff : NSControlStateValueOn; [self toggleMute:self.muteButton]; }
    else if([command isEqualToString:@"look"]) {
        if(![self canEditPreparation]) return NO;
        NSInteger tone=arguments[@"tone"] ? [arguments[@"tone"] integerValue] : self.engine.lookTone;
        double amount=arguments[@"amount"] ? [arguments[@"amount"] doubleValue]/100.0 : self.engine.lookToneAmount;
        double blur=arguments[@"blur"] ? [arguments[@"blur"] doubleValue]/100.0 : self.engine.lookBlur;
        [self.engine setLookTone:tone amount:amount blur:blur];
    }
    else if([command isEqualToString:@"beauty"]) {
        if(![self canEditPreparation]) return NO;
        if(arguments[@"preset"]) { self.beautySelector.selectedSegment=[arguments[@"preset"] integerValue]; [self changeBeauty:self.beautySelector]; }
        else {
            for(NSString *key in @[@"strength",@"skin",@"shape",@"eyes",@"brows"]) if(arguments[key]) {
                NSSlider *slider=[key isEqualToString:@"strength"] ? self.strengthSlider : [key isEqualToString:@"skin"] ? self.skinSlider : [key isEqualToString:@"shape"] ? self.shapeSlider : [key isEqualToString:@"eyes"] ? self.eyeSlider : self.browSlider;
                slider.doubleValue=std::clamp([arguments[key] doubleValue],0.0,100.0);
            }
            [self adjustBeauty:nil];
        }
        if(arguments[@"compare"]) { self.compareButton.state=[arguments[@"compare"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff; [self changeComparison:self.compareButton]; }
    } else return NO;
    [self updateStatus:nil]; return YES;
}
- (NSView *)programPreviewView { return self.programPreview; }
- (BOOL)applySceneGraph:(NSDictionary<NSString *,id> *)graph preview:(BOOL)preview {
    // 진행 화면의 다음 장면 미리보기(studio)는 편집 잠금과 무관하게 허용
    BOOL studio=preview && [graph[@"studio"] boolValue] && self.performanceMode;
    if(preview && !studio && ![self canEditPreparation]) return NO;
    BOOL okay=[self.engine applyGraph:graph preview:preview];
    self.errorLabel.stringValue=okay ? @"" : self.engine.lastError;
    return okay;
}
- (BOOL)updatePreviewLayout:(NSArray<NSDictionary<NSString *,id> *> *)items {
    if(![self canEditPreparation]) return NO;
    return [self.engine updateGraphPreviewLayout:items];
}

NS_ASSUME_NONNULL_END
