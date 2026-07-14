// Copyright (c) 1998-2007 The OpenSSL Project.  All rights reserved.
// SPDX-License-Identifier: Apache-2.0

#include <assert.h>

#include <openssl/digest.h>
#include <openssl/hkdf.h>
#include <openssl/hmac.h>
#include <openssl/mem.h>

#include "../../internal.h"

// tls1_P_hash computes the TLS P_<hash> function as described in RFC 5246,
// section 5. It XORs |out_len| bytes to |out|, using |md| as the hash and
// |secret| as the secret. |label|, |seed1|, and |seed2| are concatenated to
// form the seed parameter. It returns true on success and false on failure.
static int tls1_P_hash(uint8_t *out, size_t out_len,
                       const EVP_MD *md,
                       const uint8_t *secret, size_t secret_len,
                       const char *label, size_t label_len,
                       const uint8_t *seed1, size_t seed1_len,
                       const uint8_t *seed2, size_t seed2_len) {
  HMAC_CTX ctx, ctx_tmp, ctx_init;
  uint8_t A1[EVP_MAX_MD_SIZE];
  unsigned A1_len;
  int ret = 0;

  const size_t chunk = EVP_MD_size(md);
  HMAC_CTX_init(&ctx);
  HMAC_CTX_init(&ctx_tmp);
  HMAC_CTX_init(&ctx_init);

  if (!HMAC_Init_ex(&ctx_init, secret, secret_len, md, NULL) ||
      !HMAC_CTX_copy_ex(&ctx, &ctx_init) ||
      !HMAC_Update(&ctx, (const uint8_t *) label, label_len) ||
      !HMAC_Update(&ctx, seed1, seed1_len) ||
      !HMAC_Update(&ctx, seed2, seed2_len) ||
      !HMAC_Final(&ctx, A1, &A1_len)) {
    goto err;
  }

  for (;;) {
    unsigned len_u;
    uint8_t hmac[EVP_MAX_MD_SIZE];
    if (!HMAC_CTX_copy_ex(&ctx, &ctx_init) ||
        !HMAC_Update(&ctx, A1, A1_len) ||
        // Save a copy of |ctx| to compute the next A1 value below.
        (out_len > chunk && !HMAC_CTX_copy_ex(&ctx_tmp, &ctx)) ||
        !HMAC_Update(&ctx, (const uint8_t *) label, label_len) ||
        !HMAC_Update(&ctx, seed1, seed1_len) ||
        !HMAC_Update(&ctx, seed2, seed2_len) ||
        !HMAC_Final(&ctx, hmac, &len_u)) {
      goto err;
    }
    size_t len = len_u;
    assert(len == chunk);

    // XOR the result into |out|.
    if (len > out_len) {
      len = out_len;
    }
    for (size_t i = 0; i < len; i++) {
      out[i] ^= hmac[i];
    }
    out += len;
    out_len -= len;

    if (out_len == 0) {
      break;
    }

    // Calculate the next A1 value.
    if (!HMAC_Final(&ctx_tmp, A1, &A1_len)) {
      goto err;
    }
  }

  ret = 1;

err:
  OPENSSL_cleanse(A1, sizeof(A1));
  HMAC_CTX_cleanup(&ctx);
  HMAC_CTX_cleanup(&ctx_tmp);
  HMAC_CTX_cleanup(&ctx_init);
  return ret;
}

int CRYPTO_tls1_prf(const EVP_MD *digest,
                    uint8_t *out, size_t out_len,
                    const uint8_t *secret, size_t secret_len,
                    const char *label, size_t label_len,
                    const uint8_t *seed1, size_t seed1_len,
                    const uint8_t *seed2, size_t seed2_len) {
  // We have to avoid the underlying HMAC services updating the indicator state,
  // so we lock the state here.
  FIPS_service_indicator_lock_state();
  SET_DIT_AUTO_RESET;
  int ret = 0;
  const EVP_MD *original_digest = digest;
  if (out_len == 0) {
    ret = 1;
    goto end;
  }

  OPENSSL_memset(out, 0, out_len);

  if (digest == EVP_md5_sha1()) {
    // If using the MD5/SHA1 PRF, |secret| is partitioned between MD5 and SHA-1.
    size_t secret_half = secret_len - (secret_len / 2);
    if (!tls1_P_hash(out, out_len, EVP_md5(), secret, secret_half, label,
                     label_len, seed1, seed1_len, seed2, seed2_len)) {
      goto end;
    }

    // Note that, if |secret_len| is odd, the two halves share a byte.
    secret += secret_len - secret_half;
    secret_len = secret_half;
    digest = EVP_sha1();
  }

  ret = tls1_P_hash(out, out_len, digest, secret, secret_len, label, label_len,
                     seed1, seed1_len, seed2, seed2_len);
end:
  FIPS_service_indicator_unlock_state();
  if(ret) {
    TLSKDF_verify_service_indicator(original_digest, label, label_len);
  }
  return ret;
}
