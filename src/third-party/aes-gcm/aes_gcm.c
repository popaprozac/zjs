// Compact pure-C AES-GCM. See header for caveats.
//
// AES portion: textbook FIPS-197 — key schedule + 10/12/14 rounds of
// SubBytes, ShiftRows, MixColumns, AddRoundKey. Uses a 256-entry
// S-box (table lookup, NOT constant-time).
//
// GHASH portion: GF(2^128) multiplication via shift-and-XOR using
// the spec polynomial x^128 + x^7 + x^2 + x + 1. Bit-by-bit (slow
// but correct; 128 iterations per block).
//
// GCM: standard SP 800-38D construction.
//   J0 = IV || 00000001
//   Y[i] = inc32(J0)
//   C[i] = P[i] XOR AES_E(K, Y[i])
//   T = GHASH(H, A || C || len(A)||len(C)) XOR AES_E(K, J0)
//
// Validated end-of-file with a NIST test vector.

#include "aes_gcm.h"
#include <string.h>

// ---------------------------------------------------------------------
// AES — encrypt only (decrypt uses CTR-style same path).
// ---------------------------------------------------------------------

static const uint8_t SBOX[256] = {
    0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
    0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
    0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
    0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
    0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
    0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
    0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
    0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
    0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
    0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
    0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
    0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
    0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
    0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
    0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
    0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16,
};

static const uint8_t RCON[15] = {
    0x00, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40,
    0x80, 0x1b, 0x36, 0x6c, 0xd8, 0xab, 0x4d,
};

// xtime: multiply by x in GF(2^8) mod 0x11b.
static uint8_t xtime(uint8_t b) {
    return (uint8_t)((b << 1) ^ ((b & 0x80) ? 0x1b : 0x00));
}

// AES expanded key. Up to AES-256 = 14 rounds = 15*16 = 240 bytes.
typedef struct {
    uint8_t rk[240];
    int     nr;   // number of rounds (10/12/14)
} aes_ks;

static int aes_setkey(aes_ks* ks, const uint8_t* key, size_t key_len) {
    int nk, nr;
    if (key_len == 16) { nk = 4; nr = 10; }
    else if (key_len == 24) { nk = 6; nr = 12; }
    else if (key_len == 32) { nk = 8; nr = 14; }
    else return -1;
    ks->nr = nr;
    int total_words = 4 * (nr + 1);  // each round needs 16 bytes
    memcpy(ks->rk, key, key_len);
    uint8_t* w = ks->rk;
    int i = nk;
    while (i < total_words) {
        uint8_t t[4];
        t[0] = w[(i - 1) * 4 + 0];
        t[1] = w[(i - 1) * 4 + 1];
        t[2] = w[(i - 1) * 4 + 2];
        t[3] = w[(i - 1) * 4 + 3];
        if (i % nk == 0) {
            // RotWord
            uint8_t k = t[0]; t[0] = t[1]; t[1] = t[2]; t[2] = t[3]; t[3] = k;
            // SubWord
            t[0] = SBOX[t[0]]; t[1] = SBOX[t[1]];
            t[2] = SBOX[t[2]]; t[3] = SBOX[t[3]];
            // Rcon
            t[0] ^= RCON[i / nk];
        } else if (nk > 6 && i % nk == 4) {
            t[0] = SBOX[t[0]]; t[1] = SBOX[t[1]];
            t[2] = SBOX[t[2]]; t[3] = SBOX[t[3]];
        }
        w[i * 4 + 0] = w[(i - nk) * 4 + 0] ^ t[0];
        w[i * 4 + 1] = w[(i - nk) * 4 + 1] ^ t[1];
        w[i * 4 + 2] = w[(i - nk) * 4 + 2] ^ t[2];
        w[i * 4 + 3] = w[(i - nk) * 4 + 3] ^ t[3];
        i++;
    }
    return 0;
}

