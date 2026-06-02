// Generic stream API: player-agnostic decrypted MP4 access. Any player
// (ExoPlayer DataSource, AVPlayer ResourceLoaderDelegate, or mpv via the
// mpv_adapter) can use these to open an encrypted CDN stream, read decrypted
// bytes sequentially, seek, query size, and close. The handle is opaque.
#ifndef SP_CRYPTO_STREAM_H
#define SP_CRYPTO_STREAM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Platform-provided HTTP range fetch. Must perform a blocking GET of
// `url` with header "Range: bytes=<start>-<end>" (inclusive) and write the
// body into `out` (capacity `out_cap`). Returns the number of bytes written,
// or -1 on error. `user` is the opaque pointer passed at registration time.
typedef long (*sp_http_range_fn)(void *user, const char *url, uint64_t start,
                                 uint64_t end, uint8_t *out, size_t out_cap);

// Platform-provided streaming GET, used for the large mdat region so bytes are
// delivered to the player as each TCP chunk arrives (no waiting for a full
// block). The three functions model an open-ended "Range: bytes=<start>-" GET:
//   open  : begin a streamed GET at `start`; returns an opaque stream handle
//           (or NULL on error). `user` is the registration-time pointer.
//   read  : block until the next chunk arrives, copy up to `cap` bytes into
//           `out`; return bytes read, 0 on clean EOF, or -1 on error.
//   close : release the stream handle (safe to call with NULL).
// A platform may leave these NULL (e.g. desktop tests), in which case the core
// falls back to sp_http_range_fn for mdat as well.
typedef void *(*sp_http_stream_open_fn)(void *user, const char *url,
                                        uint64_t start);
typedef long (*sp_http_stream_read_fn)(void *user, void *stream, uint8_t *out,
                                       size_t cap);
typedef void (*sp_http_stream_close_fn)(void *user, void *stream);

// Install the HTTP backend. Must be called once before opening any stream.
// `user` is forwarded to every call.
void sp_crypto_set_http(sp_http_range_fn fn, void *user);

// Install the optional streaming backend (used for mdat). Pass NULL fns to
// disable streaming and fall back to range fetches. `user` matches set_http.
void sp_crypto_set_http_stream(sp_http_stream_open_fn open_fn,
                               sp_http_stream_read_fn read_fn,
                               sp_http_stream_close_fn close_fn);

// ── Generic stream API (player-agnostic) ──────────────────────────────────

// Open a decrypted stream for `cdn_url` using `key_hex` (32 hex chars).
// Returns an opaque handle on success, NULL on failure. The handle owns a
// background producer thread that prefetches CDN data ahead of the read pos.
void *sp_stream_open(const char *cdn_url, const char *key_hex);

// Read up to `nbytes` decrypted bytes into `buf` starting at the current
// position. Returns the number of bytes read (0 at EOF, <0 should not occur
// in practice but treat as error).
int64_t sp_stream_read(void *handle, char *buf, uint64_t nbytes);

// Seek to `offset` (absolute byte position in the virtual decrypted file).
// Returns the new position on success, -1 on out-of-range.
int64_t sp_stream_seek(void *handle, int64_t offset);

// Return the total size of the virtual decrypted file.
int64_t sp_stream_size(void *handle);

// Close the stream: stop the producer thread, free all resources.
void sp_stream_close(void *handle);

// ── mpv adapter (kept for media_kit backward compatibility) ───────────────

// Register the "crypto://" protocol on the given mpv handle (cast from the
// int handle exposed by media_kit's Player.handle). Returns 0 on success,
// non-zero if the libmpv symbol could not be resolved or registration failed.
int sp_register_crypto_protocol(int64_t handle);

// ── Prewarm cache ─────────────────────────────────────────────────────────

// Prewarm the cache for `cdn_url` so the next sp_stream_open for it skips the
// box scan + header fetch + sample-table parse (~300-680ms). Blocking. Call
// from a background thread. Returns 0 on success, non-zero on failure.
int sp_prewarm(const char *cdn_url, const char *key_hex);

// Header-only prewarm: same as sp_prewarm but skips the 512KB mdat prefetch.
// Use for N+2 episodes where you want fast build_stream but don't need the
// mdat seed yet. Later call sp_prewarm_seed_mdat to upgrade.
int sp_prewarm_header_only(const char *cdn_url, const char *key_hex);

// Upgrade a header-only prewarm entry by fetching 512KB of raw mdat. No-op if
// the entry already has a seed or doesn't exist. Returns 0 on success.
int sp_prewarm_seed_mdat(const char *cdn_url);

// ── Whole-file decrypt (for offline caching) ──────────────────────────────

// Decrypt the entire encrypted MP4 at `cdn_url` using `key_hex` and write the
// resulting clear MP4 to `output_path`. Blocking (downloads + decrypts the full
// file). Returns 0 on success, non-zero on failure (1=bad args, 2=fopen fail,
// 3=read error, 4=write error). On failure the partial file is removed.
int sp_decrypt_to_file(const char *cdn_url, const char *key_hex,
                       const char *output_path);

// ── Internal (used by mpv_adapter.c) ──────────────────────────────────────

// Parse a "crypto://..." URI into CDN URL + 16-byte AES key.
int parse_uri(const char *uri, char **out_url, uint8_t key[16]);

#ifdef __cplusplus
}
#endif

#endif  // SP_CRYPTO_STREAM_H
