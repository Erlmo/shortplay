#import "GeneratedPluginRegistrant.h"

// Native crypto core — exposes C functions to Swift via bridging header.
#include "crypto_stream.h"

// API signing native library — declare so linker retains the symbol.
int weeou_sign(const char *method, const char *path,
               const char *query, const char *body, int body_len,
               char *out_buf);

// iOS-specific bridge entry point (registers HTTP callbacks into the C core).
#include <stdint.h>
#include <stddef.h>

typedef long (*sp_http_range_fn_t)(void *user, const char *url, uint64_t start,
                                   uint64_t end, uint8_t *out, size_t out_cap);
typedef void *(*sp_http_stream_open_fn_t)(void *user, const char *url,
                                          uint64_t start);
typedef long (*sp_http_stream_read_fn_t)(void *user, void *stream, uint8_t *out,
                                         size_t cap);
typedef void (*sp_http_stream_close_fn_t)(void *user, void *stream);

void sp_ios_init(sp_http_range_fn_t range_fn,
                 sp_http_stream_open_fn_t open_fn,
                 sp_http_stream_read_fn_t read_fn,
                 sp_http_stream_close_fn_t close_fn);