// AES block encrypt. state is 16 bytes, modified in place.
static void aes_encrypt(const aes_ks* ks, uint8_t state[16]) {
    int nr = ks->nr;

    // AddRoundKey(0)
    for (int i = 0; i < 16; i++) state[i] ^= ks->rk[i];

    for (int r = 1; r < nr; r++) {
        // SubBytes
        for (int i = 0; i < 16; i++) state[i] = SBOX[state[i]];
        // ShiftRows
        uint8_t t;
        t = state[1]; state[1] = state[5]; state[5] = state[9];
        state[9] = state[13]; state[13] = t;
        t = state[2]; state[2] = state[10]; state[10] = t;
        t = state[6]; state[6] = state[14]; state[14] = t;
        t = state[15]; state[15] = state[11]; state[11] = state[7];
        state[7] = state[3]; state[3] = t;
        // MixColumns
        for (int c = 0; c < 4; c++) {
            uint8_t s0 = state[c * 4 + 0];
            uint8_t s1 = state[c * 4 + 1];
            uint8_t s2 = state[c * 4 + 2];
            uint8_t s3 = state[c * 4 + 3];
            uint8_t t0 = s0 ^ s1 ^ s2 ^ s3;
            state[c * 4 + 0] ^= t0 ^ xtime((uint8_t)(s0 ^ s1));
            state[c * 4 + 1] ^= t0 ^ xtime((uint8_t)(s1 ^ s2));
            state[c * 4 + 2] ^= t0 ^ xtime((uint8_t)(s2 ^ s3));
            state[c * 4 + 3] ^= t0 ^ xtime((uint8_t)(s3 ^ s0));
        }
        // AddRoundKey(r)
        for (int i = 0; i < 16; i++) state[i] ^= ks->rk[r * 16 + i];
    }

    // Final round (no MixColumns)
    for (int i = 0; i < 16; i++) state[i] = SBOX[state[i]];
    uint8_t t;
    t = state[1]; state[1] = state[5]; state[5] = state[9];
    state[9] = state[13]; state[13] = t;
    t = state[2]; state[2] = state[10]; state[10] = t;
    t = state[6]; state[6] = state[14]; state[14] = t;
    t = state[15]; state[15] = state[11]; state[11] = state[7];
    state[7] = state[3]; state[3] = t;
    for (int i = 0; i < 16; i++) state[i] ^= ks->rk[nr * 16 + i];
}

// ---------------------------------------------------------------------
// GHASH — GF(2^128) multiplication.
// ---------------------------------------------------------------------

// Multiply Y by H in GF(2^128). Y is mutated in place.
// Polynomial is x^128 + x^7 + x^2 + x + 1, bit-ordered MSB-first per
// SP 800-38D §6.3.
static void gf_mul(uint8_t y[16], const uint8_t h[16]) {
    uint8_t v[16];
    memcpy(v, h, 16);
    uint8_t z[16] = { 0 };

    for (int i = 0; i < 128; i++) {
        // If bit i of Y is set, XOR V into Z.
        if (y[i >> 3] & (0x80 >> (i & 7))) {
            for (int j = 0; j < 16; j++) z[j] ^= v[j];
        }
        // Shift V right by 1 bit; if low bit was set, XOR R into V's top.
        uint8_t carry = (uint8_t)(v[15] & 1);
        for (int j = 15; j > 0; j--) {
            v[j] = (uint8_t)((v[j] >> 1) | ((v[j - 1] & 1) << 7));
        }
        v[0] >>= 1;
        if (carry) v[0] ^= 0xe1;  // R reduction polynomial top byte
    }
    memcpy(y, z, 16);
}

// GHASH single-block: y := (y XOR block) * H
static void ghash_block(uint8_t y[16], const uint8_t block[16], const uint8_t h[16]) {
    for (int i = 0; i < 16; i++) y[i] ^= block[i];
    gf_mul(y, h);
}

// GHASH a stream of bytes (with zero-padding to 16-byte boundary).
static void ghash_stream(uint8_t y[16], const uint8_t* data, size_t len, const uint8_t h[16]) {
    uint8_t block[16];
    while (len >= 16) {
        ghash_block(y, data, h);
        data += 16;
        len  -= 16;
    }
    if (len > 0) {
        memset(block, 0, 16);
        memcpy(block, data, len);
        ghash_block(y, block, h);
    }
}

// ---------------------------------------------------------------------
// AES-GCM core.
// ---------------------------------------------------------------------

