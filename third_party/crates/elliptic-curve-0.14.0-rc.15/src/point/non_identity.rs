//! Non-identity point type.

#![cfg(feature = "arithmetic")]

use core::ops::{Deref, Mul};

use group::{Group, GroupEncoding, prime::PrimeCurveAffine};
use rand_core::{CryptoRng, TryCryptoRng};
use subtle::{Choice, ConditionallySelectable, ConstantTimeEq, CtOption};

#[cfg(feature = "alloc")]
use alloc::vec::Vec;

#[cfg(feature = "serde")]
use serdect::serde::{Deserialize, Serialize, de, ser};
use zeroize::Zeroize;

use crate::{BatchNormalize, CurveArithmetic, CurveGroup, NonZeroScalar, Scalar};

/// Non-identity point type.
///
/// This type ensures that its value is not the identity point, ala `core::num::NonZero*`.
///
/// In the context of ECC, it's useful for ensuring that certain arithmetic
/// cannot result in the identity point.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(transparent)] // SAFETY: needed for `unsafe` safety invariants below
pub struct NonIdentity<P> {
    point: P,
}

impl<P> NonIdentity<P>
where
    P: ConditionallySelectable + ConstantTimeEq + Default,
{
    /// Create a [`NonIdentity`] from a point.
    pub fn new(point: P) -> CtOption<Self> {
        CtOption::new(Self { point }, !point.ct_eq(&P::default()))
    }

    pub(crate) fn new_unchecked(point: P) -> Self {
        Self { point }
    }
}

impl<P> NonIdentity<P>
where
    P: ConditionallySelectable + ConstantTimeEq + Default + GroupEncoding,
{
    /// Decode a [`NonIdentity`] from its encoding.
    pub fn from_repr(repr: &P::Repr) -> CtOption<Self> {
        Self::from_bytes(repr)
    }
}

impl<P> NonIdentity<P> {
    /// Transform array reference containing [`NonIdentity`] points to an array reference to the
    /// inner point type.
    pub fn cast_array_as_inner<const N: usize>(points: &[Self; N]) -> &[P; N] {
        // SAFETY: `NonIdentity` is a `repr(transparent)` newtype for `P` so it's safe to cast to
        // the inner `P` type.
        #[allow(unsafe_code)]
        unsafe {
            &*points.as_ptr().cast()
        }
    }

    /// Transform slice containing [`NonIdentity`] points to a slice of the inner point type.
    pub fn cast_slice_as_inner(points: &[Self]) -> &[P] {
        // SAFETY: `NonIdentity` is a `repr(transparent)` newtype for `P` so it's safe to cast to
        // the inner `P` type.
        #[allow(unsafe_code)]
        unsafe {
            &*(points as *const [NonIdentity<P>] as *const [P])
        }
    }
}

impl<P: Copy> NonIdentity<P> {
    /// Return wrapped point.
    pub fn to_point(self) -> P {
        self.point
    }
}

impl<P> NonIdentity<P>
where
    P: ConditionallySelectable + ConstantTimeEq + CurveGroup + Default,
{
    /// Generate a random `NonIdentity<ProjectivePoint>`.
    pub fn random<R: CryptoRng + ?Sized>(rng: &mut R) -> Self {
        loop {
            if let Some(point) = Self::new(P::random(rng)).into() {
                break point;
            }
        }
    }

    /// Generate a random `NonIdentity<ProjectivePoint>`.
    pub fn try_from_rng<R: TryCryptoRng + ?Sized>(rng: &mut R) -> Result<Self, R::Error> {
        loop {
            if let Some(point) = Self::new(P::try_from_rng(rng)?).into() {
                break Ok(point);
            }
        }
    }

    /// Converts this element into its affine representation.
    pub fn to_affine(self) -> NonIdentity<P::AffineRepr> {
        NonIdentity {
            point: self.point.to_affine(),
        }
    }

    /// Multiply by the generator of the prime-order subgroup.
    pub fn mul_by_generator<C: CurveArithmetic>(scalar: &NonZeroScalar<C>) -> Self
    where
        P: Group<Scalar = C::Scalar>,
    {
        Self {
            point: P::mul_by_generator(scalar),
        }
    }
}

impl<P> NonIdentity<P>
where
    P: PrimeCurveAffine,
{
    /// Converts this element to its curve representation.
    pub fn to_curve(self) -> NonIdentity<P::Curve> {
        NonIdentity {
            point: self.point.to_curve(),
        }
    }
}

