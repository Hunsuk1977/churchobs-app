// SPDX-License-Identifier: GPL-2.0-or-later
#import <AppKit/AppKit.h>
NS_ASSUME_NONNULL_BEGIN
@interface WSActionButton : NSButton
@property(nonatomic) BOOL prominent;
@end
@interface WSSceneButton : WSActionButton
@property(nonatomic,copy) NSString *caption;
@end
@interface WSSectionStack : NSStackView
@end

// Frame-based outer workspace avoids cross-pane Auto Layout dependencies.
@interface WSStudioWorkspace : NSView
@property(nonatomic,strong) NSView *stage;
@property(nonatomic,strong) NSView *inspector;
@property(nonatomic,strong) NSView *sidebar;
@property(nonatomic,strong) NSView *scenes;
@property(nonatomic,strong) NSView *countdown;
@property(nonatomic,strong) NSView *footer;
@property(nonatomic,strong) NSView *status;
@property(nonatomic) NSInteger page;
@property(nonatomic) BOOL performance;
- (void)refreshLayout;
@end
@interface WSVideoStage : NSView
@property(nonatomic,strong) NSView *header;
@property(nonatomic,strong) NSView *screen;
@property(nonatomic,strong) NSTextField *errorLabel;
@end
NS_ASSUME_NONNULL_END
