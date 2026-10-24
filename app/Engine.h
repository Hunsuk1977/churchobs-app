// SPDX-License-Identifier: GPL-2.0-or-later
#import <AppKit/AppKit.h>
NS_ASSUME_NONNULL_BEGIN
@interface WSEngine : NSObject
@property(nonatomic, readonly) BOOL ready;
@property(nonatomic, readonly) BOOL recording;
@property(nonatomic, readonly) BOOL stopping;
@property(nonatomic, readonly) BOOL streaming;
@property(nonatomic, readonly) BOOL streamConnected;
/// 송출 상태 (active, kbps, dropped, frames, congestion, reconnecting, targetKbps)
- (NSDictionary *)streamStats;
@property(nonatomic, readonly) BOOL hasCamera;
@property(nonatomic, readonly) BOOL hasMicrophone;
@property(nonatomic, readonly) NSString *status;
@property(nonatomic, readonly) NSString *lastError;
@property(nonatomic, readonly) NSString *recordingPath;
@property(nonatomic, readonly) NSString *beautyStatus;
@property(nonatomic, readonly) NSDictionary<NSString *, NSNumber *> *beautyDiagnostics;
- (BOOL)startWithPreview:(NSView *)view;
- (void)resizePreview:(NSView *)view;
- (BOOL)attachProgramView:(NSView *)view;
- (void)resizeProgram:(NSView *)view;
/// 출력 창: 송출 화면을 모니터(UUID) 전체 또는 별도 창에 띄운다
- (BOOL)openProjectorOnDisplay:(NSString *)displayUUID windowed:(BOOL)windowed;
- (void)closeProjector;
/// 영상·음악 소리가 나가는 곳 (broadcast · both · room)
- (BOOL)setAudioMonitor:(NSString *)sourceID mode:(NSString *)mode;
/// 출력 창에 송출과 다른 장면 띄우기 (sceneID 없음 = 송출 화면 그대로)
- (BOOL)applyProjectorGraph:(NSDictionary<NSString *,id> *)graph;
- (void)clearProjectorGraph;
/// 영상 파일 재생 상태와 조작 (재생·멈춤·처음부터·정지·반복)
- (NSDictionary<NSString *,NSDictionary *> *)graphMediaStates;
- (BOOL)mediaControl:(NSString *)sourceID action:(NSString *)action loop:(BOOL)loop;
@property(nonatomic, readonly) BOOL projectorOpen;
- (void)setStudioMode:(BOOL)enabled;
- (BOOL)setVirtualCameraEnabled:(BOOL)enabled;
@property(nonatomic, readonly) BOOL virtualCameraActive;
@property(nonatomic, readonly) BOOL virtualCameraAvailable;
- (NSArray<NSDictionary<NSString *, NSString *> *> *)cameras;
- (NSArray<NSDictionary<NSString *, NSString *> *> *)microphones;
- (BOOL)selectCamera:(NSString *)device;
- (BOOL)selectTestPattern;
- (BOOL)selectFaceTestInput;
- (BOOL)verifyFaceTrackingPipeline;
- (BOOL)selectMicrophone:(NSString *)device;
- (void)setCameraSceneVisible:(BOOL)visible;
- (void)setMicrophoneMuted:(BOOL)muted;
- (BOOL)selectCaptureWindow:(uint32_t)windowID scene:(NSInteger)scene;
- (void)setWindowCaptureEnabled:(BOOL)enabled scene:(NSInteger)scene;
- (void)setCaptureLayout:(NSInteger)layout scene:(NSInteger)scene;
- (BOOL)setLoopMediaAtPath:(NSString *)path scene:(NSInteger)scene;
- (BOOL)setBackgroundMusicAtPath:(NSString *)path scene:(NSInteger)scene;
- (void)setBeautyPreset:(NSInteger)preset;
- (void)setBeautyStrength:(double)strength skin:(double)skin shape:(double)shape eyes:(double)eyes brows:(double)brows;
- (void)setFaceGuide:(BOOL)enabled;
- (void)setBeautyComparison:(BOOL)enabled;
/// 색 톤 (0 없음, 1 따뜻하게, 2 맑게, 3 차분하게, 4 필름), 강도 0~1, 배경 흐림 0~1
- (void)setLookTone:(NSInteger)tone amount:(double)amount blur:(double)blur;
@property(nonatomic, readonly) NSInteger lookTone;
@property(nonatomic, readonly) double lookToneAmount;
@property(nonatomic, readonly) double lookBlur;
- (BOOL)verifyBeautyOnTestPattern;
- (BOOL)verifyWorshipScenes;
- (BOOL)verifyStreamingComponents;
- (BOOL)startRecordingAtPath:(NSString *)path;
- (void)stopRecording;
- (BOOL)setWorshipScene:(NSInteger)scene text:(NSString *)text imagePath:(NSString *)path;
- (BOOL)startStreamToServer:(NSString *)server key:(NSString *)key;
- (void)stopStream;
- (void)poll;
- (BOOL)verifySwiftGraph;
- (float)microphoneLevel;
- (BOOL)applyGraph:(NSDictionary<NSString *,id> *)graph preview:(BOOL)preview;
- (void)clearGraphPreview;
- (BOOL)updateGraphPreviewLayout:(NSArray<NSDictionary<NSString *,id> *> *)items;
- (NSDictionary<NSString *,NSArray<NSNumber *> *> *)graphSourceSizes;
- (NSDictionary<NSString *,NSString *> *)graphWarnings;
- (void)setAudioProbe:(NSString *)device;
- (float)audioProbeLevel;
- (NSDictionary<NSString *,NSNumber *> *)graphAudioLevels;
- (void)shutdown;
@end
NS_ASSUME_NONNULL_END