impl<P> AsRef<P> for NonIdentity<P> {
    fn as_ref(&self) -> &P {
        &self.point
    }
}

impl<const N: usize, P> BatchNormalize<[Self; N]> for NonIdentity<P>
where
    P: CurveGroup + BatchNormalize<[P; N], Output = [P::AffineRepr; N]>,
{
    type Output = [NonIdentity<P::AffineRepr>; N];

    fn batch_normalize(points: &[Self; N]) -> [NonIdentity<P::AffineRepr>; N] {
        let points = Self::cast_array_as_inner::<N>(points);
        let affine_points = <P as BatchNormalize<_>>::batch_normalize(points);
        affine_points.map(|point| NonIdentity { point })
    }
}

#[cfg(feature = "alloc")]
impl<P> BatchNormalize<[Self]> for NonIdentity<P>
where
    P: CurveGroup + BatchNormalize<[P], Output = Vec<P::AffineRepr>>,
{
    type Output = Vec<NonIdentity<P::AffineRepr>>;

    fn batch_normalize(points: &[Self]) -> Vec<NonIdentity<P::AffineRepr>> {
        let points = Self::cast_slice_as_inner(points);
        let affine_points = <P as BatchNormalize<_>>::batch_normalize(points);
        affine_points
            .into_iter()
            .map(|point| NonIdentity { point })
            .collect()
    }
}

impl<P> ConditionallySelectable for NonIdentity<P>
where
    P: ConditionallySelectable,
{
    fn conditional_select(a: &Self, b: &Self, choice: Choice) -> Self {
        Self {
            point: P::conditional_select(&a.point, &b.point, choice),
        }
    }
}

impl<P> ConstantTimeEq for NonIdentity<P>
where
    P: ConstantTimeEq,
{
    fn ct_eq(&self, other: &Self) -> Choice {
        self.point.ct_eq(&other.point)
    }
}

impl<P> Deref for NonIdentity<P> {
    type Target = P;

    fn deref(&self) -> &Self::Target {
        &self.point
    }
}

impl<P> GroupEncoding for NonIdentity<P>
where
    P: ConditionallySelectable + ConstantTimeEq + Default + GroupEncoding,
{
    type Repr = P::Repr;

    fn from_bytes(bytes: &Self::Repr) -> CtOption<Self> {
        let point = P::from_bytes(bytes);
        point.and_then(|point| CtOption::new(Self { point }, !point.ct_eq(&P::default())))
    }

    fn from_bytes_unchecked(bytes: &Self::Repr) -> CtOption<Self> {
        P::from_bytes_unchecked(bytes).map(|point| Self { point })
    }

    fn to_bytes(&self) -> Self::Repr {
        self.point.to_bytes()
    }
}

impl<C, P> Mul<NonZeroScalar<C>> for NonIdentity<P>
where
    C: CurveArithmetic,
    P: Copy + Mul<Scalar<C>, Output = P>,
{
    type Output = NonIdentity<P>;

    fn mul(self, rhs: NonZeroScalar<C>) -> Self::Output {
        &self * &rhs
    }
}

impl<C, P> Mul<&NonZeroScalar<C>> for NonIdentity<P>
where
    C: CurveArithmetic,
    P: Copy + Mul<Scalar<C>, Output = P>,
{
    type Output = NonIdentity<P>;

    fn mul(self, rhs: &NonZeroScalar<C>) -> Self::Output {
        self * *rhs
    }
}

impl<C, P> Mul<NonZeroScalar<C>> for &NonIdentity<P>
where
    C: CurveArithmetic,
    P: Copy + Mul<Scalar<C>, Output = P>,
{
    type Output = NonIdentity<P>;

    fn mul(self, rhs: NonZeroScalar<C>) -> Self::Output {
        NonIdentity {
            point: self.point * *rhs.as_ref(),
        }
    }
}

impl<C, P> Mul<&NonZeroScalar<C>> for &NonIdentity<P>
where
    C: CurveArithmetic,
    P: Copy + Mul<Scalar<C>, Output = P>,
{
    type Output = NonIdentity<P>;

    fn mul(self, rhs: &NonZeroScalar<C>) -> Self::Output {
        self * *rhs
    }
}

