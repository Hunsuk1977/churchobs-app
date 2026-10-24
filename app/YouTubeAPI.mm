// SPDX-License-Identifier: GPL-2.0-or-later
// YouTube Live API (네이티브 이식본). youtube_client.py 의 동작을 그대로 옮겼다:
//  - 데스크톱 OAuth: PKCE + 127.0.0.1 루프백, 브라우저에서 로그인
//  - 방송 목록·만들기·준비(스트림 묶기, RTMPS 주소)·시작·상태·공개 범위·종료
// 오류 문구는 예전과 같아서 기존 번역(WSL)이 그대로 맞는다.
#import "YouTubeAPI.h"
#import <AppKit/AppKit.h>
#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>
#include <ctype.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <unistd.h>

static NSString *const kAPI=@"https://www.googleapis.com/youtube/v3/";
static NSString *const kTokenURL=@"https://oauth2.googleapis.com/token";
static NSString *const kScope=@"https://www.googleapis.com/auth/youtube.force-ssl";

static NSString *base64url(NSData *data) {
    NSString *s=[data base64EncodedStringWithOptions:0];
    s=[s stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
    s=[s stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    return [s stringByReplacingOccurrencesOfString:@"=" withString:@""];
}
static NSString *randomToken(NSUInteger bytes) {
    NSMutableData *data=[NSMutableData dataWithLength:bytes];
    if(SecRandomCopyBytes(kSecRandomDefault,bytes,data.mutableBytes)!=errSecSuccess) arc4random_buf(data.mutableBytes,bytes);
    return base64url(data);
}
static NSString *pkceChallenge(NSString *verifier) {
    NSData *input=[verifier dataUsingEncoding:NSASCIIStringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(input.bytes,(CC_LONG)input.length,digest);
    return base64url([NSData dataWithBytes:digest length:sizeof digest]);
}
static NSString *encode(id value) {
    NSString *text=[value isKindOfClass:NSString.class] ? value : [value description];
    static NSCharacterSet *allowed;
    static dispatch_once_t once;
    dispatch_once(&once,^{ allowed=[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"]; });
    return [text stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
}
static NSString *formEncode(NSDictionary *params) {
    NSMutableArray *parts=[NSMutableArray new];
    for(NSString *key in params) [parts addObject:[NSString stringWithFormat:@"%@=%@",encode(key),encode(params[key])]];
    return [parts componentsJoinedByString:@"&"];
}
static BOOL sameString(NSString *a,NSString *b) {
    NSData *x=[a dataUsingEncoding:NSUTF8StringEncoding], *y=[b dataUsingEncoding:NSUTF8StringEncoding];
    if(x.length!=y.length) return NO;
    const unsigned char *p=(const unsigned char *)x.bytes, *q=(const unsigned char *)y.bytes; unsigned char diff=0;
    for(NSUInteger i=0;i<x.length;i++) diff|=p[i]^q[i];
    return diff==0;
}

@interface WSYouTubeAPI ()
@property(nonatomic, readwrite, copy, nullable) NSString *failure;
@end

@implementation WSYouTubeAPI {
    NSDictionary *_config;        // client_id, client_secret
    NSMutableDictionary *_tokens;
    NSString *_language;
}
- (instancetype)initWithConfig:(NSDictionary *)config tokens:(NSDictionary *)tokens language:(NSString *)language {
    if((self=[super init])) {
        NSDictionary *installed=[config[@"installed"] isKindOfClass:NSDictionary.class] ? config[@"installed"] : @{};
        _config=@{@"client_id":[installed[@"client_id"] isKindOfClass:NSString.class] ? installed[@"client_id"] : @"",
                  @"client_secret":[installed[@"client_secret"] isKindOfClass:NSString.class] ? installed[@"client_secret"] : @""};
        _tokens=[tokens isKindOfClass:NSDictionary.class] ? [tokens mutableCopy] : [NSMutableDictionary new];
        _language=[language hasPrefix:@"en"] ? @"en" : @"ko";
    }
    return self;
}
- (NSDictionary *)tokens { return [_tokens copy]; }
- (id)fail:(NSString *)message { if(!self.failure) self.failure=message; return nil; }

// ── HTTP ───────────────────────────────────────────────
- (nullable NSDictionary *)request:(NSString *)url form:(nullable NSDictionary *)form body:(nullable id)body method:(nullable NSString *)method token:(nullable NSString *)token {
    NSURL *target=[NSURL URLWithString:url];
    if(!target) return [self fail:@"인터넷 연결 또는 Google 응답을 확인하세요."];
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:target cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:25];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    if(form) {
        request.HTTPBody=[formEncode(form) dataUsingEncoding:NSUTF8StringEncoding];
        [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    }
    if(body) {
        request.HTTPBody=[NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    }
    request.HTTPMethod=method ?: ((form || body) ? @"POST" : @"GET");
    if(token) [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];

    __block NSData *data=nil; __block NSHTTPURLResponse *response=nil; __block NSError *transport=nil;
    dispatch_semaphore_t done=dispatch_semaphore_create(0);
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *d,NSURLResponse *r,NSError *e) {
        data=d; response=[r isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)r : nil; transport=e;
        dispatch_semaphore_signal(done);
    }] resume];
    dispatch_semaphore_wait(done,DISPATCH_TIME_FOREVER);
    if(transport || !response) return [self fail:@"인터넷 연결 또는 Google 응답을 확인하세요."];
    id object=data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if(response.statusCode>=400) {
        // 기계가 읽는 이유 코드만 쓴다 (주소·헤더·응답 본문·스트림 키는 남기지 않는다)
        NSString *reason=@"apiError";
        if([object isKindOfClass:NSDictionary.class]) {
            id detail=object[@"error"];
            if([detail isKindOfClass:NSString.class]) reason=detail;
            else if([detail isKindOfClass:NSDictionary.class]) {
                NSArray *errors=[detail[@"errors"] isKindOfClass:NSArray.class] ? detail[@"errors"] : nil;
                NSDictionary *first=[errors.firstObject isKindOfClass:NSDictionary.class] ? errors.firstObject : nil;
                if([first[@"reason"] isKindOfClass:NSString.class]) reason=first[@"reason"];
            }
        }
        NSMutableString *clean=[NSMutableString new];
        for(NSUInteger i=0;i<reason.length && clean.length<80;i++) {
            unichar c=[reason characterAtIndex:i];
            if((c<128 && isalnum(c)) || c=='_' || c=='-') [clean appendFormat:@"%C",c];
        }
        NSDictionary *hints=@{
            @"accessNotConfigured":@"Google Cloud 프로젝트에서 YouTube Data API v3를 사용 설정하세요 (API 및 서비스 › 라이브러리).",
            @"liveStreamingNotEnabled":@"이 채널은 라이브 방송이 꺼져 있습니다. YouTube Studio › 만들기 › 라이브 스트리밍 시작에서 켜세요.",
            @"livePermissionBlocked":@"이 채널은 지금 라이브 방송을 할 수 없습니다. YouTube Studio에서 채널 상태를 확인하세요.",
            @"insufficientPermissions":@"YouTube 권한이 빠졌습니다. 연결 해제 후 다시 연결하고, 권한 화면에서 YouTube 항목을 켜세요.",
            @"youtubeSignupRequired":@"이 Google 계정에는 YouTube 채널이 없습니다. 채널을 고르거나 만든 뒤 다시 연결하세요.",
            @"quotaExceeded":@"오늘 쓸 수 있는 YouTube API 사용량을 넘었습니다. 내일 다시 시도하세요.",
        };
        NSString *hint=hints[clean];
        NSString *code=[NSString stringWithFormat:@"YouTube/Google HTTP %ld: %@",(long)response.statusCode,clean];
        return [self fail:hint ? [NSString stringWithFormat:@"%@ (%@)",hint,code] : code];
    }
    if(![object isKindOfClass:NSDictionary.class]) {
        if(!data.length) return @{};   // 내용 없는 성공 응답
        return [self fail:@"Google 응답 형식이 올바르지 않습니다."];
    }
    return object;
}

- (nullable NSString *)accessToken {
    NSString *refresh=[_tokens[@"refresh_token"] isKindOfClass:NSString.class] ? _tokens[@"refresh_token"] : nil;
    if(!refresh.length) return [self fail:@"먼저 YouTube 계정을 연결하세요."];
    NSString *access=[_tokens[@"access_token"] isKindOfClass:NSString.class] ? _tokens[@"access_token"] : nil;
    if(access.length && [_tokens[@"expires_at"] doubleValue]>NSDate.date.timeIntervalSince1970+60) return access;
    NSMutableDictionary *form=[_config mutableCopy];
    form[@"grant_type"]=@"refresh_token"; form[@"refresh_token"]=refresh;
    NSDictionary *refreshed=[self request:kTokenURL form:form body:nil method:nil token:nil];
    if(!refreshed) return nil;
    [_tokens addEntriesFromDictionary:refreshed];
    NSInteger life=[refreshed[@"expires_in"] integerValue] ?: 3600;
    _tokens[@"expires_at"]=@(NSDate.date.timeIntervalSince1970+life);
    return [_tokens[@"access_token"] isKindOfClass:NSString.class] ? _tokens[@"access_token"] : [self fail:@"재연결 권한을 받지 못했습니다. 다시 로그인하세요."];
}
- (nullable NSDictionary *)api:(NSString *)resource params:(NSDictionary *)params body:(nullable id)body method:(nullable NSString *)method {
    NSString *token=[self accessToken];
    if(!token) return nil;
    return [self request:[NSString stringWithFormat:@"%@%@?%@",kAPI,resource,formEncode(params)] form:nil body:body method:method token:token];
}
- (nullable NSDictionary *)broadcast:(NSString *)bid {
    NSDictionary *data=[self api:@"liveBroadcasts" params:@{@"part":@"id,snippet,status,contentDetails",@"id":bid} body:nil method:nil];
    if(!data) return nil;
    NSArray *items=[data[@"items"] isKindOfClass:NSArray.class] ? data[@"items"] : @[];
    if(!items.count) return [self fail:@"선택한 방송을 찾을 수 없습니다. 예배 목록을 새로 불러오세요."];
    return items.firstObject;
}
static NSString *lifeCycle(NSDictionary *b) { return b[@"status"][@"lifeCycleStatus"] ?: @""; }

// ── 로그인 (PKCE + 루프백) ─────────────────────────────
- (BOOL)authorize {
    NSString *verifier=randomToken(48), *state=randomToken(32);
    int server=socket(AF_INET,SOCK_STREAM,0);
    if(server<0) { [self fail:@"기본 브라우저를 열 수 없습니다."]; return NO; }
    int yes=1; setsockopt(server,SOL_SOCKET,SO_REUSEADDR,&yes,sizeof yes);
    struct sockaddr_in address={}; address.sin_family=AF_INET; address.sin_addr.s_addr=htonl(INADDR_LOOPBACK); address.sin_port=0;
    socklen_t length=sizeof address;
    if(bind(server,(struct sockaddr *)&address,sizeof address)<0 || listen(server,4)<0 || getsockname(server,(struct sockaddr *)&address,&length)<0) {
        close(server); [self fail:@"기본 브라우저를 열 수 없습니다."]; return NO;
    }
    NSString *redirect=[NSString stringWithFormat:@"http://127.0.0.1:%d/oauth2callback",ntohs(address.sin_port)];
    NSDictionary *query=@{@"client_id":_config[@"client_id"],@"redirect_uri":redirect,@"response_type":@"code",@"scope":kScope,
                          @"state":state,@"code_challenge":pkceChallenge(verifier),@"code_challenge_method":@"S256",
                          @"access_type":@"offline",@"prompt":@"consent select_account"};
    NSURL *login=[NSURL URLWithString:[@"https://accounts.google.com/o/oauth2/v2/auth?" stringByAppendingString:formEncode(query)]];
    __block BOOL opened=NO;
    dispatch_sync(dispatch_get_main_queue(),^{ opened=login && [NSWorkspace.sharedWorkspace openURL:login]; });
    if(!opened) { close(server); [self fail:@"기본 브라우저를 열 수 없습니다."]; return NO; }

    NSString *code=nil, *error=nil;
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:300];
    NSData *reply=[(([_language isEqualToString:@"en"]) ? @"Connected. Close this tab and return to Church OBS." : @"연결 요청을 받았습니다. 브라우저를 닫고 Church OBS로 돌아가세요.") dataUsingEncoding:NSUTF8StringEncoding];
    while(!code && !error && deadline.timeIntervalSinceNow>0) {
        fd_set ready; FD_ZERO(&ready); FD_SET(server,&ready);
        struct timeval wait={0,500000};
        if(select(server+1,&ready,nullptr,nullptr,&wait)<=0) continue;
        int client=accept(server,nullptr,nullptr);
        if(client<0) continue;
        struct timeval limit={5,0}; setsockopt(client,SOL_SOCKET,SO_RCVTIMEO,&limit,sizeof limit);
        NSMutableData *incoming=[NSMutableData new]; char buffer[4096];
        while(incoming.length<16384) {
            ssize_t n=recv(client,buffer,sizeof buffer,0);
            if(n<=0) break;
            [incoming appendBytes:buffer length:(NSUInteger)n];
            if([[[NSString alloc] initWithData:incoming encoding:NSUTF8StringEncoding] containsString:@"\r\n\r\n"]) break;
        }
        NSString *text=[[NSString alloc] initWithData:incoming encoding:NSUTF8StringEncoding] ?: @"";
        NSArray *words=[[text componentsSeparatedByString:@"\r\n"].firstObject componentsSeparatedByString:@" "];
        NSURLComponents *parts=words.count>=2 ? [NSURLComponents componentsWithString:[@"http://127.0.0.1" stringByAppendingString:words[1]]] : nil;
        NSMutableDictionary *values=[NSMutableDictionary new];
        for(NSURLQueryItem *item in parts.queryItems) if(item.value && !values[item.name]) values[item.name]=item.value;
        BOOL valid=[parts.path isEqualToString:@"/oauth2callback"] && sameString(values[@"state"] ?: @"",state);
        if(!valid) {
            const char *bad="HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            send(client,bad,strlen(bad),0); close(client); continue;
        }
        if(values[@"error"]) error=@"Google 로그인이 취소되었습니다.";
        else if([values[@"code"] length]) code=values[@"code"];
        else error=@"Google 인증 코드를 받지 못했습니다.";
        NSString *header=[NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n",(unsigned long)reply.length];
        NSMutableData *out=[[header dataUsingEncoding:NSUTF8StringEncoding] mutableCopy]; [out appendData:reply];
        send(client,out.bytes,out.length,0); close(client);
    }
    close(server);
    if(error) { [self fail:error]; return NO; }
    if(!code) { [self fail:@"로그인 시간이 지났습니다. 다시 연결하세요."]; return NO; }
    NSMutableDictionary *form=[_config mutableCopy];
    [form addEntriesFromDictionary:@{@"grant_type":@"authorization_code",@"code":code,@"redirect_uri":redirect,@"code_verifier":verifier}];
    NSDictionary *tokens=[self request:kTokenURL form:form body:nil method:nil token:nil];
    if(!tokens) return NO;
    if(![tokens[@"refresh_token"] isKindOfClass:NSString.class]) { [self fail:@"재연결 권한을 받지 못했습니다. 다시 로그인하세요."]; return NO; }
    _tokens=[tokens mutableCopy];
    NSInteger life=[tokens[@"expires_in"] integerValue] ?: 3600;
    _tokens[@"expires_at"]=@(NSDate.date.timeIntervalSince1970+life);
    return YES;
}

// ── 방송 작업 ──────────────────────────────────────────
- (nullable NSDictionary *)listBroadcasts {
    NSDictionary *channels=[self api:@"channels" params:@{@"part":@"snippet",@"mine":@"true"} body:nil method:nil];
    if(!channels) return nil;
    NSArray *channelItems=[channels[@"items"] isKindOfClass:NSArray.class] ? channels[@"items"] : @[];
    if(!channelItems.count) return [self fail:@"이 계정의 YouTube 채널을 찾을 수 없습니다."];
    NSMutableArray *broadcasts=[NSMutableArray new]; NSString *page=nil;
    for(int i=0;i<4;i++) {
        NSMutableDictionary *params=[@{@"part":@"id,snippet,status,contentDetails",@"broadcastStatus":@"upcoming",@"broadcastType":@"all",@"maxResults":@"50"} mutableCopy];
        if(page) params[@"pageToken"]=page;
        NSDictionary *data=[self api:@"liveBroadcasts" params:params body:nil method:nil];
        if(!data) return nil;
        if([data[@"items"] isKindOfClass:NSArray.class]) [broadcasts addObjectsFromArray:data[@"items"]];
        page=[data[@"nextPageToken"] isKindOfClass:NSString.class] ? data[@"nextPageToken"] : nil;
        if(!page) break;
    }
    NSMutableArray *list=[NSMutableArray new];
    for(NSDictionary *b in broadcasts) [list addObject:@{@"id":b[@"id"] ?: @"",@"title":b[@"snippet"][@"title"] ?: @"",@"privacy":b[@"status"][@"privacyStatus"] ?: @""}];
    return @{@"channel":channelItems.firstObject[@"snippet"][@"title"] ?: @"",@"broadcasts":list};
}
- (nullable NSDictionary *)create:(NSString *)title privacy:(NSString *)privacy kids:(BOOL)kids {
    NSString *trimmed=[title stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if(!trimmed.length || title.length>100) return [self fail:@"예배 제목은 1~100자로 입력하세요."];
    if(![@[@"public",@"unlisted",@"private"] containsObject:privacy]) return [self fail:@"공개 범위를 선택하세요."];
    NSISO8601DateFormatter *iso=[NSISO8601DateFormatter new];
    NSDictionary *body=@{@"snippet":@{@"title":trimmed,@"scheduledStartTime":[iso stringFromDate:[NSDate dateWithTimeIntervalSinceNow:60]]},
                         @"status":@{@"privacyStatus":privacy,@"selfDeclaredMadeForKids":@(kids)},
                         @"contentDetails":@{@"enableAutoStart":@NO,@"enableAutoStop":@NO,@"enableDvr":@YES,@"monitorStream":@{@"enableMonitorStream":@NO}}};
    NSDictionary *b=[self api:@"liveBroadcasts" params:@{@"part":@"snippet,status,contentDetails"} body:body method:@"POST"];
    if(!b) return nil;
    return @{@"id":b[@"id"] ?: @"",@"title":b[@"snippet"][@"title"] ?: trimmed,@"privacy":b[@"status"][@"privacyStatus"] ?: privacy};
}
- (nullable NSDictionary *)prepare:(NSString *)bid {
    NSDictionary *b=[self broadcast:bid]; if(!b) return nil;
    NSDictionary *details=[b[@"contentDetails"] isKindOfClass:NSDictionary.class] ? b[@"contentDetails"] : @{};
    if(![@[@"created",@"ready",@"testing"] containsObject:lifeCycle(b)]) return [self fail:@"시작 전인 예배만 선택할 수 있습니다."];
    if([details[@"enableAutoStart"] boolValue] || [details[@"enableAutoStop"] boolValue]) {
        // YouTube Studio에서 만든 예약은 보통 자동 시작/종료가 켜져 있다 → 이 두 설정만 끈다 (나머지는 그대로)
        NSArray *writable=@[@"enableAutoStart",@"enableAutoStop",@"enableClosedCaptions",@"closedCaptionsType",@"enableContentEncryption",
                            @"enableDvr",@"enableEmbed",@"recordFromStart",@"startWithSlate",@"monitorStream",@"latencyPreference",@"projection",@"enableLowLatency"];
        NSMutableDictionary *updated=[NSMutableDictionary new];
        for(NSString *key in writable) if(details[key]) updated[key]=details[key];
        updated[@"enableAutoStart"]=@NO; updated[@"enableAutoStop"]=@NO;
        NSMutableDictionary *monitor=[updated[@"monitorStream"] isKindOfClass:NSDictionary.class] ? [updated[@"monitorStream"] mutableCopy] : [NSMutableDictionary new];
        if(!monitor[@"enableMonitorStream"]) monitor[@"enableMonitorStream"]=@NO;
        if([monitor[@"enableMonitorStream"] boolValue] && !monitor[@"broadcastStreamDelayMs"]) monitor[@"broadcastStreamDelayMs"]=@0;
        updated[@"monitorStream"]=monitor;
        if(![self api:@"liveBroadcasts" params:@{@"part":@"contentDetails"} body:@{@"id":bid,@"contentDetails":updated} method:@"PUT"]) {
            NSString *why=self.failure ?: @""; self.failure=nil;
            return [self fail:[NSString stringWithFormat:@"이 예약 방송의 자동 시작/자동 종료를 끄지 못했습니다. YouTube Studio에서 끄거나 앱에서 새 예배를 만드세요. (%@)",why]];
        }
        b=[self broadcast:bid]; if(!b) return nil;
        details=[b[@"contentDetails"] isKindOfClass:NSDictionary.class] ? b[@"contentDetails"] : @{};
    }
    NSString *sid=[details[@"boundStreamId"] isKindOfClass:NSString.class] ? details[@"boundStreamId"] : nil;
    if(!sid.length) {
        NSDictionary *s=[self api:@"liveStreams" params:@{@"part":@"snippet,cdn,contentDetails"} body:@{
            @"snippet":@{@"title":[@"Church OBS · " stringByAppendingString:b[@"snippet"][@"title"] ?: @""]},
            @"cdn":@{@"frameRate":@"variable",@"resolution":@"variable",@"ingestionType":@"rtmp"},   // 720p·1080p 어느 쪽이든
            @"contentDetails":@{@"isReusable":@NO}} method:@"POST"];
        if(!s) return nil;
        sid=s[@"id"];
        if(![self api:@"liveBroadcasts/bind" params:@{@"id":bid,@"streamId":sid,@"part":@"id"} body:nil method:@"POST"]) return nil;
    }
    NSDictionary *streams=[self api:@"liveStreams" params:@{@"part":@"cdn,status",@"id":sid} body:nil method:nil];
    if(!streams) return nil;
    NSArray *items=[streams[@"items"] isKindOfClass:NSArray.class] ? streams[@"items"] : @[];
    if(!items.count) return [self fail:@"방송 스트림을 찾을 수 없습니다."];
    NSDictionary *stream=items.firstObject;
    if([stream[@"status"][@"streamStatus"] isEqual:@"active"]) return [self fail:@"이 스트림은 이미 영상을 받고 있습니다. 다른 송출 프로그램을 먼저 확인하세요."];
    NSDictionary *info=stream[@"cdn"][@"ingestionInfo"];
    NSString *server=[info[@"rtmpsIngestionAddress"] isKindOfClass:NSString.class] ? info[@"rtmpsIngestionAddress"] : @"";
    NSString *key=[info[@"streamName"] isKindOfClass:NSString.class] ? info[@"streamName"] : @"";
    if(![server hasPrefix:@"rtmps://"] || !key.length) return [self fail:@"YouTube RTMPS 송출 주소가 없습니다."];
    return @{@"id":bid,@"stream_id":sid,@"server":server,@"key":key,@"title":b[@"snippet"][@"title"] ?: @""};
}
- (nullable NSDictionary *)goLive:(NSString *)bid {
    // 시작 요청은 한 번만 보낸다. 확인은 읽기만 (불확실한 POST를 되풀이하지 않는다)
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:90]; BOOL arrived=NO;
    while(deadline.timeIntervalSinceNow>0) {
        NSDictionary *b=[self broadcast:bid]; if(!b) return nil;
        NSString *state=lifeCycle(b);
        if([state isEqualToString:@"live"]) return @{@"state":@"live"};
        if(![@[@"created",@"ready",@"testing",@"testStarting",@"liveStarting"] containsObject:state]) return [self fail:[@"방송이 시작 가능한 상태가 아닙니다: " stringByAppendingString:state]];
        NSString *sid=b[@"contentDetails"][@"boundStreamId"];
        if(![sid isKindOfClass:NSString.class] || !sid.length) return [self fail:@"방송 스트림이 연결되지 않았습니다."];
        NSDictionary *streams=[self api:@"liveStreams" params:@{@"part":@"status",@"id":sid} body:nil method:nil];
        if(!streams) return nil;
        NSArray *items=[streams[@"items"] isKindOfClass:NSArray.class] ? streams[@"items"] : @[];
        if(items.count && [items.firstObject[@"status"][@"streamStatus"] isEqual:@"active"]) { arrived=YES; break; }
        [NSThread sleepForTimeInterval:2];
    }
    if(!arrived) return [self fail:@"YouTube에 영상이 도착하지 않았습니다. 송출 상태를 확인하세요."];
    if(![self api:@"liveBroadcasts/transition" params:@{@"id":bid,@"broadcastStatus":@"live",@"part":@"status"} body:nil method:@"POST"]) return nil;
    for(int i=0;i<30;i++) {
        NSDictionary *b=[self broadcast:bid]; if(!b) return nil;
        if([lifeCycle(b) isEqualToString:@"live"]) return @{@"state":@"live"};
        [NSThread sleepForTimeInterval:2];
    }
    return [self fail:@"시작 확인이 지연됩니다. 방송 상태 확인을 누르세요."];
}
- (nullable NSDictionary *)status:(NSString *)bid {
    NSDictionary *b=[self broadcast:bid]; if(!b) return nil;
    return @{@"state":lifeCycle(b)};
}
- (nullable NSDictionary *)setPrivacy:(NSString *)privacy for:(NSString *)bid {
    if(![@[@"public",@"unlisted",@"private"] containsObject:privacy]) return [self fail:@"공개 범위를 선택하세요."];
    NSDictionary *b=[self broadcast:bid]; if(!b) return nil;
    NSDictionary *status=[b[@"status"] isKindOfClass:NSDictionary.class] ? b[@"status"] : @{};
    NSMutableDictionary *newStatus=[@{@"privacyStatus":privacy} mutableCopy];
    for(NSString *key in @[@"selfDeclaredMadeForKids",@"containsSyntheticMedia"]) if(status[key]) newStatus[key]=status[key];
    NSDictionary *u=[self api:@"liveBroadcasts" params:@{@"part":@"status"} body:@{@"id":bid,@"status":newStatus} method:@"PUT"];
    if(!u) return nil;
    return @{@"id":bid,@"title":b[@"snippet"][@"title"] ?: @"",@"privacy":u[@"status"][@"privacyStatus"] ?: privacy};
}
- (nullable NSDictionary *)complete:(NSString *)bid {
    NSDictionary *b=[self broadcast:bid]; if(!b) return nil;
    NSString *state=lifeCycle(b);
    if([state isEqualToString:@"complete"]) return @{@"state":@"complete"};
    if(![@[@"live",@"testing"] containsObject:state]) return [self fail:[@"방송 상태를 확인한 뒤 종료하세요: " stringByAppendingString:state]];
    if(![self api:@"liveBroadcasts/transition" params:@{@"id":bid,@"broadcastStatus":@"complete",@"part":@"status"} body:nil method:@"POST"]) return nil;
    return [self status:bid];
}

- (nullable NSDictionary *)execute:(NSString *)command arguments:(NSDictionary *)arguments {
    self.failure=nil;
    if(![_config[@"client_id"] hasSuffix:@".apps.googleusercontent.com"]) return [self fail:@"Google Cloud에서 Desktop app으로 만든 OAuth JSON이 필요합니다."];
    if([command isEqualToString:@"login"] && ![self authorize]) return nil;
    NSString *bid=[arguments[@"id"] isKindOfClass:NSString.class] ? arguments[@"id"] : @"";
    if([command isEqualToString:@"login"] || [command isEqualToString:@"list"]) return [self listBroadcasts];
    if([command isEqualToString:@"create"]) return [self create:[arguments[@"title"] isKindOfClass:NSString.class] ? arguments[@"title"] : @""
                                                        privacy:[arguments[@"privacy"] isKindOfClass:NSString.class] ? arguments[@"privacy"] : @"unlisted"
                                                           kids:[arguments[@"kids"] boolValue]];
    if(!bid.length && ![command isEqualToString:@"login"]) return [self fail:@"알 수 없는 YouTube 작업입니다."];
    if([command isEqualToString:@"prepare"]) return [self prepare:bid];
    if([command isEqualToString:@"live"]) return [self goLive:bid];
    if([command isEqualToString:@"status"]) return [self status:bid];
    if([command isEqualToString:@"privacy"]) return [self setPrivacy:[arguments[@"privacy"] isKindOfClass:NSString.class] ? arguments[@"privacy"] : @"" for:bid];
    if([command isEqualToString:@"complete"]) return [self complete:bid];
    return [self fail:@"알 수 없는 YouTube 작업입니다."];
}
@end
