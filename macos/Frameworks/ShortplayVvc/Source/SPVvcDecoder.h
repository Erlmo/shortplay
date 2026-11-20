#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

/// A copied NV12 frame; its storage is independent of VVdeC's reference frames.
@interface SPVvcFrame : NSObject
@property(nonatomic, readonly) CVPixelBufferRef pixelBuffer;
@property(nonatomic, readonly) int64_t presentationTimeUs;
@end

/// Confined to the caller's serial decoding queue.
@interface SPVvcDecoder : NSObject
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (nullable instancetype)initWithThreadCount:(NSInteger)threadCount error:(NSError **)error;
// An empty array is a successful decode with no frame yet (priming / reorder).
- (nullable NSArray<SPVvcFrame *> *)decodePacket:(NSData *)packet
                presentationTimeUs:(int64_t)presentationTimeUs
                             error:(NSError **)error;
- (nullable NSArray<SPVvcFrame *> *)flushWithError:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
