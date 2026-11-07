#import "SPVvcDecoder.h"
#include <vvdec/vvdec.h>
#include <cstring>
#include <vector>

@implementation SPVvcFrame {
    CVPixelBufferRef _pixelBuffer;
    int64_t _presentationTimeUs;
}
- (instancetype)initWithBuffer:(CVPixelBufferRef)buffer time:(int64_t)time {
    if ((self = [super init])) {
        _pixelBuffer = CVPixelBufferRetain(buffer);
        _presentationTimeUs = time;
    }
    return self;
}
- (CVPixelBufferRef)pixelBuffer { return _pixelBuffer; }
- (int64_t)presentationTimeUs { return _presentationTimeUs; }
- (void)dealloc { CVPixelBufferRelease(_pixelBuffer); }
@end

static void setError(NSError **error, NSInteger code, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"ShortplayVvc" code:code
                                      userInfo:@{NSLocalizedDescriptionKey:message}];
}

@implementation SPVvcDecoder {
    vvdecDecoder *_decoder;
    CVPixelBufferPoolRef _pool;
    uint32_t _poolWidth, _poolHeight;
    OSType _poolFormat;
}
- (nullable instancetype)initWithThreadCount:(NSInteger)threadCount error:(NSError **)error {
    if ((self = [super init])) {
        vvdecParams params;
        vvdec_params_default(&params);
        params.threads = (int)MAX(1, MIN(4, threadCount));
        params.parseDelay = 0;
        params.logLevel = VVDEC_ERROR;
        _decoder = vvdec_decoder_open(&params);
        if (!_decoder) {
            setError(error, -1, @"无法初始化 VVC 解码器");
            return nil;
        }
    }
    return self;
}
- (SPVvcFrame *)copyFrame:(vvdecFrame *)frame error:(NSError **)error {
    if (!frame) return nil;
    SPVvcFrame *result = nil;
    CVPixelBufferRef buffer = nil;
    if (frame->colorFormat != VVDEC_CF_YUV420_PLANAR || frame->numPlanes != 3) {
        setError(error, -2, @"暂不支持该 VVC 色彩格式");
    } else {
        const vvdecVui *vui = frame->picAttributes ? frame->picAttributes->vui : nullptr;
        OSType format = vui && vui->videoFullRangeFlag ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                                                     : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
        if (!_pool || _poolWidth != frame->width || _poolHeight != frame->height || _poolFormat != format) {
            if (_pool) CVPixelBufferPoolRelease(_pool);
            _pool = nullptr;
            _poolWidth = frame->width; _poolHeight = frame->height; _poolFormat = format;
            NSDictionary *attrs = @{
                (id)kCVPixelBufferWidthKey:@(frame->width), (id)kCVPixelBufferHeightKey:@(frame->height),
                (id)kCVPixelBufferPixelFormatTypeKey:@(format), (id)kCVPixelBufferIOSurfacePropertiesKey:@{}
            };
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nullptr, (__bridge CFDictionaryRef)attrs, &_pool);
        }
        CVReturn status = _pool ? CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _pool, &buffer)
                                : kCVReturnAllocationFailed;
        if (status != kCVReturnSuccess) {
            setError(error, status, @"无法分配 VVC 视频帧");
        } else {
            CVPixelBufferLockBaseAddress(buffer, 0);
            const unsigned shift = frame->bitDepth > 8 ? frame->bitDepth - 8 : 0;
            for (unsigned plane = 0; plane < 3; ++plane) {
                const auto &src = frame->planes[plane];
                const size_t dstPlane = plane == 0 ? 0 : 1;
                auto *dst = static_cast<uint8_t *>(CVPixelBufferGetBaseAddressOfPlane(buffer, dstPlane));
                const size_t dstStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, dstPlane);
                for (unsigned y = 0; y < src.height; ++y) {
                    const auto *row = src.ptr + y * src.stride;
                    auto *out = dst + y * dstStride;
                    if (plane == 0 && src.bytesPerSample == 1) {
                        memcpy(out, row, src.width);
                        continue;
                    }
                    for (unsigned x = 0; x < src.width; ++x) {
                        unsigned value = src.bytesPerSample == 1 ? row[x] : reinterpret_cast<const uint16_t *>(row)[x];
                        out[plane == 0 ? x : 2 * x + plane - 1] = static_cast<uint8_t>(value >> shift);
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, 0);
            CFStringRef matrix = frame->height >= 720 ? kCVImageBufferYCbCrMatrix_ITU_R_709_2 : kCVImageBufferYCbCrMatrix_ITU_R_601_4;
            if (vui && vui->colourDescriptionPresentFlag) {
                if (vui->matrixCoefficients == 1) matrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2;
                else if (vui->matrixCoefficients == 9) matrix = kCVImageBufferYCbCrMatrix_ITU_R_2020;
                else if (vui->matrixCoefficients == 5 || vui->matrixCoefficients == 6) matrix = kCVImageBufferYCbCrMatrix_ITU_R_601_4;
            }
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, matrix, kCVAttachmentMode_ShouldPropagate);
            result = [[SPVvcFrame alloc] initWithBuffer:buffer time:frame->ctsValid ? frame->cts : 0];
            CVPixelBufferRelease(buffer);
        }
    }
    vvdec_frame_unref(_decoder, frame);
    return result;
}
- (nullable NSArray<SPVvcFrame *> *)decodePacket:(NSData *)packet presentationTimeUs:(int64_t)time error:(NSError **)error {
    if (packet.length > INT_MAX) {
        setError(error, -3, @"VVC 视频包过大");
        return nil;
    }
    // VVdeC may read padding after the last NAL; never expose NSData's boundary.
    std::vector<uint8_t> bytes(packet.length + 64, 0);
    memcpy(bytes.data(), packet.bytes, packet.length);
    vvdecAccessUnit unit;
    vvdec_accessUnit_default(&unit);
    unit.payload = bytes.data();
    unit.payloadSize = static_cast<int>(bytes.size());
    unit.payloadUsedSize = static_cast<int>(packet.length);
    unit.cts = time < 0 ? 0 : time;
    unit.ctsValid = true;
    vvdecFrame *frame = nullptr;
    int rc = vvdec_decode(_decoder, &unit, &frame);
    if (rc != VVDEC_OK && rc != VVDEC_TRY_AGAIN && rc != VVDEC_EOF) {
        if (frame) vvdec_frame_unref(_decoder, frame);
        setError(error, rc, @"视频解码失败，请切换画质后重试");
        return nil;
    }
    SPVvcFrame *output = [self copyFrame:frame error:error];
    if (error && *error) return nil;
    return output ? @[output] : @[];
}
- (nullable NSArray<SPVvcFrame *> *)flushWithError:(NSError **)error {
    vvdecFrame *frame = nullptr;
    int rc = vvdec_flush(_decoder, &frame);
    if (rc != VVDEC_OK && rc != VVDEC_EOF && rc != VVDEC_TRY_AGAIN) {
        if (frame) vvdec_frame_unref(_decoder, frame);
        setError(error, rc, @"VVC 尾帧解码失败");
        return nil;
    }
    SPVvcFrame *output = [self copyFrame:frame error:error];
    if (error && *error) return nil;
    return output ? @[output] : @[];
}
- (void)dealloc {
    if (_decoder) vvdec_decoder_close(_decoder);
    if (_pool) CVPixelBufferPoolRelease(_pool);
}
@end
