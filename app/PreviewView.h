// SPDX-License-Identifier: GPL-2.0-or-later
#import <AppKit/AppKit.h>
@interface WSPreviewView : NSView
@property(nonatomic, copy) void (^sizeChanged)(NSView *view);
@property(nonatomic, copy) void (^windowChanged)(NSView *view);
@end
