// SPDX-License-Identifier: GPL-2.0-or-later
// YouTube Live API (네이티브). 예전 youtube_client.py 와 같은 동작·같은 오류 문구.
// 토큰은 호출한 쪽(WSYouTubeBridge)이 macOS 키체인에 저장한다. 이 코드는 토큰·스트림 키를 로그에 남기지 않는다.
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface WSYouTubeAPI : NSObject
/// config = {"installed":{"client_id":…,"client_secret":…}}, tokens = 키체인에 저장된 사전
- (instancetype)initWithConfig:(NSDictionary *)config tokens:(NSDictionary *)tokens language:(NSString *)language;
/// 백그라운드 스레드에서 부른다 (네트워크를 기다린다). 실패하면 nil 이고 failure 에 이유
- (nullable NSDictionary *)execute:(NSString *)command arguments:(NSDictionary *)arguments;
@property(nonatomic, readonly, copy) NSDictionary *tokens;
@property(nonatomic, readonly, copy, nullable) NSString *failure;
@end
NS_ASSUME_NONNULL_END
