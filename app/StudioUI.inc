// SPDX-License-Identifier: GPL-2.0-or-later
// Included inside AppDelegate's implementation. All controls call the native engine.
NS_ASSUME_NONNULL_BEGIN
- (NSStackView *)row:(NSArray<NSView *> *)views {
    NSStackView *stack=[NSStackView stackViewWithViews:views];
    stack.orientation=NSUserInterfaceLayoutOrientationHorizontal;
    stack.alignment=NSLayoutAttributeCenterY; stack.spacing=10;
    stack.distribution=NSStackViewDistributionFill;
    return stack;
}
- (NSView *)spacer {
    NSView *view=[NSView new];
    [view setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    return view;
}
- (NSStackView *)section:(NSString *)title views:(NSArray<NSView *> *)views {
    WSSectionStack *stack=[[WSSectionStack alloc] initWithFrame:NSZeroRect];
    stack.orientation=NSUserInterfaceLayoutOrientationVertical; stack.alignment=NSLayoutAttributeLeading;
    stack.spacing=10; stack.edgeInsets=NSEdgeInsetsMake(12,0,12,0);
    NSBox *divider=[NSBox new]; divider.boxType=NSBoxSeparator;
    [stack addArrangedSubview:divider];
    [divider.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active=YES;
    [stack addArrangedSubview:label(title,12,NSFontWeightSemibold)];
    for(NSView *view in views) [stack addArrangedSubview:view];
    return stack;
}
- (void)chooseSceneButton:(NSButton *)sender {
    self.sceneSelector.selectedSegment=sender.tag;
    [self changeScene:self.sceneSelector];
}
- (NSPopUpButton *)moreMenu:(NSString *)title entries:(NSArray<NSString *> *)titles actions:(NSArray<NSString *> *)actions {
    NSPopUpButton *menu=[[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:YES];
    [menu addItemWithTitle:title];
    for(NSUInteger i=0;i<titles.count;i++) {
        [menu addItemWithTitle:titles[i]]; menu.lastItem.target=self; menu.lastItem.action=NSSelectorFromString(actions[i]);
    }
    menu.font=[NSFont systemFontOfSize:13]; return menu;
}
- (void)fitSettingsColumn:(NSStackView *)stack {
    for(NSView *view in stack.arrangedSubviews) {
        BOOL vertical=[view isKindOfClass:NSStackView.class] && ((NSStackView *)view).orientation==NSUserInterfaceLayoutOrientationVertical;
        if([view isKindOfClass:NSTextField.class] || [view isKindOfClass:NSPopUpButton.class] || [view isKindOfClass:NSStackView.class] || [view isKindOfClass:WSActionButton.class]) [view.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-(stack.edgeInsets.left+stack.edgeInsets.right)].active=YES;
        if(vertical) [self fitSettingsColumn:(NSStackView *)view];
    }
}
- (void)buildStudioUI {
    self.window.title=@"Church OBS · 0.8.0";
    self.window.subtitle=WSL(@"1 준비 · 방송 전 점검");
    self.window.minSize=NSMakeSize(1120,800);
    self.window.titlebarAppearsTransparent=YES;
    self.window.appearance=[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    self.window.backgroundColor=[NSColor colorWithWhite:0.065 alpha:1];
    self.workspace=[WSStudioWorkspace new];
    self.workspace.wantsLayer=YES;
    self.workspace.layer.backgroundColor=[NSColor colorWithWhite:0.065 alpha:1].CGColor;
    self.modeTitle=label(WSL(@"예배 준비"),13,NSFontWeightSemibold);
    self.modeHint=label(WSL(@"연결하고, 화면을 고르면 준비 끝."),13,NSFontWeightRegular);
    self.modeHint.textColor=NSColor.secondaryLabelColor;
    self.modeButton=[self button:WSL(@"진행 모드") action:@selector(switchMode:)];
    ((WSActionButton *)self.modeButton).prominent=YES;
    self.preparationSteps=[NSSegmentedControl segmentedControlWithLabels:@[WSL(@"1  준비"),WSL(@"2  장면"),WSL(@"3  진행")] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(changePreparationStep:)];
    self.preparationSteps.selectedSegment=0;
    self.preparationSteps.font=[NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    self.preparationSteps.controlSize=NSControlSizeRegular;

    self.startButton=[self button:WSL(@"영상 엔진 시작") action:@selector(startEngine:)];
    self.cameraMenu=[NSPopUpButton new]; self.microphoneMenu=[NSPopUpButton new];
    self.cameraButton=[self button:WSL(@"카메라 연결") action:@selector(connectCamera:)];
    self.microphoneButton=[self button:WSL(@"마이크 연결") action:@selector(connectMicrophone:)];
    self.youtubeButton=[self button:WSL(@"YouTube 연결") action:@selector(connectYouTube:)];
    self.createBroadcastButton=[self button:WSL(@"새 예배…") action:@selector(createBroadcast:)];
    self.broadcastMenu=[NSPopUpButton new]; [self.broadcastMenu addItemWithTitle:WSL(@"계정 연결 후 예배 선택")];
    self.youtubeLabel=label(WSL(@"YouTube 계정을 연결하고 예배를 선택하세요."),12,NSFontWeightRegular);
    for(NSPopUpButton *menu in @[self.cameraMenu,self.microphoneMenu,self.broadcastMenu]) {
        menu.font=[NSFont systemFontOfSize:13]; menu.controlSize=NSControlSizeRegular;
    }
    self.connectionSummary=label(WSL(@"연결 상태 확인 중"),13,NSFontWeightMedium);
    self.deviceStatus=label(WSL(@"카메라 ○   마이크 ○   YouTube ○"),11,NSFontWeightMedium);
    self.cameraCheck=label(WSL(@"○ 연결 전"),12,NSFontWeightMedium);
    self.microphoneCheck=label(WSL(@"○ 연결 전"),12,NSFontWeightMedium);
    self.channelCheck=label(WSL(@"○ 연결 전"),12,NSFontWeightMedium);
    NSStackView *channelSection=[self section:WSL(@"방송 채널") views:@[self.channelCheck,self.youtubeButton,self.broadcastMenu,self.createBroadcastButton,self.youtubeLabel]];
    NSStackView *cameraSection=[self section:WSL(@"카메라") views:@[self.cameraCheck,self.cameraMenu,self.cameraButton]];
    NSStackView *microphoneSection=[self section:WSL(@"마이크") views:@[self.microphoneCheck,self.microphoneMenu,self.microphoneButton]];
    NSPopUpButton *connectionMore=[self moreMenu:WSL(@"추가 설정") entries:@[WSL(@"장치 목록 새로고침"),WSL(@"영상 엔진 시작"),WSL(@"YouTube 연결 해제")] actions:@[@"refreshDevices:",@"startEngine:",@"disconnectYouTube:"]];
    self.connectionPage=column(@[label(WSL(@"방송 전 점검"),20,NSFontWeightSemibold),self.connectionSummary,channelSection,cameraSection,microphoneSection,connectionMore,
      label(WSL(@"마이크 소리는 짧은 테스트 녹화로 확인하세요."),12,NSFontWeightRegular)]);


    self.sceneSelector=[NSSegmentedControl segmentedControlWithLabels:@[WSL(@"대기"),WSL(@"찬양"),WSL(@"설교"),WSL(@"말씀·자료"),WSL(@"종료")] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(changeScene:)];
    // Keep the existing selector as the single scene state; large buttons drive it.
    self.sceneSelector.selectedSegment=0;
    NSArray *sceneTitles=@[WSL(@"대기"),WSL(@"찬양"),WSL(@"설교"),WSL(@"말씀·자료"),WSL(@"종료")];
    NSArray *sceneCaptions=@[WSL(@"배경 · 음악 · 타이머"),WSL(@"카메라 · 찬양 자료"),WSL(@"카메라 · 설교 자료"),WSL(@"PPT · 화면 자료"),WSL(@"마침 화면 · 음악")];
    NSArray *sceneSymbols=@[@"clock",@"music.note",@"person.crop.rectangle",@"rectangle.on.rectangle",@"checkmark.circle"];
    NSMutableArray<WSSceneButton *> *buttons=[NSMutableArray new];
    for(NSInteger i=0;i<5;i++) {
        WSSceneButton *button=[[WSSceneButton alloc] initWithFrame:NSZeroRect];
        button.title=sceneTitles[i]; button.caption=sceneCaptions[i]; button.tag=i;
        button.target=self; button.action=@selector(chooseSceneButton:); button.bordered=YES;
        button.bezelStyle=NSBezelStyleRegularSquare;
        button.font=[NSFont systemFontOfSize:14 weight:NSFontWeightMedium];
        NSImage *symbol=[NSImage imageWithSystemSymbolName:sceneSymbols[i] accessibilityDescription:sceneTitles[i]];
        button.image=[symbol imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:24 weight:NSFontWeightRegular]];
        button.imagePosition=NSImageLeft; button.cell.wraps=YES;
        [button.widthAnchor constraintGreaterThanOrEqualToConstant:110].active=YES;
        [button setButtonType:NSButtonTypeToggle];
        button.keyEquivalent=[NSString stringWithFormat:@"%ld",(long)i+1]; button.keyEquivalentModifierMask=NSEventModifierFlagCommand;
        button.toolTip=[NSString stringWithFormat:WSL(@"%@ 장면 · ⌘%ld"),sceneTitles[i],(long)i+1];
        button.accessibilityLabel=[NSString stringWithFormat:WSL(@"%@ 장면"),sceneTitles[i]];
        [button.heightAnchor constraintEqualToConstant:96].active=YES;
        [buttons addObject:button];
    }
    self.sceneButtons=buttons;
    self.sceneDock=[self row:buttons]; self.sceneDock.distribution=NSStackViewDistributionFillEqually; self.sceneDock.spacing=10; self.sceneDock.edgeInsets=NSEdgeInsetsMake(4,0,4,0);
    
    NSMutableArray<WSSceneButton *> *sidebarButtons=[NSMutableArray new];
    for(NSInteger i=0;i<5;i++) {
        WSSceneButton *item=[[WSSceneButton alloc] initWithFrame:NSZeroRect];
        item.title=sceneTitles[i]; item.caption=sceneCaptions[i]; item.tag=i;
        item.target=self; item.action=@selector(chooseSceneButton:);
        item.bordered=YES; item.bezelStyle=NSBezelStyleRegularSquare;
        [item setButtonType:NSButtonTypeToggle];
        item.image=[NSImage imageWithSystemSymbolName:sceneSymbols[i] accessibilityDescription:sceneTitles[i]];
        item.imagePosition=NSImageLeft; item.cell.wraps=YES;
        item.keyEquivalent=[NSString stringWithFormat:@"%ld",(long)i+1];
        item.keyEquivalentModifierMask=NSEventModifierFlagCommand;
        item.accessibilityLabel=[NSString stringWithFormat:WSL(@"%@ 장면 편집"),sceneTitles[i]];
        [item.heightAnchor constraintEqualToConstant:68].active=YES;
        [sidebarButtons addObject:item];
    }
    self.sidebarButtons=sidebarButtons;
    NSView *sidebarSpace=[NSView new];
    [sidebarSpace setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationVertical];
    NSMutableArray<NSView *> *sidebarViews=[NSMutableArray arrayWithObject:label(WSL(@"장면"),13,NSFontWeightSemibold)];
    [sidebarViews addObjectsFromArray:sidebarButtons];
    [sidebarViews addObject:label(WSL(@"⌘1–5로 선택\n카메라와 자료를 조합하세요."),11,NSFontWeightRegular)];
    [sidebarViews addObject:sidebarSpace];
    self.sceneSidebar=column(sidebarViews); self.sceneSidebar.spacing=10;
    [self fitSettingsColumn:self.sceneSidebar];
    self.sceneNameLabel=label(WSL(@"방송 대기"),13,NSFontWeightSemibold);
    self.outputBadge=label(WSL(@"준비 미리보기"),12,NSFontWeightMedium);
    self.outputBadge.textColor=NSColor.secondaryLabelColor;
    self.preview=[WSPreviewView new];
    __weak AppDelegate *weakSelf=self;
    self.preview.sizeChanged=^(NSView *view) { [weakSelf.engine resizePreview:view]; };
    self.programPreview=[WSPreviewView new];
    self.programPreview.sizeChanged=^(NSView *view) { [weakSelf.engine resizeProgram:view]; };
    self.programPreview.windowChanged=^(NSView *view) { if(view.window) [weakSelf.engine attachProgramView:view]; };
    NSView *screen=[NSView new]; screen.wantsLayer=YES;
    screen.layer.backgroundColor=NSColor.blackColor.CGColor;
    screen.layer.cornerRadius=0;
    [screen addSubview:self.preview];
    self.preview.frame=screen.bounds;
    self.preview.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
    self.errorLabel=label(@"",12,NSFontWeightRegular); self.errorLabel.textColor=NSColor.systemOrangeColor;
    self.statusLabel=label(WSL(@"영상 엔진을 시작하고 있습니다…"),11,NSFontWeightRegular);
    self.statusLabel.textColor=NSColor.secondaryLabelColor;
    NSStackView *screenHeader=[self row:@[self.sceneNameLabel,[self spacer],self.outputBadge]];
    WSVideoStage *stage=[WSVideoStage new];
    stage.header=screenHeader; stage.screen=screen; stage.errorLabel=self.errorLabel;
    for(NSView *view in @[screenHeader,screen,self.errorLabel]) [stage addSubview:view];

    self.beautySelector=[NSSegmentedControl segmentedControlWithLabels:@[WSL(@"끔"),WSL(@"자연스럽게"),WSL(@"조금 더")] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(changeBeauty:)];
    self.beautySelector.selectedSegment=0;
    self.beautySelector.font=[NSFont systemFontOfSize:13];
    self.compareButton=[NSButton checkboxWithTitle:WSL(@"원본과 보정 나란히 비교") target:self action:@selector(changeComparison:)];
    self.faceGuideButton=[NSButton checkboxWithTitle:WSL(@"얼굴 위치 표시") target:self action:@selector(changeFaceGuide:)];
    self.beautyStatusLabel=label(WSL(@"카메라 연결 후 사용할 수 있습니다."),11,NSFontWeightRegular);
    self.strengthSlider=[self beautySlider:0]; self.skinSlider=[self beautySlider:65];
    self.shapeSlider=[self beautySlider:25]; self.eyeSlider=[self beautySlider:20]; self.browSlider=[self beautySlider:35];
    self.detailControls=column(@[self.compareButton,label(WSL(@"피부"),12,NSFontWeightMedium),self.skinSlider,label(WSL(@"얼굴형"),12,NSFontWeightMedium),self.shapeSlider,
      label(WSL(@"눈매"),12,NSFontWeightMedium),self.eyeSlider,label(WSL(@"눈썹"),12,NSFontWeightMedium),self.browSlider,self.faceGuideButton]);
    self.detailControls.hidden=YES; self.detailControls.spacing=5;
    NSButton *details=[NSButton checkboxWithTitle:WSL(@"비교 · 세부 조절") target:self action:@selector(toggleBeautyDetails:)];
    NSButton *edit=[self button:WSL(@"문구·가사 편집…") action:@selector(editScene:)];
    NSButton *material=[self button:WSL(@"자료 사진 선택…") action:@selector(selectMaterial:)];
    NSButton *clear=[self button:WSL(@"자료 사진 해제") action:@selector(clearMaterial:)];
    self.sourceMenu=[NSPopUpButton new];
    [self.sourceMenu addItemsWithTitles:@[WSL(@"카메라 · 문구"),WSL(@"PPT · 브라우저 창")]];
    self.sourceMenu.target=self; self.sourceMenu.action=@selector(changeSource:);
    self.layoutMenu=[NSPopUpButton new];
    [self.layoutMenu addItemsWithTitles:@[WSL(@"자료를 전체 화면으로"),WSL(@"자료 위에 작은 카메라"),WSL(@"자료와 카메라를 나란히")]];
    self.layoutMenu.target=self; self.layoutMenu.action=@selector(changeLayout:);
    for(NSPopUpButton *menu in @[self.sourceMenu,self.layoutMenu]) {
        menu.font=[NSFont systemFontOfSize:13]; menu.controlSize=NSControlSizeRegular;
    }
    self.captureLabel=label(WSL(@"찬양·설교·말씀 장면마다 자료 창을 지정할 수 있습니다."),11,NSFontWeightRegular);
    NSButton *capture=[self button:WSL(@"PPT·자료 창 선택…") action:@selector(selectCaptureWindow:)];
    self.countdownMinutes=[NSTextField textFieldWithString:@"5"];
    [self.countdownMinutes.widthAnchor constraintEqualToConstant:70].active=YES;
    self.countdownMinutes.font=[NSFont monospacedDigitSystemFontOfSize:15 weight:NSFontWeightMedium];
    self.countdownMinutes.alignment=NSTextAlignmentCenter;
    [self.countdownMinutes.heightAnchor constraintEqualToConstant:28].active=YES;
    self.countdownMinutes.target=self; self.countdownMinutes.action=@selector(configureCountdown:);
    self.countdownAuto=[NSButton checkboxWithTitle:WSL(@"0초에 찬양으로 전환") target:self action:@selector(configureCountdown:)];
    self.countdownAuto.state=[[NSUserDefaults standardUserDefaults] boolForKey:@"WSCountdownAuto"] ? NSControlStateValueOn : NSControlStateValueOff;
    NSInteger minutes=[NSUserDefaults.standardUserDefaults integerForKey:@"WSCountdownMinutes"];
    self.countdownMinutes.integerValue=minutes>0 ? std::clamp<NSInteger>(minutes,1,180) : 5;
    self.countdownRemaining=self.countdownMinutes.integerValue*60;
    NSButton *browser=[self button:WSL(@"웹 자료 열기…") action:@selector(openBrowserSource:)];
    self.materialRow=[self row:@[material,clear]];
    self.materialRow.distribution=NSStackViewDistributionFillEqually;
    self.captureOptions=column(@[label(WSL(@"카메라와 자료 배치"),12,NSFontWeightMedium),self.layoutMenu]); self.captureOptions.spacing=8;
    self.captureTools=[self section:WSL(@"화면 자료") views:@[self.sourceMenu,capture,browser,self.captureOptions,self.captureLabel,self.materialRow]];
    NSButton *photo=[self button:WSL(@"사진…") action:@selector(selectMaterial:)];
    NSButton *video=[self button:WSL(@"반복 영상…") action:@selector(selectLoopVideo:)];
    NSButton *music=[self button:WSL(@"배경 음악 선택…") action:@selector(selectBackgroundMusic:)];
    NSPopUpButton *mediaMore=[self moreMenu:WSL(@"배경 관리") entries:@[WSL(@"사진·영상 해제"),WSL(@"음악 해제")] actions:@[@"clearMaterial:",@"clearBackgroundMusic:"]];
    self.mediaLabel=label(WSL(@"사진 또는 영상을 선택하세요. 영상과 음악은 반복됩니다."),11,NSFontWeightRegular);
    NSStackView *backgroundChoice=[self row:@[photo,video]]; backgroundChoice.distribution=NSStackViewDistributionFillEqually;
    self.mediaTools=[self section:WSL(@"배경과 음악") views:@[backgroundChoice,music,self.mediaLabel,mediaMore]];
    self.countdownSettings=[self section:WSL(@"예배 시작까지") views:@[[self row:@[self.countdownMinutes,label(WSL(@"분 후 시작"),14,NSFontWeightRegular)]],self.countdownAuto]];
    self.beautySettings=[self section:WSL(@"자연 보정") views:@[self.beautySelector,label(WSL(@"보정 강도"),12,NSFontWeightMedium),self.strengthSlider,details,self.detailControls,self.beautyStatusLabel]];
    self.layerSummary=label(WSL(@"장면을 선택하세요."),12,NSFontWeightRegular);
    NSStackView *layers=[self section:WSL(@"이 장면의 레이어 · 위가 앞") views:@[self.layerSummary]];
    self.scenePage=column(@[label(WSL(@"소스와 보정"),17,NSFontWeightSemibold),
      label(WSL(@"장면은 왼쪽에서, 화면 배치는 아래에서 선택하세요."),12,NSFontWeightRegular),layers,edit,self.captureTools,self.mediaTools,self.countdownSettings,self.beautySettings]);
    self.reviewLabel=label(@"",13,NSFontWeightRegular);
    self.reviewCheck=[NSButton checkboxWithTitle:WSL(@"화면과 소리를 모두 확인했어요") target:self action:@selector(reviewChanged:)];
    self.reviewPage=column(@[label(WSL(@"진행 전 마지막 확인"),20,NSFontWeightSemibold),self.reviewLabel,self.reviewCheck,
      label(WSL(@"진행 화면에서는 설정이 잠깁니다.\n방송을 시작하기 전까지 YouTube에 송출되지 않습니다."),12,NSFontWeightRegular)]);
    self.nextStepButton=[self button:WSL(@"장면 준비 →") action:@selector(nextPreparationStep:)];
    ((WSActionButton *)self.nextStepButton).prominent=YES;
    self.settingsStack=column(@[self.connectionPage,self.scenePage,self.reviewPage,self.nextStepButton]);
    [self.nextStepButton.widthAnchor constraintEqualToAnchor:self.settingsStack.widthAnchor].active=YES;
    self.settingsStack.translatesAutoresizingMaskIntoConstraints=NO;
    self.settingsScroll=[NSScrollView new]; self.settingsScroll.hasVerticalScroller=YES;
    self.settingsScroll.drawsBackground=YES; self.settingsScroll.backgroundColor=NSColor.windowBackgroundColor; self.settingsScroll.autohidesScrollers=YES;
    NSView *document=[WSFlippedView new]; document.translatesAutoresizingMaskIntoConstraints=NO; self.settingsScroll.documentView=document;
    [document addSubview:self.settingsStack];
    [NSLayoutConstraint activateConstraints:@[[self.settingsStack.leadingAnchor constraintEqualToAnchor:document.leadingAnchor constant:16],
      [self.settingsStack.trailingAnchor constraintEqualToAnchor:document.trailingAnchor constant:-16],
      [self.settingsStack.topAnchor constraintEqualToAnchor:document.topAnchor constant:16],
      [self.settingsStack.bottomAnchor constraintEqualToAnchor:document.bottomAnchor constant:-16],
      [document.widthAnchor constraintEqualToAnchor:self.settingsScroll.contentView.widthAnchor]]];
    for(NSStackView *page in @[self.connectionPage,self.scenePage,self.reviewPage]) {
        [page.widthAnchor constraintEqualToAnchor:self.settingsStack.widthAnchor].active=YES;
        [self fitSettingsColumn:page];
    }
    self.muteButton=[self button:WSL(@"마이크 켜짐") action:@selector(toggleMute:)];
    [self.muteButton setButtonType:NSButtonTypeToggle];
    self.muteButton.toolTip=WSL(@"클릭하여 마이크 음소거 / 해제");
    self.recordButton=[self button:WSL(@"녹화 시작…") action:@selector(toggleRecording:)];
    self.recordLabel=label(WSL(@"로컬 녹화 대기"),11,NSFontWeightRegular);
    self.recordLabel.textColor=NSColor.secondaryLabelColor;
    self.broadcastButton=[self button:WSL(@"방송 시작") action:@selector(toggleBroadcast:)];
    self.broadcastButton.bezelColor=NSColor.systemGreenColor;
    ((WSActionButton *)self.broadcastButton).prominent=YES;
    [self.broadcastButton.widthAnchor constraintGreaterThanOrEqualToConstant:132].active=YES;
    self.broadcastStatusButton=[self button:WSL(@"방송 확인") action:@selector(checkBroadcast:)];
    self.countdownButton=[self button:WSL(@"카운트다운 시작") action:@selector(toggleCountdown:)];
    self.countdownResetButton=[self button:WSL(@"초기화") action:@selector(resetCountdown:)];
    self.countdownLabel=label(@"05:00",16,NSFontWeightSemibold);
    self.countdownRow=[self row:@[self.countdownLabel,self.countdownButton,self.countdownResetButton]];
    self.nextSceneButton=[self button:WSL(@"다음 장면 → 찬양") action:@selector(advanceScene:)];
    self.nextSceneButton.keyEquivalent=@" "; self.nextSceneButton.keyEquivalentModifierMask=0;
    NSStackView *footer=[self row:@[self.muteButton,self.recordButton,self.broadcastStatusButton,[self spacer],self.nextSceneButton,self.broadcastButton]];
    self.broadcastFeedback=label(@"",12,NSFontWeightMedium);
    self.broadcastFeedback.maximumNumberOfLines=2;
    self.performanceStatus=label(WSL(@"방송 준비"),12,NSFontWeightMedium);
    NSStackView *bottom=[self row:@[self.statusLabel,[self spacer],self.performanceStatus]];
    NSStackView *statusArea=column(@[self.broadcastFeedback,self.recordLabel,bottom]);
    statusArea.edgeInsets=NSEdgeInsetsMake(0,16,8,16); statusArea.spacing=4;
    for(NSView *view in @[self.broadcastFeedback,self.recordLabel,bottom]) [view.widthAnchor constraintEqualToAnchor:statusArea.widthAnchor constant:-32].active=YES;
    self.workspace.stage=stage; self.workspace.inspector=self.settingsScroll;
    self.workspace.sidebar=self.sceneSidebar; self.workspace.scenes=self.sceneDock;
    self.workspace.countdown=self.countdownRow; self.workspace.footer=footer; self.workspace.status=statusArea;
    for(NSView *view in @[stage,self.settingsScroll,self.sceneSidebar,self.sceneDock,self.countdownRow,footer,statusArea]) {
        view.translatesAutoresizingMaskIntoConstraints=YES;
        [self.workspace addSubview:view];
    }
    self.window.contentView=self.workspace;
    [self.workspace refreshLayout];
    self.recordLabel.maximumNumberOfLines=1;
    for(NSButton *check in @[self.reviewCheck,self.countdownAuto,self.compareButton,self.faceGuideButton,details]) check.font=[NSFont systemFontOfSize:13];
    NSToolbar *toolbar=[[NSToolbar alloc] initWithIdentifier:@"ChurchOBS.MainToolbar"];
    toolbar.delegate=self; toolbar.allowsUserCustomization=NO; toolbar.displayMode=NSToolbarDisplayModeIconOnly;
    self.window.toolbarStyle=NSWindowToolbarStyleUnifiedCompact;
    self.window.toolbar=toolbar;
    [self changePreparationStep:self.preparationSteps];
}
- (BOOL)canEditPreparation {
    return !self.performanceMode && !self.engine.recording && !self.engine.stopping && !self.engine.streaming && !self.activeBroadcastID.length && !self.youtube.busy && !self.broadcastAction;
}
- (void)invalidateReview {
    self.reviewCheck.state=NSControlStateValueOff;
}
- (void)changePreparationStep:(NSSegmentedControl *)sender {
    if(self.performanceMode) { sender.selectedSegment=2; return; }
    NSInteger step=sender.selectedSegment;
    self.connectionPage.hidden=step!=0; self.scenePage.hidden=step!=1; self.reviewPage.hidden=step!=2;
    self.nextStepButton.title=step==0 ? WSL(@"장면 편집으로 →") : step==1 ? WSL(@"진행 전 확인 →") : WSL(@"확인 완료 · 진행 화면으로 →");
    self.workspace.page=step;
    [self.workspace refreshLayout];
    [self.settingsScroll.contentView scrollToPoint:NSMakePoint(0,0)];
    [self updateStudioStatus];
}
- (void)advanceScene:(id _Nullable)sender {
    (void)sender;
    if(!self.performanceMode || !self.engine.ready) return;
    NSInteger next=self.sceneSelector.selectedSegment+1;
    if(next>=5) return;
    self.sceneSelector.selectedSegment=next; [self changeScene:self.sceneSelector];
}
- (void)nextPreparationStep:(id _Nullable)sender {
    (void)sender;
    if(self.preparationSteps.selectedSegment<2) { self.preparationSteps.selectedSegment++; [self changePreparationStep:self.preparationSteps]; }
    else [self switchMode:nil];
}
- (void)reviewChanged:(id _Nullable)sender { (void)sender; [self updateStudioStatus]; }
- (void)switchMode:(id _Nullable)sender {
    (void)sender;
    if(self.engine.recording || self.engine.stopping || self.engine.streaming || self.activeBroadcastID.length || self.youtube.busy || self.broadcastAction) {
        self.errorLabel.stringValue=WSL(@"방송·녹화·연결 작업을 마친 뒤 화면을 바꿀 수 있습니다."); return;
    }
    if(!self.performanceMode && (self.preparationSteps.selectedSegment!=2 || self.reviewCheck.state!=NSControlStateValueOn)) {
        self.preparationSteps.selectedSegment=2; [self changePreparationStep:self.preparationSteps];
        self.errorLabel.stringValue=WSL(@"5개 장면과 소리를 확인한 뒤 확인란을 선택하세요."); return;
    }
    if(!self.performanceMode && !self.engine.ready) { self.errorLabel.stringValue=WSL(@"영상 엔진을 먼저 시작하세요."); return; }
    self.performanceMode=!self.performanceMode;
    self.workspace.performance=self.performanceMode;
    self.preparationSteps.selectedSegment=self.performanceMode ? 2 : 1;
    self.workspace.page=self.preparationSteps.selectedSegment;
    self.preparationSteps.enabled=!self.performanceMode;
    [self.workspace refreshLayout];
    ((WSActionButton *)self.modeButton).prominent=!self.performanceMode;
    self.errorLabel.stringValue=@"";
    if(self.performanceMode) {
        self.compareButton.state=self.faceGuideButton.state=NSControlStateValueOff;
        [self.engine setBeautyComparison:NO]; [self.engine setFaceGuide:NO];
        self.sceneSelector.selectedSegment=0; [self resetCountdown:nil]; [self applyScene];
    } else { [self invalidateReview]; [self changePreparationStep:self.preparationSteps]; }
    [self.window.contentView layoutSubtreeIfNeeded]; [self.engine resizePreview:self.preview];
    [self updateStatus:nil];
}
- (void)updateStudioStatus {
    self.workspace.performance=self.performanceMode;
    self.workspace.page=self.performanceMode ? 2 : self.preparationSteps.selectedSegment;
    self.window.subtitle=self.performanceMode ? WSL(@"3 진행 · 예배 진행") : self.workspace.page==0 ? WSL(@"1 준비 · 방송 전 점검") : self.workspace.page==1 ? WSL(@"2 장면 · 화면 편집") : WSL(@"3 진행 · 송출 전 확인");
    self.modeButton.title=self.performanceMode ? WSL(@"장면 편집") : WSL(@"진행 화면으로 →");
    self.preparationSteps.enabled=!self.performanceMode;
    NSInteger connected=(self.engine.hasCamera?1:0)+(self.engine.hasMicrophone?1:0)+(self.youtubeConnected?1:0);
    self.connectionSummary.stringValue=[NSString stringWithFormat:WSL(@"%ld / 3 연결됨 · 장면 편집 후 화면과 소리를 확인하세요."),(long)connected];
    self.deviceStatus.stringValue=[NSString stringWithFormat:WSL(@"카메라 %@   마이크 %@   YouTube %@"),self.engine.hasCamera?@"●":@"○",self.engine.hasMicrophone?@"●":@"○",self.youtubeConnected?@"●":@"○"];
    self.cameraCheck.stringValue=self.engine.hasCamera ? WSL(@"● 영상 연결됨") : WSL(@"○ 카메라를 연결하세요");
    self.microphoneCheck.stringValue=self.engine.hasMicrophone ? WSL(@"● 마이크 연결됨 · 소리는 녹화로 확인") : WSL(@"○ 마이크를 연결하세요");
    self.channelCheck.stringValue=self.youtubeConnected ? WSL(@"● 계정 연결됨 · 예배를 선택하세요") : WSL(@"○ YouTube 계정을 연결하세요");
    self.cameraCheck.textColor=self.engine.hasCamera ? NSColor.systemGreenColor : NSColor.secondaryLabelColor;
    self.microphoneCheck.textColor=self.engine.hasMicrophone ? NSColor.systemGreenColor : NSColor.secondaryLabelColor;
    self.channelCheck.textColor=self.youtubeConnected ? NSColor.systemGreenColor : NSColor.secondaryLabelColor;
    const BOOL active=self.activeBroadcastID.length || self.engine.streaming || self.broadcastAction;
    self.broadcastButton.hidden=!self.performanceMode && !active;
    self.broadcastFeedback.hidden=!self.performanceMode && !active;
    self.broadcastFeedback.stringValue=self.youtubeLabel.stringValue;
    self.broadcastFeedback.textColor=self.isLive && self.engine.streamConnected ? NSColor.systemGreenColor : NSColor.labelColor;
    self.broadcastStatusButton.hidden=!active || (self.isLive && self.engine.streamConnected && [self.youtubeLabel.stringValue hasPrefix:@"● "]);
    self.modeButton.enabled=!active && !self.engine.recording && !self.engine.stopping && !self.youtube.busy;
    self.nextStepButton.enabled=self.preparationSteps.selectedSegment!=2 || self.reviewCheck.state==NSControlStateValueOn;
    self.performanceStatus.stringValue=self.isLive ? WSL(@"● YouTube 방송 중") : active ? WSL(@"YouTube 연결·상태 확인 중") : self.performanceMode ? WSL(@"진행 화면 · 방송 전") : WSL(@"준비 중");
    self.performanceStatus.textColor=self.isLive ? NSColor.systemRedColor : NSColor.secondaryLabelColor;
    self.outputBadge.stringValue=self.isLive ? WSL(@"실제 송출") : active ? WSL(@"송출 연결 확인 중") : self.performanceMode ? WSL(@"방송 미리보기") : WSL(@"준비 미리보기");
    NSArray *names=@[WSL(@"방송 대기"),WSL(@"찬양"),WSL(@"설교"),WSL(@"말씀·자료"),WSL(@"예배 종료")];
    NSInteger scene=self.sceneSelector.selectedSegment;
    if(scene>=0 && scene<5) self.sceneNameLabel.stringValue=names[scene];
    self.reviewLabel.stringValue=[NSString stringWithFormat:WSL(@"%@ 영상 엔진\n%@ 카메라\n%@ 마이크\n%@ YouTube 계정\n\n선택한 예배: %@\n\n대기 → 찬양 → 설교 → 말씀·자료 → 종료\n각 장면은 장면 편집 단계에서 직접 확인하세요."),self.engine.ready ? @"✓" : @"○",self.engine.hasCamera ? @"✓" : @"○",self.engine.hasMicrophone ? @"✓" : @"○",self.youtubeConnected ? @"✓" : @"○",self.broadcastMenu.selectedItem.title ?: WSL(@"미선택")];
    NSArray *buttonNames=@[WSL(@"대기"),WSL(@"찬양"),WSL(@"설교"),WSL(@"말씀·자료"),WSL(@"종료")];
    NSArray *allButtons=[self.sceneButtons arrayByAddingObjectsFromArray:self.sidebarButtons];
    for(WSSceneButton *button in allButtons) {
        NSControlStateValue state=button.tag==scene ? NSControlStateValueOn : NSControlStateValueOff;
        NSString *prefix=state==NSControlStateValueOn ? (self.performanceMode ? @"● " : @"✓ ") : @"";
        NSString *title=[NSString stringWithFormat:@"%@%@\n%@",prefix,buttonNames[button.tag],button.caption];
        if(button.state!=state || button.enabled!=self.sceneSelector.enabled || ![button.attributedTitle.string isEqualToString:title]) {
            button.state=state; button.enabled=self.sceneSelector.enabled;
            button.bezelColor=state==NSControlStateValueOn ? NSColor.controlAccentColor : nil;
            NSMutableParagraphStyle *paragraph=[NSMutableParagraphStyle new];
            paragraph.alignment=NSTextAlignmentLeft; paragraph.lineBreakMode=NSLineBreakByWordWrapping;
            NSMutableAttributedString *text=[[NSMutableAttributedString alloc] initWithString:title attributes:@{NSFontAttributeName:[NSFont systemFontOfSize:12 weight:NSFontWeightMedium],NSForegroundColorAttributeName:NSColor.secondaryLabelColor,NSParagraphStyleAttributeName:paragraph}];
            NSRange headline=[title rangeOfString:@"\n"];
            [text addAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:15 weight:NSFontWeightSemibold],NSForegroundColorAttributeName:NSColor.labelColor} range:NSMakeRange(0,headline.location)];
            button.attributedTitle=text;
        }
    }
    self.nextSceneButton.hidden=!self.performanceMode;
    self.nextSceneButton.enabled=self.sceneSelector.enabled && scene>=0 && scene<4;
    self.nextSceneButton.title=scene>=0 && scene<4 ? [NSString stringWithFormat:WSL(@"다음 장면 → %@"),buttonNames[scene+1]] : WSL(@"마지막 장면");
    self.countdownRow.hidden=scene!=0 || (!self.performanceMode && self.preparationSteps.selectedSegment!=1);
    self.countdownSettings.hidden=scene!=0;
    self.materialRow.hidden=scene!=3;
    BOOL hasCapture=scene>=0 && scene<5 && self.sourceModes[scene].boolValue;
    self.captureOptions.hidden=!hasCapture;
    self.captureLabel.hidden=!hasCapture;
    self.errorLabel.hidden=!self.errorLabel.stringValue.length;
    self.beautySettings.hidden=!(scene==1 || scene==2 || (scene==3 && hasCapture)) || (hasCapture && self.sceneLayouts[scene].integerValue==0);
    self.statusLabel.hidden=self.engine.ready && !self.engine.lastError.length;
    self.recordLabel.hidden=!self.engine.recordingPath.length;
    self.muteButton.title=!self.engine.hasMicrophone ? WSL(@"마이크 미연결") : self.muteButton.state==NSControlStateValueOn ? WSL(@"마이크 꺼짐") : WSL(@"마이크 켜짐");
    self.muteButton.bezelColor=NSColor.systemRedColor;
    self.muteButton.needsDisplay=YES;
    self.broadcastButton.bezelColor=self.activeBroadcastID.length ? NSColor.systemRedColor : NSColor.systemGreenColor;
    self.broadcastButton.needsDisplay=YES;
    self.captureTools.hidden=scene==0 || scene==4;
    self.mediaTools.hidden=scene!=0 && scene!=4;
    if(scene>=0 && scene<5) self.mediaLabel.stringValue=[NSString stringWithFormat:WSL(@"배경: %@\n음악: %@"),self.sceneVideos[scene].length ? self.sceneVideos[scene].lastPathComponent : self.sceneImages[scene].length ? self.sceneImages[scene].lastPathComponent : WSL(@"기본 화면"),self.sceneMusic[scene].length ? self.sceneMusic[scene].lastPathComponent : WSL(@"없음")];
    self.countdownButton.enabled=self.engine.ready && self.countdownRemaining>0;
    self.countdownButton.title=self.countdownDeadline ? WSL(@"일시 정지") : self.countdownRemaining>0 ? WSL(@"카운트다운 시작") : WSL(@"카운트다운 완료");
    self.countdownResetButton.enabled=self.engine.ready;
    self.sourceMenu.enabled=self.layoutMenu.enabled=[self canEditPreparation] && scene>=1 && scene<=3;
    self.countdownMinutes.enabled=self.countdownAuto.enabled=[self canEditPreparation];
    if(scene==0 || scene==4) {
        self.layerSummary.stringValue=[NSString stringWithFormat:@"%@%@\n%@",scene==0 && self.countdownVisible ? WSL(@"① 카운트다운\n") : @"",self.sceneVideos[scene].length ? WSL(@"배경 영상 · 반복") : self.sceneImages[scene].length ? WSL(@"배경 사진") : WSL(@"기본 안내 화면"),self.sceneMusic[scene].length ? WSL(@"배경 음악 · 반복") : WSL(@"배경 음악 없음")];
    } else if(scene>=1 && scene<=3) {
        NSString *camera=self.engine.hasCamera ? WSL(@"카메라 · 인물 보정") : WSL(@"카메라 미연결");
        NSString *microphone=self.engine.hasMicrophone ? WSL(@"강단 마이크") : WSL(@"마이크 미연결");
        if(hasCapture) {
            NSString *video=self.sceneLayouts[scene].integerValue==0 ? @"" : [camera stringByAppendingString:@"\n"];
            self.layerSummary.stringValue=[NSString stringWithFormat:WSL(@"%@자료 창 · %@\n%@"),video,self.captureNames[scene].length ? self.captureNames[scene] : WSL(@"선택 전"),microphone];
        } else {
            self.layerSummary.stringValue=scene==3 ? [NSString stringWithFormat:@"%@\n%@",self.sceneImages[scene].length ? WSL(@"자료 사진") : WSL(@"말씀 · 자료 문구"),microphone] : [NSString stringWithFormat:WSL(@"문구 · 가사\n%@\n%@"),camera,microphone];
        }
    }
    [self.workspace refreshLayout];
    self.workspace.stage.needsLayout=YES;
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar {
    (void)toolbar; return @[@"ChurchOBS.Workflow",NSToolbarFlexibleSpaceItemIdentifier,@"ChurchOBS.State",@"ChurchOBS.Mode"];
}
- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar {
    return [self toolbarAllowedItemIdentifiers:toolbar];
}
- (NSToolbarItem * _Nullable)toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSToolbarItemIdentifier)identifier willBeInsertedIntoToolbar:(BOOL)flag {
    (void)toolbar; (void)flag;
    NSToolbarItem *item=[[NSToolbarItem alloc] initWithItemIdentifier:identifier];
    if([identifier isEqualToString:@"ChurchOBS.Workflow"]) {
        item.label=WSL(@"예배 준비"); item.view=self.preparationSteps; return item;
    }
    if([identifier isEqualToString:@"ChurchOBS.State"]) { item.label=WSL(@"연결 상태"); item.view=self.deviceStatus; return item; }
    if([identifier isEqualToString:@"ChurchOBS.Mode"]) {
        item.label=WSL(@"준비·진행 모드 전환"); item.view=self.modeButton; return item;
    }
    return nil;
}

NS_ASSUME_NONNULL_END
