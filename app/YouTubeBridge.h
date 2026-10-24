// SPDX-License-Identifier: GPL-2.0-or-later
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface WSYouTubeBridge : NSObject
@property(nonatomic, readonly) BOOL busy;
@property(nonatomic, readonly) BOOL connected;
@property(nonatomic, readonly) BOOL configured;
@property(nonatomic, readonly) NSURL *configurationURL;
- (BOOL)disconnect;
- (BOOL)importConfiguration:(NSURL *)url error:(NSError * _Nullable * _Nullable)error;
- (void)run:(NSString *)command arguments:(NSDictionary *)arguments completion:(void (^)(NSDictionary * _Nullable result, NSString * _Nullable error))completion;
@end
NS_ASSUME_NONNULL_END
