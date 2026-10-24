// SPDX-License-Identifier: GPL-2.0-or-later
- (NSString *)countdownText {
    return [NSString stringWithFormat:@"%02ld:%02ld",(long)(self.countdownRemaining/60),(long)(self.countdownRemaining%60)];
}
- (void)configureCountdown:(id)sender {
    (void)sender; if(![self canEditPreparation]) return;
    [self invalidateReview];
    self.countdownMinutes.integerValue=std::clamp<NSInteger>(self.countdownMinutes.integerValue,1,180);
    [NSUserDefaults.standardUserDefaults setInteger:self.countdownMinutes.integerValue forKey:@"WSCountdownMinutes"];
    [NSUserDefaults.standardUserDefaults setBool:self.countdownAuto.state==NSControlStateValueOn forKey:@"WSCountdownAuto"];
    [self resetCountdown:nil];
}
- (void)pauseCountdown {
    if(self.countdownDeadline>0) self.countdownRemaining=ws_countdown_remaining(self.countdownDeadline,NSProcessInfo.processInfo.systemUptime);
    self.countdownDeadline=0;
}
- (void)toggleCountdown:(id)sender {
    (void)sender;
    if(!self.engine.ready || self.sceneSelector.selectedSegment!=0 || self.countdownRemaining<=0) return;
    if(self.countdownDeadline>0) [self pauseCountdown];
    else self.countdownDeadline=NSProcessInfo.processInfo.systemUptime+self.countdownRemaining;
    self.countdownVisible=YES; [self applyScene];
}
- (void)resetCountdown:(id)sender {
    (void)sender; self.countdownDeadline=0;
    self.countdownRemaining=std::clamp<NSInteger>(self.countdownMinutes.integerValue,1,180)*60;
    self.countdownVisible=NO; self.countdownLabel.stringValue=[self countdownText];
    if(self.sceneSelector.selectedSegment==0) [self applyScene];
}
- (void)tickCountdown {
    if(self.countdownDeadline<=0) { self.countdownLabel.stringValue=[self countdownText]; return; }
    NSInteger remaining=ws_countdown_remaining(self.countdownDeadline,NSProcessInfo.processInfo.systemUptime);
    if(remaining==self.countdownRemaining) return;
    self.countdownRemaining=remaining; self.countdownLabel.stringValue=[self countdownText];
    const BOOL waiting=self.sceneSelector.selectedSegment==0;
    if(remaining==0) {
        self.countdownDeadline=0;
        if(waiting && self.countdownAuto.state==NSControlStateValueOn) { self.sceneSelector.selectedSegment=1; [self applyScene]; return; }
    }
    if(waiting) [self applyScene];
}
- (void)changeSource:(id)sender {
    (void)sender; if(![self canEditPreparation]) return;
    NSInteger scene=self.sceneSelector.selectedSegment;
    if(scene<1 || scene>3) { [self.sourceMenu selectItemAtIndex:0]; return; }
    if(self.sourceMenu.indexOfSelectedItem==1 && !self.captureNames[scene].length) { [self.sourceMenu selectItemAtIndex:0]; [self selectCaptureWindow:nil]; return; }
    self.sourceModes[scene]=@(self.sourceMenu.indexOfSelectedItem);
    [self.engine setWindowCaptureEnabled:self.sourceModes[scene].boolValue scene:scene];
    [self invalidateReview]; [self applyScene];
}
- (void)changeLayout:(id)sender {
    (void)sender; if(![self canEditPreparation]) return;
    NSInteger scene=self.sceneSelector.selectedSegment;
    if(scene<1 || scene>3) return;
    self.sceneLayouts[scene]=@(self.layoutMenu.indexOfSelectedItem);
    [self.engine setCaptureLayout:self.layoutMenu.indexOfSelectedItem scene:scene];
    [self invalidateReview]; [self applyScene];
}
- (void)selectCaptureWindow:(id)sender {
    (void)sender; if(![self canEditPreparation] || !self.engine.ready) return;
    NSInteger scene=self.sceneSelector.selectedSegment;
    if(scene<1 || scene>3) { self.errorLabel.stringValue=WSL(@"찬양·설교·말씀 장면 중 하나를 선택하세요."); return; }
    if(!CGPreflightScreenCaptureAccess()) {
        CGRequestScreenCaptureAccess();
        self.errorLabel.stringValue=WSL(@"시스템 설정 → 개인정보 보호 및 보안 → 화면 및 시스템 오디오 녹음에서 허용하세요. 필요하면 앱을 다시 실행하세요.");
        return;
    }
    NSArray *windows=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly|kCGWindowListExcludeDesktopElements,kCGNullWindowID));
    NSPopUpButton *choices=[NSPopUpButton new]; [choices.widthAnchor constraintEqualToConstant:460].active=YES;
    for(NSDictionary *info in windows) {
        if([info[(NSString *)kCGWindowLayer] integerValue]!=0 || [info[(NSString *)kCGWindowOwnerPID] intValue]==NSProcessInfo.processInfo.processIdentifier) continue;
        NSString *owner=info[(NSString *)kCGWindowOwnerName] ?: WSL(@"앱");
        NSString *title=info[(NSString *)kCGWindowName] ?: @"";
        if(!title.length) continue;
        [choices addItemWithTitle:[NSString stringWithFormat:@"%@ — %@",owner,title]];
        choices.lastItem.representedObject=info[(NSString *)kCGWindowNumber];
    }
    if(!choices.numberOfItems) { self.errorLabel.stringValue=WSL(@"캡처할 창이 없습니다. PPT 슬라이드 쇼나 자료 창을 먼저 여세요."); return; }
    NSAlert *alert=[NSAlert new]; alert.messageText=WSL(@"이 장면에 사용할 자료 창");
    alert.informativeText=WSL(@"PPT는 슬라이드 쇼를 창 모드로 실행하세요. 선택한 창은 닫거나 최소화하지 마세요. 창 소리는 포함되지 않습니다.");
    NSStackView *form=column(@[choices]); form.frame=NSMakeRect(0,0,470,40); alert.accessoryView=form;
    [alert addButtonWithTitle:WSL(@"이 창 사용")]; [alert addButtonWithTitle:WSL(@"취소")];
    if([alert runModal]!=NSAlertFirstButtonReturn) return;
    if(![self.engine selectCaptureWindow:[choices.selectedItem.representedObject unsignedIntValue] scene:scene]) { [self reportFailure]; return; }
    self.captureNames[scene]=choices.selectedItem.title; self.sourceModes[scene]=@1;
    [self.engine setCaptureLayout:self.sceneLayouts[scene].integerValue scene:scene];
    [self invalidateReview]; [self applyScene];
}

