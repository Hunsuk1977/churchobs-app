// SPDX-License-Identifier: GPL-2.0-or-later
#import "PreviewView.h"
@implementation WSPreviewView
- (BOOL)isOpaque { return YES; }
- (void)layout {
    [super layout];
    if (self.sizeChanged) self.sizeChanged(self);
}
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (self.windowChanged) self.windowChanged(self);
}
- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    if (self.sizeChanged) self.sizeChanged(self);
}
@end
