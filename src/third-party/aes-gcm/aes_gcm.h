// Compact pure-C AES-GCM for zjs's crypto.subtle.encrypt/decrypt path.
//
// Used as the fallback when no platform-native AES-GCM is reachable —
// Apple's public SDK doesn't expose kCCModeGCM, so this is what runs
// on macOS / iOS.
//
// SCOPE / CAVEATS:
//   - Supports AES-128, AES-192, AES-256.
//   - 12-byte (96-bit) IV only. The spec allows other lengths but in
//     practice everyone uses 96; supporting arbitrary lengths would
//     need GHASH-prep of the IV.
//   - 16-byte authentication tag.
//   - Table-based AES (uses 256-entry S-box). NOT CONSTANT-TIME —
//     vulnerable to cache-timing side channels. Acceptable for hobby
//     zjs; security-sensitive embedders should swap in a constant-
//     time AES (BearSSL aes_ct / aes_ct64) when packaging.
//
// Returns 0 on success. Returns -1 on:
//   - Invalid key length (must be 16/24/32 bytes).
//   - Invalid IV length (must be 12 bytes).
//   - Decrypt tag mismatch (authentication failure).

#ifndef ZJS_AES_GCM_H
#define ZJS_AES_GCM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// AES-GCM encrypt. Writes in_len ciphertext bytes to out, writes the
// 16-byte authentication tag to tag.
int zjs_pc_aes_gcm_encrypt(const uint8_t* key, size_t key_len,
                           const uint8_t* iv,  size_t iv_len,
                           const uint8_t* aad, size_t aad_len,
                           const uint8_t* in,  size_t in_len,
                           uint8_t* out,
                           uint8_t tag[16]);

// AES-GCM decrypt. tag is the 16-byte tag the consumer sent in (the
// caller-passed buffer is read-only here). Returns -1 if the
// recomputed tag doesn't match (constant-time compare).
int zjs_pc_aes_gcm_decrypt(const uint8_t* key, size_t key_len,
                           const uint8_t* iv,  size_t iv_len,
                           const uint8_t* aad, size_t aad_len,
                           const uint8_t* in,  size_t in_len,
                           uint8_t* out,
                           const uint8_t tag[16]);

#ifdef __cplusplus
}
#endif

#endif
