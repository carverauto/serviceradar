#![no_std]
#![doc = include_str!("../README.md")]
#![forbid(unsafe_code, clippy::unwrap_used)]
#![warn(missing_docs, rust_2018_idioms)]
#![doc(
    html_logo_url = "https://raw.githubusercontent.com/RustCrypto/media/8f1a9894/logo.svg",
    html_favicon_url = "https://raw.githubusercontent.com/RustCrypto/media/8f1a9894/logo.svg"
)]

//! ## Usage
//!
//! See also: the documentation for the [`generate_k`] function.
//!
//! ```
//! use hex_literal::hex;
//! use rfc6979::consts::U32;
//! use sha2::{Digest, Sha256};
//!
//! // NIST P-256 field modulus
//! const NIST_P256_MODULUS: [u8; 32] =
//!     hex!("FFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551");
//!
//! // Public key for RFC6979 NIST P256/SHA256 test case
//! const RFC6979_KEY: [u8; 32] =
//!     hex!("C9AFA9D845BA75166B5C215767B1D6934E50C3DB36E89B127B8A622B120F6721");
//!
//! // Test message for RFC6979 NIST P256/SHA256 test case
//! const RFC6979_MSG: &[u8; 6] = b"sample";
//!
//! // Expected K for RFC6979 NIST P256/SHA256 test case
//! const RFC6979_EXPECTED_K: [u8; 32] =
//!     hex!("A6E3C57DD01ABE90086538398355DD4C3B17AA873382B0F24D6129493D8AAD60");
//!
//! let h = Sha256::digest(RFC6979_MSG);
//! let aad = b"";
//! let k = rfc6979::generate_k::<Sha256, U32>(&RFC6979_KEY.into(), &NIST_P256_MODULUS.into(), &h, aad);
//! assert_eq!(k.as_slice(), &RFC6979_EXPECTED_K);
//! ```

mod ct;

pub use hmac::digest::array::typenum::consts;

use hmac::{
    SimpleHmacReset,
    digest::{
        Digest, FixedOutput, FixedOutputReset, KeyInit, Mac,
        array::{Array, ArraySize},
        block_api::BlockSizeUser,
    },
};

/// Deterministically generate ephemeral scalar `k`.
///
/// Accepts the following parameters and inputs:
///
/// - `x`: secret key
/// - `q`: field modulus
/// - `h`: hash/digest of input message: must be reduced modulo `q` in advance
/// - `data`: additional associated data, e.g. CSRNG output used as added entropy
#[inline]
pub fn generate_k<D, N>(
    x: &Array<u8, N>,
    q: &Array<u8, N>,
    h: &Array<u8, N>,
    data: &[u8],
) -> Array<u8, N>
where
    D: Digest + BlockSizeUser + FixedOutput + FixedOutputReset,
    N: ArraySize,
{
    let mut k = Array::default();
    generate_k_mut::<D>(x, q, h, data, &mut k);
    k
}

/// Deterministically generate ephemeral scalar `k` by writing it into the provided output buffer.
///
/// This is an API which accepts dynamically sized inputs intended for use cases where the sizes
/// are determined at runtime, such as the legacy Digital Signature Algorithm (DSA).
///
/// Accepts the following parameters and inputs:
///
/// - `x`: secret key
/// - `q`: field modulus
/// - `h`: hash/digest of input message: must be reduced modulo `q` in advance
/// - `data`: additional associated data, e.g. CSRNG output used as added entropy
#[inline]
pub fn generate_k_mut<D>(x: &[u8], q: &[u8], h: &[u8], data: &[u8], k: &mut [u8])
where
    D: Digest + BlockSizeUser + FixedOutput + FixedOutputReset,
{
    let k_len = k.len();
    assert_eq!(k_len, x.len());
    assert_eq!(k_len, q.len());
    assert_eq!(k_len, h.len());
    debug_assert!(bool::from(ct::lt(h, q)));

    let q_leading_zeros = ct::leading_zeros(q);
    let q_has_leading_zeros = q_leading_zeros != 0;
    let mut hmac_drbg = HmacDrbg::<D>::new(x, h, data);

    loop {
        hmac_drbg.fill_bytes(k);

        if q_has_leading_zeros {
            ct::rshift(k, q_leading_zeros);
        }

        if (!ct::is_zero(k) & ct::lt(k, q)).into() {
            return;
        }
    }
}

