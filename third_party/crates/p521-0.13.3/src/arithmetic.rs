//! Pure Rust implementation of group operations on secp521r1.
//!
//! Curve parameters can be found in [NIST SP 800-186] § 3.2.1.5: P-521.
//!
//! [NIST SP 800-186]: https://csrc.nist.gov/publications/detail/sp/800-186/final

pub(crate) mod field;
#[cfg(feature = "hash2curve")]
mod hash2curve;
pub(crate) mod scalar;
mod util;

pub use self::scalar::Scalar;

use self::field::FieldElement;
use crate::NistP521;
use elliptic_curve::{CurveArithmetic, PrimeCurveArithmetic};
use primeorder::{point_arithmetic, PrimeCurveParams};

/// Elliptic curve point in affine coordinates.
pub type AffinePoint = primeorder::AffinePoint<NistP521>;

/// Elliptic curve point in projective coordinates.
pub type ProjectivePoint = primeorder::ProjectivePoint<NistP521>;

impl CurveArithmetic for NistP521 {
    type AffinePoint = AffinePoint;
    type ProjectivePoint = ProjectivePoint;
    type Scalar = Scalar;
}

impl PrimeCurveArithmetic for NistP521 {
    type CurveGroup = ProjectivePoint;
}

/// Adapted from [NIST SP 800-186] § 3.2.1.5: P-521.
///
/// [NIST SP 800-186]: https://csrc.nist.gov/publications/detail/sp/800-186/final
impl PrimeCurveParams for NistP521 {
    type FieldElement = FieldElement;
    type PointArithmetic = point_arithmetic::EquationAIsMinusThree;

    /// a = -3 (0x1ff ffffffff ffffffff ffffffff ffffffff ffffffff ffffffff
    ///               ffffffff ffffffff ffffffff ffffffff ffffffff ffffffff
    ///               ffffffff ffffffff ffffffff fffffffc)
    const EQUATION_A: FieldElement = FieldElement::from_u64(3).neg();

    /// b = 0x051 953eb961 8e1c9a1f 929a21a0 b68540ee a2da725b 99b315f3
    ///           b8b48991 8ef109e1 56193951 ec7e937b 1652c0bd 3bb1bf07
    ///           3573df88 3d2c34f1 ef451fd4 6b503f00
    const EQUATION_B: FieldElement =
        FieldElement::from_hex("0000000000000051953eb9618e1c9a1f929a21a0b68540eea2da725b99b315f3b8b489918ef109e156193951ec7e937b1652c0bd3bb1bf073573df883d2c34f1ef451fd46b503f00");

    /// Base point of P-521.
    ///
    /// ```text
    /// Gₓ = 0x0c6 858e06b7 0404e9cd 9e3ecb66 2395b442 9c648139 053fb521
    ///            f828af60 6b4d3dba a14b5e77 efe75928 fe1dc127 a2ffa8de
    ///            3348b3c1 856a429b f97e7e31 c2e5bd66
    /// Gᵧ = 0x118 39296a78 9a3bc004 5c8a5fb4 2c7d1bd9 98f54449 579b4468
    ///            17afbd17 273e662c 97ee7299 5ef42640 c550b901 3fad0761
    ///            353c7086 a272c240 88be9476 9fd16650
    /// ```
    const GENERATOR: (FieldElement, FieldElement) = (
        FieldElement::from_hex("00000000000000c6858e06b70404e9cd9e3ecb662395b4429c648139053fb521f828af606b4d3dbaa14b5e77efe75928fe1dc127a2ffa8de3348b3c1856a429bf97e7e31c2e5bd66"),
        FieldElement::from_hex("000000000000011839296a789a3bc0045c8a5fb42c7d1bd998f54449579b446817afbd17273e662c97ee72995ef42640c550b9013fad0761353c7086a272c24088be94769fd16650"),
    );
}
