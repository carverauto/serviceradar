//! Low-level ECDSA primitives.
//!
//! # ⚠️ Warning: Hazmat!
//!
//! YOU PROBABLY DON'T WANT TO USE THESE!
//!
//! These primitives are easy-to-misuse low-level interfaces.
//!
//! If you are an end user / non-expert in cryptography, do not use these!
//! Failure to use them correctly can lead to catastrophic failures including
//! FULL PRIVATE KEY RECOVERY!

use crate::{EcdsaCurve, Error, Result};
use core::cmp;
use elliptic_curve::{FieldBytes, array::typenum::Unsigned};

#[cfg(feature = "arithmetic")]
use {
    crate::{RecoveryId, SignatureSize},
    elliptic_curve::{
        CurveArithmetic, NonZeroScalar, ProjectivePoint, Scalar,
        ff::PrimeField,
        group::{Curve as _, Group},
        ops::{Invert, LinearCombination, Reduce},
        point::AffineCoordinates,
        scalar::IsHigh,
    },
};

#[cfg(feature = "digest")]
use signature::digest::{Digest, FixedOutput, FixedOutputReset, block_api::BlockSizeUser};

#[cfg(feature = "rfc6979")]
use elliptic_curve::FieldBytesEncoding;

#[cfg(any(feature = "arithmetic", feature = "rfc6979"))]
use crate::{Signature, elliptic_curve::array::ArraySize};

/// Bind a preferred [`Digest`] algorithm to an elliptic curve type.
///
/// Generally there is a preferred variety of the SHA-2 family used with ECDSA
/// for a particular elliptic curve.
#[cfg(feature = "digest")]
pub trait DigestAlgorithm: EcdsaCurve {
    /// Preferred digest to use when computing ECDSA signatures for this
    /// elliptic curve. This is typically a member of the SHA-2 family.
    type Digest: BlockSizeUser + Digest + FixedOutput + FixedOutputReset;
}

/// Partial implementation of the `bits2int` function as defined in
/// [RFC6979 § 2.3.2] as well as [SEC1] § 2.3.8.
///
/// This is used to convert a message digest whose size may be smaller or
/// larger than the size of the curve's scalar field into a serialized
/// (unreduced) field element.
///
/// [RFC6979 § 2.3.2]: https://datatracker.ietf.org/doc/html/rfc6979#section-2.3.2
/// [SEC1]: https://www.secg.org/sec1-v2.pdf
pub fn bits2field<C: EcdsaCurve>(bits: &[u8]) -> Result<FieldBytes<C>> {
    // Minimum allowed bits size is half the field size
    if bits.len() < C::FieldBytesSize::USIZE / 2 {
        return Err(Error::new());
    }

    let mut field_bytes = FieldBytes::<C>::default();

    match bits.len().cmp(&C::FieldBytesSize::USIZE) {
        cmp::Ordering::Equal => field_bytes.copy_from_slice(bits),
        cmp::Ordering::Less => {
            // If bits is smaller than the field size, pad with zeroes on the left
            field_bytes[(C::FieldBytesSize::USIZE - bits.len())..].copy_from_slice(bits);
        }
        cmp::Ordering::Greater => {
            // If bits is larger than the field size, truncate
            field_bytes.copy_from_slice(&bits[..C::FieldBytesSize::USIZE]);
        }
    }

    Ok(field_bytes)
}

/// Sign a prehashed message digest using the provided secret scalar and
/// ephemeral scalar, returning an ECDSA signature.
///
/// Accepts the following arguments:
///
/// - `d`: signing key. MUST BE UNIFORMLY RANDOM!!!
/// - `k`: ephemeral scalar value. MUST BE UNIFORMLY RANDOM!!!
/// - `z`: message digest to be signed. MUST BE OUTPUT OF A CRYPTOGRAPHICALLY
///   SECURE DIGEST ALGORITHM!!!
///
/// # Low-S Normalization
///
/// This function will apply low-S normalization if `<C as EcdsaCurve>::NORMALIZE_S` is true.
///
/// # Returns
///
/// ECDSA [`Signature`] and a [`RecoveryId`] which can be used to recover the verifying key for a
/// given signature.
///
/// # Errors
///
/// This will return an error if a zero-scalar was generated. It can be tried again with a
/// different `k`.
#[cfg(feature = "arithmetic")]
#[allow(non_snake_case)]
pub fn sign_prehashed<C>(
    d: &NonZeroScalar<C>,
    k: &NonZeroScalar<C>,
    z: &FieldBytes<C>,
) -> Result<(Signature<C>, RecoveryId)>
where
    C: EcdsaCurve + CurveArithmetic,
    SignatureSize<C>: ArraySize,
{
    let z = Scalar::<C>::reduce(z);

    // Compute scalar inversion of 𝑘.
    let k_inv = k.invert();

    // Compute 𝑹 = 𝑘×𝑮.
    let R = ProjectivePoint::<C>::mul_by_generator(k).to_affine();

    // Lift x-coordinate of 𝑹 (element of base field) into a serialized big
    // integer, then reduce it into an element of the scalar field.
    let r = Scalar::<C>::reduce(&R.x());

    // Compute 𝒔 as a signature over 𝒓 and 𝒛.
    let s = *k_inv * (z + (r * d.as_ref()));

    // NOTE: `Signature::from_scalars` checks that both `r` and `s` are non-zero.
    let mut signature = Signature::from_scalars(r, s)?;

    // Compute recovery ID.
    let x_is_reduced = r.to_repr() != R.x();
    let y_is_odd = R.y_is_odd();
    let mut recovery_id = RecoveryId::new(y_is_odd.into(), x_is_reduced);

    // Apply low-S normalization if the curve is configured for it
    if C::NORMALIZE_S {
        recovery_id.0 ^= s.is_high().unwrap_u8();
        signature = signature.normalize_s();
    }

    Ok((signature, recovery_id))
}

