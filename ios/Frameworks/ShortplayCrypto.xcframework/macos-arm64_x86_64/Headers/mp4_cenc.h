// MP4 CENC parsing core. Ports the box-walking logic from the existing
// Dart implementation (mp4_decrypt.dart + video_proxy_server.dart
// _parseMoovSamples) so the native stream produces the same sample table.
#ifndef SP_MP4_CENC_H
#define SP_MP4_CENC_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// One (clear, encrypted) subsample byte-run pair.
typedef struct {
  uint32_t clear;  // leading bytes left in the clear
  uint32_t enc;    // following bytes encrypted under the per-sample IV
} sp_subsample;

// Decryption descriptor for a single media sample, ordered by file offset.
typedef struct {
  uint64_t file_offset;   // absolute byte offset of the sample in the file
  uint32_t size;          // sample size in bytes
  uint8_t iv[16];         // 16-byte IV (8-byte senc IVs are left-padded)
  sp_subsample *subs;     // NULL when the whole sample is encrypted
  uint32_t sub_count;     // number of subsample pairs (0 => full-sample)
} sp_sample;

// Parsed sample table for a whole file.
typedef struct {
  sp_sample *samples;
  size_t count;
} sp_sample_table;

// Parse a moov box (raw bytes + its absolute file offset) into a sorted
// sample table. Returns 0 on success and fills `out`; caller frees with
// sp_sample_table_free. Returns non-zero on malformed input.
int sp_parse_moov_samples(const uint8_t *moov, size_t moov_len,
                          uint64_t moov_file_offset, sp_sample_table *out);

// Free a table produced by sp_parse_moov_samples (safe on a zeroed struct).
void sp_sample_table_free(sp_sample_table *table);

// In place: rewrite encv/enca sample entries back to their original format
// (avc1/mp4a/...) recorded in the sibling frma box, matching the Dart
// fixEncryptionBoxes. `moov` points at the moov box bytes.
void sp_fix_encryption_boxes(uint8_t *moov, size_t moov_len);

#ifdef __cplusplus
}
#endif

#endif  // SP_MP4_CENC_H