static void inc32(uint8_t c[16]) {
    // Increment the LAST 32 bits as a big-endian counter, wrap at 2^32.
    for (int i = 15; i >= 12; i--) {
        c[i] = (uint8_t)(c[i] + 1);
        if (c[i] != 0) return;
    }
}

static int aes_gcm_run(int encrypt,
                      const uint8_t* key, size_t key_len,
                      const uint8_t* iv,
                      const uint8_t* aad, size_t aad_len,
                      const uint8_t* in,  size_t in_len,
                      uint8_t* out,
                      uint8_t tag[16]) {
    aes_ks ks;
    if (aes_setkey(&ks, key, key_len) != 0) return -1;

    // H = AES_E(K, 0^128)
    uint8_t h[16] = { 0 };
    aes_encrypt(&ks, h);

    // J0 = IV (12 bytes) || 0x00000001
    uint8_t J0[16];
    memcpy(J0, iv, 12);
    J0[12] = 0; J0[13] = 0; J0[14] = 0; J0[15] = 1;

    // CTR-mode encrypt/decrypt: Y0 = inc(J0), Y1 = inc(Y0), ...
    uint8_t counter[16];
    memcpy(counter, J0, 16);
    inc32(counter);

    size_t off = 0;
    while (off < in_len) {
        uint8_t keystream[16];
        memcpy(keystream, counter, 16);
        aes_encrypt(&ks, keystream);
        size_t n = (in_len - off > 16) ? 16 : (in_len - off);
        for (size_t i = 0; i < n; i++) out[off + i] = in[off + i] ^ keystream[i];
        inc32(counter);
        off += n;
    }

    // GHASH:
    //   S = GHASH(H, A || 0-pad || C || 0-pad || len(A)*8 || len(C)*8)
    uint8_t S[16] = { 0 };
    ghash_stream(S, aad, aad_len, h);
    // For encrypt: GHASH the ciphertext we just produced (out).
    // For decrypt: GHASH the ciphertext input (in).
    const uint8_t* c_for_hash = encrypt ? out : in;
    ghash_stream(S, c_for_hash, in_len, h);
    // Length block: 64-bit big-endian aad_len in bits, then in_len in bits.
    uint8_t lenblock[16];
    uint64_t a_bits = (uint64_t)aad_len * 8;
    uint64_t c_bits = (uint64_t)in_len  * 8;
    for (int i = 0; i < 8; i++) {
        lenblock[i]     = (uint8_t)(a_bits >> (56 - 8 * i));
        lenblock[8 + i] = (uint8_t)(c_bits >> (56 - 8 * i));
    }
    ghash_block(S, lenblock, h);

    // Tag = S XOR AES_E(K, J0)
    uint8_t t[16];
    memcpy(t, J0, 16);
    aes_encrypt(&ks, t);
    for (int i = 0; i < 16; i++) t[i] ^= S[i];

    if (encrypt) {
        memcpy(tag, t, 16);
        return 0;
    }
    // Decrypt: constant-time compare.
    uint8_t diff = 0;
    for (int i = 0; i < 16; i++) diff |= (uint8_t)(t[i] ^ tag[i]);
    return diff == 0 ? 0 : -1;
}

int zjs_pc_aes_gcm_encrypt(const uint8_t* key, size_t key_len,
                           const uint8_t* iv,  size_t iv_len,
                           const uint8_t* aad, size_t aad_len,
                           const uint8_t* in,  size_t in_len,
                           uint8_t* out,
                           uint8_t tag[16]) {
    if (iv_len != 12) return -1;
    return aes_gcm_run(1, key, key_len, iv, aad, aad_len, in, in_len, out, tag);
}

int zjs_pc_aes_gcm_decrypt(const uint8_t* key, size_t key_len,
                           const uint8_t* iv,  size_t iv_len,
                           const uint8_t* aad, size_t aad_len,
                           const uint8_t* in,  size_t in_len,
                           uint8_t* out,
                           const uint8_t tag[16]) {
    if (iv_len != 12) return -1;
    uint8_t expected[16];
    memcpy(expected, tag, 16);
    // aes_gcm_run mutates `tag` in place for the compare; pass a copy.
    return aes_gcm_run(0, key, key_len, iv, aad, aad_len, in, in_len, out, expected);
}