- (void)selectLoopVideo:(id)sender {
    (void)sender; if(![self canEditPreparation] || !self.engine.ready) return;
    NSInteger scene=self.sceneSelector.selectedSegment; if(scene!=0 && scene!=4) return;
    NSOpenPanel *panel=[NSOpenPanel openPanel];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    panel.allowedFileTypes=@[@"mp4",@"mov",@"mkv",@"m4v"];
#pragma clang diagnostic pop
    panel.message=WSL(@"이 장면에서 반복할 로컬 영상을 선택하세요.");
    if([panel runModal]!=NSModalResponseOK) return;
    if(![self.engine setLoopMediaAtPath:panel.URL.path scene:scene]) { [self reportFailure]; return; }
    self.sceneVideos[scene]=panel.URL.path; self.sceneImages[scene]=@"";
    [NSUserDefaults.standardUserDefaults setObject:self.sceneImages forKey:@"WSSceneImagesV1"];
    [NSUserDefaults.standardUserDefaults setObject:self.sceneVideos forKey:@"WSSceneVideosV1"];
    [self invalidateReview]; [self applyScene];
}
- (void)selectBackgroundMusic:(id)sender {
    (void)sender; if(![self canEditPreparation] || !self.engine.ready) return;
    NSInteger scene=self.sceneSelector.selectedSegment; if(scene!=0 && scene!=4) return;
    NSOpenPanel *panel=[NSOpenPanel openPanel];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    panel.allowedFileTypes=@[@"mp3",@"m4a",@"wav",@"aac",@"flac"];
#pragma clang diagnostic pop
    panel.message=WSL(@"이 장면에서 반복할 배경 음악을 선택하세요. 기본 음량은 25%입니다.");
    if([panel runModal]!=NSModalResponseOK) return;
    if(![self.engine setBackgroundMusicAtPath:panel.URL.path scene:scene]) { [self reportFailure]; return; }
    self.sceneMusic[scene]=panel.URL.path;
    [NSUserDefaults.standardUserDefaults setObject:self.sceneMusic forKey:@"WSSceneMusicV1"];
    [self invalidateReview]; [self updateStudioStatus];
}
- (void)clearBackgroundMusic:(id)sender {
    (void)sender; if(![self canEditPreparation]) return;
    NSInteger scene=self.sceneSelector.selectedSegment; if(scene!=0 && scene!=4) return;
    [self.engine setBackgroundMusicAtPath:@"" scene:scene]; self.sceneMusic[scene]=@"";
    [NSUserDefaults.standardUserDefaults setObject:self.sceneMusic forKey:@"WSSceneMusicV1"];
    [self invalidateReview]; [self updateStudioStatus];
}
- (void)openBrowserSource:(id)sender {
    (void)sender; if(![self canEditPreparation]) return;
    NSAlert *alert=[NSAlert new]; alert.messageText=WSL(@"브라우저 자료 열기");
    alert.informativeText=WSL(@"자료 주소를 브라우저에서 연 다음 ‘캡처할 창 선택’으로 그 창을 골라주세요. 이 방식은 불투명한 창 영상만 가져옵니다. 브라우저 소리는 포함되지 않습니다.");
    NSTextField *address=[NSTextField textFieldWithString:@"https://"];
    address.frame=NSMakeRect(0,0,440,28); alert.accessoryView=address;
    [alert addButtonWithTitle:WSL(@"브라우저에서 열기")]; [alert addButtonWithTitle:WSL(@"취소")];
    if([alert runModal]!=NSAlertFirstButtonReturn) return;
    NSURL *url=[NSURL URLWithString:address.stringValue];
    if(!url.host.length || ![@[@"http",@"https"] containsObject:url.scheme.lowercaseString]) { self.errorLabel.stringValue=WSL(@"http 또는 https 웹 주소를 입력하세요."); return; }
    [NSWorkspace.sharedWorkspace openURL:url];
    self.captureLabel.stringValue=WSL(@"브라우저가 열리면 ‘캡처할 창 선택’에서 자료 창을 선택하세요.");
}
