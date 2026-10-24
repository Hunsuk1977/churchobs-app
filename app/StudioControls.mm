// SPDX-License-Identifier: GPL-2.0-or-later
#import "StudioControls.h"
// These are real AppKit controls. AppKit draws their bezel, focus, pressed state,
// SF Symbols and appearance; the app does not paint CSS-like button surfaces.
@implementation WSActionButton
@synthesize prominent=_prominent;
- (void)setProminent:(BOOL)prominent {
    _prominent=prominent;
    if(prominent && !self.bezelColor) self.bezelColor=NSColor.controlAccentColor;
    if(!prominent) self.bezelColor=nil;
}
@end
@implementation WSSceneButton
@end
@implementation WSSectionStack
@end

#include "StudioLayout.h"
static NSRect workspaceRect(WSRect value) {
    return NSMakeRect(value.x,value.y,value.width,value.height);
}
@implementation WSStudioWorkspace
- (BOOL)isFlipped { return YES; }
- (void)resizeSubviewsWithOldSize:(NSSize)oldSize {
    [super resizeSubviewsWithOldSize:oldSize]; self.needsLayout=YES;
}
- (void)refreshLayout {
    self.inspector.hidden=self.performance;
    self.sidebar.hidden=self.performance || self.page!=1;
    self.scenes.hidden=!self.performance;
    self.needsLayout=YES;
}
- (void)layout {
    [super layout];
    WSLayoutFrames f=ws_studio_layout(self.bounds.size.width,self.bounds.size.height,(int)self.page,self.performance,!self.countdown.hidden);
    self.stage.frame=workspaceRect(f.stage);
    self.stage.needsLayout=YES;
    if(!self.inspector.hidden) self.inspector.frame=workspaceRect(f.inspector);
    if(!self.sidebar.hidden) self.sidebar.frame=workspaceRect(f.sidebar);
    if(!self.scenes.hidden) self.scenes.frame=workspaceRect(f.scenes);
    if(!self.countdown.hidden) self.countdown.frame=workspaceRect(f.countdown);
    self.footer.frame=workspaceRect(f.footer);
    self.status.frame=workspaceRect(f.status);
}
@end
@implementation WSVideoStage
- (BOOL)isFlipped { return YES; }
- (void)layout {
    [super layout];
    CGFloat width=self.bounds.size.width,height=self.bounds.size.height;
    CGFloat errorHeight=self.errorLabel.hidden ? 0 : 42;
    self.header.frame=NSMakeRect(0,0,width,26);
    self.screen.frame=NSMakeRect(0,36,width,MAX(0,height-36-errorHeight));
    self.errorLabel.frame=NSMakeRect(0,MAX(0,height-errorHeight),width,errorHeight);
    for(NSView *view in self.screen.subviews) { view.frame=self.screen.bounds; view.needsLayout=YES; }
}
@end
