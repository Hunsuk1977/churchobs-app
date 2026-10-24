// SPDX-License-Identifier: GPL-2.0-or-later
// Runs in the compiled Mac app without requesting camera/microphone permissions.
- (BOOL)verifyWorkspaceGeometry {
    [self.window.contentView layoutSubtreeIfNeeded];
    WSLayoutFrames f=ws_studio_layout(self.workspace.bounds.size.width,self.workspace.bounds.size.height,(int)self.workspace.page,self.performanceMode,!self.countdownRow.hidden);
    CGFloat errorHeight=self.errorLabel.hidden ? 0 : 42;
    if(std::abs(self.preview.bounds.size.width-f.stage.width)>2 || std::abs(self.preview.bounds.size.height-(f.stage.height-36-errorHeight))>2) {
        fprintf(stderr,"FAIL workspace preview geometry: actual=%.0fx%.0f expected=%.0fx%.0f\n",self.preview.bounds.size.width,self.preview.bounds.size.height,f.stage.width,f.stage.height-36-errorHeight); return NO;
    }
    if(!self.settingsScroll.hidden && (std::abs(self.settingsScroll.frame.origin.x-f.inspector.x)>2 || std::abs(self.settingsScroll.bounds.size.width-f.inspector.width)>2)) {
        fprintf(stderr,"FAIL workspace inspector geometry\n"); return NO;
    }
    return YES;
}
- (int)verifyStudioUI {
    [self startEngine:nil];
    if(!self.engine.ready) { fprintf(stderr,"FAIL UI engine initialization: %s\n",self.engine.lastError.UTF8String); return 20; }
    [self.window setContentSize:NSMakeSize(1120,800)];
    [self.window.contentView layoutSubtreeIfNeeded];
    if(self.preview.bounds.size.width<500 || self.preview.bounds.size.height<250 || self.settingsScroll.bounds.size.width<300) {
        fprintf(stderr,"FAIL native UI minimum-window layout: preview=%.0fx%.0f settings=%.0f\n",self.preview.bounds.size.width,self.preview.bounds.size.height,self.settingsScroll.bounds.size.width); return 21;
    }
    if(![self verifyWorkspaceGeometry]) return 41;
    if(self.settingsScroll.frame.origin.x>=self.workspace.stage.frame.origin.x || !self.sceneSidebar.hidden || !self.sceneDock.hidden) {
        fprintf(stderr,"FAIL B preparation checklist layout\n"); return 35;
    }
    if(!self.window.toolbar || self.window.toolbarStyle!=NSWindowToolbarStyleUnifiedCompact || self.window.toolbar.items.count<2) {
        fprintf(stderr,"FAIL native window toolbar installation\n"); return 34;
    }
    self.preparationSteps.selectedSegment=1; [self changePreparationStep:self.preparationSteps];
    [self.window.contentView layoutSubtreeIfNeeded];
    WSLayoutFrames editorFrames=ws_studio_layout(self.workspace.bounds.size.width,self.workspace.bounds.size.height,1,0,!self.countdownRow.hidden);
    if(![self verifyWorkspaceGeometry]) return 42;
    if(self.sceneSidebar.hidden || self.settingsScroll.hidden || !self.sceneDock.hidden ||
      std::abs(self.preview.bounds.size.width-editorFrames.stage.width)>2 || self.preview.bounds.size.width<500 ||
      self.sceneSidebar.frame.origin.x>=self.workspace.stage.frame.origin.x || self.workspace.stage.frame.origin.x>=self.settingsScroll.frame.origin.x) {
        fprintf(stderr,"FAIL B editor three-pane layout: preview=%.0f expected=%.0f\n",self.preview.bounds.size.width,editorFrames.stage.width); return 36;
    }
    if(self.sidebarButtons.count!=5) { fprintf(stderr,"FAIL editor scene list\n"); return 29; }
    for(WSSceneButton *button in self.sidebarButtons) {
        [button performClick:self];
        if(self.appliedScene!=button.tag || self.sceneSelector.selectedSegment!=button.tag || button.state!=NSControlStateValueOn) {
            fprintf(stderr,"FAIL editor scene button routing\n"); return 31;
        }
    }
    self.sceneSelector.selectedSegment=0; [self changeScene:self.sceneSelector];
    if(self.countdownSettings.hidden || !self.beautySettings.hidden || !self.captureTools.hidden) { fprintf(stderr,"FAIL waiting-scene settings\n"); return 32; }
    self.sceneSelector.selectedSegment=2; [self changeScene:self.sceneSelector];
    if(!self.countdownSettings.hidden || self.beautySettings.hidden || self.captureTools.hidden) { fprintf(stderr,"FAIL sermon-scene settings\n"); return 33; }
    self.sceneSelector.selectedSegment=0; [self changeScene:self.sceneSelector];
    // A failed image scene must retain both the output and the selected scene.
    NSInteger previousScene=self.appliedScene;
    NSString *previousImage=self.sceneImages[3];
    self.sceneImages[3]=@"/churchobs-ui-test/missing-image.png";
    self.sceneSelector.selectedSegment=3; [self applyScene];
    self.sceneImages[3]=previousImage;
    if(self.sceneSelector.selectedSegment!=previousScene || self.appliedScene!=previousScene) {
        fprintf(stderr,"FAIL UI failed-scene rollback\n"); return 28;
    }
    [self applyScene]; // Clear the deliberate test error with a valid scene.
    self.preparationSteps.selectedSegment=2; [self changePreparationStep:self.preparationSteps];
    [self switchMode:nil];
    if(self.performanceMode) { fprintf(stderr,"FAIL UI review gate\n"); return 22; }
    self.reviewCheck.state=NSControlStateValueOn;
    [self switchMode:nil];
    if(!self.performanceMode || !self.settingsScroll.hidden || self.preparationSteps.hidden || self.preparationSteps.enabled || self.sceneSelector.selectedSegment!=0) {
        fprintf(stderr,"FAIL native UI performance mode\n"); return 23;
    }
    [self.window.contentView layoutSubtreeIfNeeded];
    if(![self verifyWorkspaceGeometry]) return 43;
    [self.window setContentSize:NSMakeSize(1440,930)];
    if(![self verifyWorkspaceGeometry]) return 44;
    [self.window setContentSize:NSMakeSize(1120,800)];
    if(![self verifyWorkspaceGeometry]) return 45;
    if(self.sceneDock.hidden || !self.sceneSidebar.hidden || self.sceneButtons.count!=5 || self.sceneDock.bounds.size.height<100 || self.preview.bounds.size.width<self.workspace.bounds.size.width-34) {
        fprintf(stderr,"FAIL B performance full-width video and scene strip\n"); return 37;
    }
    for(WSSceneButton *button in self.sceneButtons) {
        if(button.bounds.size.width<100 || button.bounds.size.height<90) { fprintf(stderr,"FAIL large performance scene target\n"); return 30; }
        [button performClick:self];
        if(self.appliedScene!=button.tag || button.state!=NSControlStateValueOn) { fprintf(stderr,"FAIL performance scene routing\n"); return 38; }
    }
    [self advanceScene:nil];
    if(self.sceneSelector.selectedSegment!=4) { fprintf(stderr,"FAIL next scene must stop at ending\n"); return 39; }
    self.sceneSelector.selectedSegment=0; [self changeScene:self.sceneSelector];
    [self advanceScene:nil];
    if(self.sceneSelector.selectedSegment!=1) { fprintf(stderr,"FAIL next scene routing\n"); return 40; }
    double strength=self.strengthSlider.doubleValue;
    self.beautySelector.selectedSegment=2; [self changeBeauty:self.beautySelector];
    if(self.strengthSlider.doubleValue!=strength || [self canEditPreparation]) { fprintf(stderr,"FAIL UI editing lock\n"); return 24; }
    self.sceneSelector.selectedSegment=0; [self changeScene:self.sceneSelector];
    self.countdownAuto.state=NSControlStateValueOn;
    self.countdownRemaining=1; self.countdownVisible=YES;
    self.countdownDeadline=NSProcessInfo.processInfo.systemUptime-1;
    [self tickCountdown];
    if(self.sceneSelector.selectedSegment!=1 || self.countdownDeadline!=0) { fprintf(stderr,"FAIL countdown auto scene transition\n"); return 25; }
    self.sceneSelector.selectedSegment=2; [self applyScene];
    self.countdownRemaining=1; self.countdownDeadline=NSProcessInfo.processInfo.systemUptime-1;
    [self tickCountdown];
    if(self.sceneSelector.selectedSegment!=2) { fprintf(stderr,"FAIL expired countdown changed a later scene\n"); return 26; }
    [self switchMode:nil];
    if(self.performanceMode || self.settingsScroll.hidden || self.sceneSidebar.hidden || !self.sceneDock.hidden || self.reviewCheck.state==NSControlStateValueOn) { fprintf(stderr,"FAIL UI return to preparation\n"); return 27; }
    Class<WSSwiftStudioFactory> factory=(Class<WSSwiftStudioFactory>)NSClassFromString(@"WSSwiftStudioHost");
    if(!factory || ![factory verifyIntegrationWithBridge:self previewView:self.preview]) { fprintf(stderr,"FAIL SwiftUI hosting and engine acknowledgement\n"); return 46; }
    fprintf(stderr,"PASS SwiftUI host, real engine graph acknowledgement and minimum preview bounds\n");
    fprintf(stderr,"PASS native B UI: preparation checklist, editor three panes, performance full-width video, next scene, minimum layout, large button targets/routing, contextual settings, failed-scene rollback, review gate, performance mode, editing lock, countdown transition and return\n");
    return 0;
}
