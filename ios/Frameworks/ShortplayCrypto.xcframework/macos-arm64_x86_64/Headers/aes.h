// Zero-dependency AES-128 + streaming CTR (SIC) core.
// Replicates Dart pointycastle SICStreamCipher(AESEngine()) semantics
// byte-for-byte so decryption output matches the existing proxy path.
#ifndef SP_AES_H
#define SP_AES_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// AES-128 key schedule (11 round keys = 176 bytes).
typedef struct {
  uint8_t round_key[176];
} sp_aes_ctx;

// Initialize the key schedule from a 16-byte AES-128 key.
void sp_aes128_init(sp_aes_ctx *ctx, const uint8_t key[16]);

// Encrypt one 16-byte block in place->out (ECB primitive, used by CTR).
void sp_aes128_encrypt_block(const sp_aes_ctx *ctx,
                             const uint8_t in[16],
                             uint8_t out[16]);

// Streaming CTR (SIC) state: full 16-byte big-endian counter, with a
// retained keystream remainder so successive process() calls chain.
typedef struct {
  sp_aes_ctx aes;
  uint8_t counter[16];    // current counter block (big-endian increment)
  uint8_t keystream[16];  // cached keystream for the current block
  size_t ks_used;         // bytes of keystream already consumed (0..16)
} sp_ctr_ctx;

// (Re)initialize a CTR stream with key + 16-byte IV. Resets keystream.
void sp_ctr_init(sp_ctr_ctx *ctx, const uint8_t key[16], const uint8_t iv[16]);

// XOR `len` bytes of `in` into `out` using the running keystream,
// advancing the counter exactly like pointycastle SIC. in==out is allowed.
void sp_ctr_process(sp_ctr_ctx *ctx,
                    const uint8_t *in,
                    uint8_t *out,
                    size_t len);

#ifdef __cplusplus
}
#endif

#endif  // SP_AES_H
