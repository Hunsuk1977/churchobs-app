// SPDX-License-Identifier: GPL-2.0-or-later
#import "YouTubeBridge.h"
#import "YouTubeAPI.h"
#import "Localize.h"
#import <Security/Security.h>

static NSDictionary *tokenQuery(void) {
    return @{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
             (__bridge id)kSecAttrService:@"app.worshipstudio.youtube",
             (__bridge id)kSecAttrAccount:@"OAuthTokens"};
}
static NSData *readTokens(void) {
    NSMutableDictionary *query=[tokenQuery() mutableCopy];
    query[(__bridge id)kSecReturnData]=@YES;
    CFTypeRef item=nullptr;
    if(SecItemCopyMatching((__bridge CFDictionaryRef)query,&item)!=errSecSuccess) return nil;
    return CFBridgingRelease(item);
}
static OSStatus lastSaveStatus=errSecSuccess;
static BOOL saveTokens(NSData *data) {
    NSDictionary *attributes=@{(__bridge id)kSecValueData:data};
    OSStatus status=SecItemUpdate((__bridge CFDictionaryRef)tokenQuery(),(__bridge CFDictionaryRef)attributes);
    // 예전 이름(Worship Studio)이나 다른 서명으로 만든 항목은 고칠 수 없을 수 있다 → 지우고 새로 만든다
    if(status!=errSecSuccess && status!=errSecItemNotFound) {
        SecItemDelete((__bridge CFDictionaryRef)tokenQuery());
        status=errSecItemNotFound;
    }
    if(status==errSecItemNotFound) {
        NSMutableDictionary *query=[tokenQuery() mutableCopy];
        [query addEntriesFromDictionary:attributes];
        query[(__bridge id)kSecAttrAccessible]=(__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
        status=SecItemAdd((__bridge CFDictionaryRef)query,nullptr);
    }
    lastSaveStatus=status;
    return status==errSecSuccess;
}
@interface WSYouTubeBridge ()
@property(nonatomic, readwrite) BOOL busy;
@end
@implementation WSYouTubeBridge
- (NSURL *)configurationURL {
    NSURL *folder=[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    return [[folder URLByAppendingPathComponent:@"ChurchOBS" isDirectory:YES] URLByAppendingPathComponent:@"youtube-client.json"];
}
/// 앱에 들어 있는 Church OBS 공용 Google OAuth 설정 (있으면 사용자가 JSON을 따로 불러오지 않아도 된다)
- (nullable NSURL *)bundledConfigurationURL { return [NSBundle.mainBundle URLForResource:@"youtube-oauth" withExtension:@"json"]; }
- (BOOL)configured { return [NSFileManager.defaultManager fileExistsAtPath:self.configurationURL.path] || self.bundledConfigurationURL != nil; }
- (BOOL)connected { return readTokens().length>0; }
- (BOOL)disconnect {
    if(self.busy) return NO;
    OSStatus status=SecItemDelete((__bridge CFDictionaryRef)tokenQuery());
    return status==errSecSuccess || status==errSecItemNotFound;
}
- (BOOL)importConfiguration:(NSURL *)url error:(NSError **)error {
    if(self.busy || self.connected) {
        if(error) *error=[NSError errorWithDomain:@"ChurchOBSYouTube" code:2 userInfo:@{NSLocalizedDescriptionKey:WSL(@"연결된 계정의 OAuth 설정을 바꿀 수 없습니다.")}];
        return NO;
    }
    NSData *data=[NSData dataWithContentsOfURL:url options:0 error:error];
    id decoded=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:error] : nil;
    NSDictionary *value=[decoded isKindOfClass:NSDictionary.class] ? decoded : nil;
    NSDictionary *installed=[value[@"installed"] isKindOfClass:NSDictionary.class] ? value[@"installed"] : nil;
    NSString *clientID=[installed[@"client_id"] isKindOfClass:NSString.class] ? installed[@"client_id"] : @"";
    if(![clientID hasSuffix:@".apps.googleusercontent.com"]) {
        if(error) *error=[NSError errorWithDomain:@"ChurchOBSYouTube" code:1 userInfo:@{NSLocalizedDescriptionKey:WSL(@"Desktop app 형식의 Google OAuth JSON을 선택하세요.")}];
        return NO;
    }
    NSURL *destination=self.configurationURL;
    if(![NSFileManager.defaultManager createDirectoryAtURL:[destination URLByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:error]) return NO;
    // Only public desktop client configuration; tokens are always in Keychain.
    NSData *clean=[NSJSONSerialization dataWithJSONObject:@{@"installed":@{@"client_id":clientID,@"client_secret":installed[@"client_secret"] ?: @""}} options:0 error:error];
    if(!clean || ![clean writeToURL:destination options:NSDataWritingAtomic error:error]) return NO;
    return [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:destination.path error:error];
}
// 도우미(파이썬)가 돌려준 오류를 앱 언어로: 문장 전체, 또는 "문장 (코드)"·"문장: 상태"의 앞부분
static NSString *localizedFailure(NSString *s) {
    if(!s.length) return s;
    NSString *whole=WSL(s);
    if(![whole isEqualToString:s]) return whole;
    for(NSString *sep in @[@" (",@": "]) {
        NSRange r=[s rangeOfString:sep];
        if(r.location==NSNotFound || r.location==0) continue;
        NSString *head=[s substringToIndex:r.location], *translated=WSL(head);
        if(![translated isEqualToString:head]) return [translated stringByAppendingString:[s substringFromIndex:r.location]];
    }
    return s;
}
- (void)run:(NSString *)command arguments:(NSDictionary *)arguments completion:(void (^)(NSDictionary *,NSString *))completion {
    if(self.busy) { completion(nil,WSL(@"이전 YouTube 작업을 마칠 때까지 기다려주세요.")); return; }
    NSData *configData=[NSData dataWithContentsOfURL:self.configurationURL];
    if(!configData && self.bundledConfigurationURL) configData=[NSData dataWithContentsOfURL:self.bundledConfigurationURL];
    NSDictionary *config=configData ? [NSJSONSerialization JSONObjectWithData:configData options:0 error:nil] : nil;
    if(!config) { completion(nil,WSL(@"Google OAuth 설정 JSON을 먼저 불러오세요.")); return; }
    NSData *stored=readTokens();
    NSDictionary *tokens=stored ? [NSJSONSerialization JSONObjectWithData:stored options:0 error:nil] : @{};
    NSString *language=NSBundle.mainBundle.preferredLocalizations.firstObject ?: @"ko";
    NSDictionary *input=[arguments copy];
    self.busy=YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        @autoreleasepool {
            NSDictionary *result=nil; NSString *failure=nil;
            WSYouTubeAPI *api=[[WSYouTubeAPI alloc] initWithConfig:config tokens:tokens ?: @{} language:language];
            NSDictionary *answer=[api execute:command arguments:input];
            if(answer) {
                NSData *tokenData=[NSJSONSerialization dataWithJSONObject:api.tokens options:0 error:nil];
                if(!tokenData || !saveTokens(tokenData)) failure=[NSString stringWithFormat:WSL(@"로그인 정보를 macOS 키체인에 저장하지 못했습니다. (코드 %d)"),(int)lastSaveStatus];
                else result=answer;
            } else failure=api.failure ?: WSL(@"YouTube 연결 작업이 중단되었습니다.");
            // 원인을 찾을 수 있게 실패는 로그에 남긴다 (토큰·키는 남기지 않음)
            if(failure) { NSLog(@"[youtube] %@ failed: %@",command,failure); failure=localizedFailure(failure); }
            else NSLog(@"[youtube] %@ ok",command);
            dispatch_async(dispatch_get_main_queue(), ^{ self.busy=NO; completion(result,failure); });
        }
    });
}
@end