/// Internal implementation of `HMAC_DRBG` as described in NIST SP800-90A.
///
/// <https://csrc.nist.gov/publications/detail/sp/800-90a/rev-1/final>
///
/// This is a HMAC-based deterministic random bit generator used compute a
/// deterministic ephemeral scalar `k`.
pub struct HmacDrbg<D>
where
    D: Digest + BlockSizeUser + FixedOutputReset,
{
    /// HMAC key `K` (see RFC 6979 Section 3.2.c)
    k: SimpleHmacReset<D>,

    /// Chaining value `V` (see RFC 6979 Section 3.2.c)
    v: Array<u8, D::OutputSize>,
}

impl<D> HmacDrbg<D>
where
    D: Digest + BlockSizeUser + FixedOutputReset,
{
    /// Initialize `HMAC_DRBG`
    pub fn new(entropy_input: &[u8], nonce: &[u8], personalization_string: &[u8]) -> Self {
        let mut k = SimpleHmacReset::new(&Default::default());
        let mut v = Array::default();

        v.fill(0x01);

        for i in 0..=1 {
            k.update(&v);
            k.update(&[i]);
            k.update(entropy_input);
            k.update(nonce);
            k.update(personalization_string);
            k = SimpleHmacReset::new_from_slice(&k.finalize().into_bytes()).expect("HMAC error");

            // Steps 3.2.e,g: v = HMAC_k(v)
            k.update(&v);
            v = k.finalize_reset().into_bytes();
        }

        Self { k, v }
    }

    /// Write the next `HMAC_DRBG` output to the given byte slice.
    pub fn fill_bytes(&mut self, out: &mut [u8]) {
        let mut out_chunks = out.chunks_exact_mut(self.v.len());

        for out_chunk in &mut out_chunks {
            self.k.update(&self.v);
            self.v = self.k.finalize_reset().into_bytes();
            out_chunk.copy_from_slice(&self.v[..out_chunk.len()]);
        }

        let out_remainder = out_chunks.into_remainder();
        if !out_remainder.is_empty() {
            self.k.update(&self.v);
            self.v = self.k.finalize_reset().into_bytes();
            out_remainder.copy_from_slice(&self.v[..out_remainder.len()]);
        }

        self.k.update(&self.v);
        self.k.update(&[0x00]);
        self.k = SimpleHmacReset::new_from_slice(&self.k.finalize_reset().into_bytes())
            .expect("HMAC error");
        self.k.update(&self.v);
        self.v = self.k.finalize_reset().into_bytes();
    }
}

#[cfg(test)]
mod tests {
    use crate::{
        Array,
        consts::{U21, U66},
        generate_k,
    };
    use hex_literal::hex;
    use sha2::{Digest, Sha256, Sha512};

    /// "Detailed Example" from RFC6979 Appendix A.1.
    ///
    /// Example for ECDSA on the curve K-163 described in FIPS 186-4 (also known as
    /// "ansix9t163k1" in X9.62), defined over a field GF(2^163)
    #[test]
    fn k163_sha256() {
        let q = hex!("04000000000000000000020108A2E0CC0D99F8A5EF");
        let x = hex!("009A4D6792295A7F730FC3F2B49CBC0F62E862272F");

        // Note: SHA-256 digest of "sample" with the output run through `bits2octets` transform
        let h2 = hex!("01795EDF0D54DB760F156D0DAC04C0322B3A204224");

        let aad = b"";
        let k = generate_k::<Sha256, U21>(&x.into(), &q.into(), &h2.into(), aad);
        assert_eq!(k, hex!("023AF4074C90A02B3FE61D286D5C87F425E6BDD81B"));
    }

    /// Example from RFC6979 Appendix A.2.7.
    #[test]
    fn p521_sha512() {
        let q = hex!(
            "01FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFA51868783BF2F966B7FCC0148F709A5D03BB5C9B8899C47AEBB6FB71E91386409"
        );

        let x = hex!(
            "00FAD06DAA62BA3B25D2FB40133DA757205DE67F5BB0018FEE8C86E1B68C7E75CAA896EB32F1F47C70855836A6D16FCC1466F6D8FBEC67DB89EC0C08B0E996B83538"
        );

        // Hash message and emulate `bits2octets` to produce the input digest
        let message = "sample";
        let mut h = Array::<u8, U66>::default();
        h[2..].copy_from_slice(&Sha512::digest(message));

        let aad = b"";
        let k = generate_k::<Sha512, U66>(&x.into(), &q.into(), &h, aad);

        let expected_k = hex!(
            "01DAE2EA071F8110DC26882D4D5EAE0621A3256FC8847FB9022E2B7D28E6F10198B1574FDD03A9053C08A1854A168AA5A57470EC97DD5CE090124EF52A2F7ECBFFD3"
        );

        assert_eq!(k, expected_k);
    }
}
