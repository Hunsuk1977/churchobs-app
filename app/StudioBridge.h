// SPDX-License-Identifier: GPL-2.0-or-later
#import <AppKit/AppKit.h>
NS_ASSUME_NONNULL_BEGIN
@protocol WSStudioNativeBridge <NSObject>
- (NSDictionary<NSString *,id> *)studioState NS_SWIFT_NAME(studioState());
- (BOOL)studioCommand:(NSString *)command arguments:(NSDictionary<NSString *,id> *)arguments NS_SWIFT_NAME(studioCommand(_:arguments:));
- (BOOL)applySceneGraph:(NSDictionary<NSString *,id> *)graph preview:(BOOL)preview NS_SWIFT_NAME(applySceneGraph(_:preview:));
@optional
- (BOOL)updatePreviewLayout:(NSArray<NSDictionary<NSString *,id> *> *)items NS_SWIFT_NAME(updatePreviewLayout(_:));
/// 스튜디오 모드의 실제 송출 화면 뷰
- (NSView *)programPreviewView NS_SWIFT_NAME(programPreviewView());
@end
@protocol WSSwiftStudioFactory <NSObject>
+ (NSView *)makeViewWithBridge:(id<WSStudioNativeBridge>)bridge previewView:(NSView *)preview;
+ (BOOL)verifyIntegrationWithBridge:(id<WSStudioNativeBridge>)bridge previewView:(NSView *)preview;
@end
NS_ASSUME_NONNULL_END