/// Try to sign the given message digest deterministically using the method
/// described in [RFC6979] for computing ECDSA ephemeral scalar `k`.
///
/// Accepts the following parameters:
/// - `d`: signing key. MUST BE UNIFORMLY RANDOM!!!
/// - `z`: message digest to be signed, i.e. `H(m)`. Does not have to be reduced in advance.
/// - `ad`: optional additional data, e.g. added entropy from an RNG
///
/// # Errors
///
/// This will return an error if a zero-scalar was generated. It can be tried again with different
/// entropy `ad`.
///
/// [RFC6979]: https://datatracker.ietf.org/doc/html/rfc6979
#[cfg(feature = "rfc6979")]
pub fn sign_prehashed_rfc6979<C, D>(
    d: &NonZeroScalar<C>,
    z: &FieldBytes<C>,
    ad: &[u8],
) -> Result<(Signature<C>, RecoveryId)>
where
    C: EcdsaCurve + CurveArithmetic,
    D: Digest + BlockSizeUser + FixedOutput + FixedOutputReset,
    SignatureSize<C>: ArraySize,
{
    // From RFC6979 § 2.4:
    //
    // H(m) is transformed into an integer modulo q using the bits2int
    // transform and an extra modular reduction:
    //
    // h = bits2int(H(m)) mod q
    let z2 = Scalar::<C>::reduce(z);

    let k = NonZeroScalar::<C>::from_repr(rfc6979::generate_k::<D, _>(
        &d.to_repr(),
        &C::ORDER.encode_field_bytes(),
        &z2.to_repr(),
        ad,
    ))
    .unwrap();

    sign_prehashed(d, &k, z)
}

/// Verify the prehashed message against the provided ECDSA signature.
///
/// Accepts the following arguments:
///
/// - `q`: public key with which to verify the signature.
/// - `z`: message digest to be verified. MUST BE OUTPUT OF A CRYPTOGRAPHICALLY SECURE DIGEST
///   ALGORITHM!!!
/// - `sig`: signature to be verified against the key and message.
///
/// # Low-S Normalization
///
/// This is a low-level function that does *NOT* apply the `EcdsaCurve::NORMALIZE_S` checks.
#[cfg(feature = "arithmetic")]
pub fn verify_prehashed<C>(
    q: &ProjectivePoint<C>,
    z: &FieldBytes<C>,
    sig: &Signature<C>,
) -> Result<()>
where
    C: EcdsaCurve + CurveArithmetic,
    SignatureSize<C>: ArraySize,
{
    let z = Scalar::<C>::reduce(z);
    let (r, s) = sig.split_scalars();
    let s_inv = *s.invert_vartime();
    let u1 = z * s_inv;
    let u2 = *r * s_inv;
    let x = ProjectivePoint::<C>::lincomb(&[(ProjectivePoint::<C>::generator(), u1), (*q, u2)])
        .to_affine()
        .x();

    if *r == Scalar::<C>::reduce(&x) {
        Ok(())
    } else {
        Err(Error::new())
    }
}

#[cfg(all(test, feature = "dev"))]
mod tests {
    use super::bits2field;
    use elliptic_curve::dev::MockCurve;
    use hex_literal::hex;

    #[test]
    fn bits2field_too_small() {
        assert!(bits2field::<MockCurve>(b"").is_err());
    }

    #[test]
    fn bits2field_size_less() {
        let prehash = hex!("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
        let field_bytes = bits2field::<MockCurve>(&prehash).expect("field bytes");
        assert_eq!(
            field_bytes.as_slice(),
            &hex!("00000000000000000000000000000000AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
        );
    }

    #[test]
    fn bits2field_size_eq() {
        let prehash = hex!("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
        let field_bytes = bits2field::<MockCurve>(&prehash).expect("field bytes");
        assert_eq!(field_bytes.as_slice(), &prehash);
    }

    #[test]
    fn bits2field_size_greater() {
        let prehash = hex!(
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
        );
        let field_bytes = bits2field::<MockCurve>(&prehash).expect("field bytes");
        assert_eq!(
            field_bytes.as_slice(),
            &hex!("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
        );
    }
}