#[cfg(feature = "serde")]
impl<P> Serialize for NonIdentity<P>
where
    P: Serialize,
{
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: ser::Serializer,
    {
        self.point.serialize(serializer)
    }
}

#[cfg(feature = "serde")]
impl<'de, P> Deserialize<'de> for NonIdentity<P>
where
    P: ConditionallySelectable + ConstantTimeEq + Default + Deserialize<'de> + GroupEncoding,
{
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: de::Deserializer<'de>,
    {
        Self::new(P::deserialize(deserializer)?)
            .into_option()
            .ok_or_else(|| de::Error::custom("expected non-identity point"))
    }
}

impl<P: Group> Zeroize for NonIdentity<P> {
    fn zeroize(&mut self) {
        self.point = P::generator();
    }
}

#[cfg(all(test, feature = "dev"))]
mod tests {
    use super::NonIdentity;
    use crate::BatchNormalize;
    use crate::dev::{AffinePoint, NonZeroScalar, ProjectivePoint, SecretKey};
    use group::GroupEncoding;
    use hex_literal::hex;
    use zeroize::Zeroize;

    #[test]
    fn new_success() {
        let point = ProjectivePoint::from_bytes(
            &hex!("02c9afa9d845ba75166b5c215767b1d6934e50c3db36e89b127b8a622b120f6721").into(),
        )
        .unwrap();

        assert!(bool::from(NonIdentity::new(point).is_some()));

        assert!(bool::from(
            NonIdentity::new(AffinePoint::from(point)).is_some()
        ));
    }

    #[test]
    fn new_fail() {
        assert!(bool::from(
            NonIdentity::new(ProjectivePoint::default()).is_none()
        ));
        assert!(bool::from(
            NonIdentity::new(AffinePoint::default()).is_none()
        ));
    }

    #[test]
    fn round_trip() {
        let bytes = hex!("02c9afa9d845ba75166b5c215767b1d6934e50c3db36e89b127b8a622b120f6721");
        let point = NonIdentity::<ProjectivePoint>::from_repr(&bytes.into()).unwrap();
        assert_eq!(&bytes, point.to_bytes().as_slice());

        let bytes = hex!("02c9afa9d845ba75166b5c215767b1d6934e50c3db36e89b127b8a622b120f6721");
        let point = NonIdentity::<AffinePoint>::from_repr(&bytes.into()).unwrap();
        assert_eq!(&bytes, point.to_bytes().as_slice());
    }

    #[test]
    fn zeroize() {
        let point = ProjectivePoint::from_bytes(
            &hex!("02c9afa9d845ba75166b5c215767b1d6934e50c3db36e89b127b8a622b120f6721").into(),
        )
        .unwrap();
        let mut point = NonIdentity::new(point).unwrap();
        point.zeroize();

        assert_eq!(point.to_point(), ProjectivePoint::Generator);
    }

    #[test]
    fn mul_by_generator() {
        let scalar = NonZeroScalar::from_repr(
            hex!("c9afa9d845ba75166b5c215767b1d6934e50c3db36e89b127b8a622b120f6721").into(),
        )
        .unwrap();
        let point = NonIdentity::<ProjectivePoint>::mul_by_generator(&scalar);

        let sk = SecretKey::from(scalar);
        let pk = sk.public_key();

        assert_eq!(point.to_point(), pk.to_projective());
    }

    #[test]
    fn batch_normalize() {
        let point = ProjectivePoint::from_bytes(
            &hex!("02c9afa9d845ba75166b5c215767b1d6934e50c3db36e89b127b8a622b120f6721").into(),
        )
        .unwrap();
        let point = NonIdentity::new(point).unwrap();
        let points = [point, point];

        for (point, affine_point) in points
            .into_iter()
            .zip(NonIdentity::batch_normalize(&points))
        {
            assert_eq!(point.to_affine(), affine_point);
        }
    }

    #[test]
    #[cfg(feature = "alloc")]
    fn batch_normalize_alloc() {
        let point = ProjectivePoint::from_bytes(
            &hex!("02c9afa9d845ba75166b5c215767b1d6934e50c3db36e89b127b8a622b120f6721").into(),
        )
        .unwrap();
        let point = NonIdentity::new(point).unwrap();
        let points = vec![point, point];

        let affine_points = NonIdentity::batch_normalize(points.as_slice());

        for (point, affine_point) in points.into_iter().zip(affine_points) {
            assert_eq!(point.to_affine(), affine_point);
        }
    }
}
