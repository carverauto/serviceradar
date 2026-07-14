//! Elliptic curve arithmetic traits.

use crate::{
    Curve, CurveGroup, Error, FieldBytes, Group, NonZeroScalar, PrimeCurve, ScalarValue,
    ops::{Invert, LinearCombination, Mul, Reduce},
    point::{AffineCoordinates, NonIdentity},
    scalar::{FromUintUnchecked, IsHigh},
};
use core::fmt::Debug;
use subtle::{ConditionallySelectable, ConstantTimeEq, CtOption};
use zeroize::DefaultIsZeroes;

/// Elliptic curve with an arithmetic implementation.
pub trait CurveArithmetic: Curve {
    /// Elliptic curve point in affine coordinates.
    type AffinePoint: 'static
        + AffineCoordinates<FieldRepr = FieldBytes<Self>>
        + Copy
        + ConditionallySelectable
        + ConstantTimeEq
        + Debug
        + Default
        + DefaultIsZeroes
        + Eq
        + From<NonIdentity<Self::AffinePoint>>
        + PartialEq
        + Sized
        + Send
        + Sync
        + TryInto<NonIdentity<Self::AffinePoint>, Error = Error>;

    /// Elliptic curve point in projective coordinates.
    ///
    /// Note: the following bounds are provided by [`group::Group`]:
    /// - `'static`
    /// - [`Copy`]
    /// - [`Clone`]
    /// - [`Debug`]
    /// - [`Eq`]
    /// - [`Sized`]
    /// - [`Send`]
    /// - [`Sync`]
    type ProjectivePoint: ConditionallySelectable
        + ConstantTimeEq
        + Default
        + DefaultIsZeroes
        + From<Self::AffinePoint>
        + From<NonIdentity<Self::ProjectivePoint>>
        + Into<Self::AffinePoint>
        + LinearCombination<[(Self::ProjectivePoint, Self::Scalar)]>
        + LinearCombination<[(Self::ProjectivePoint, Self::Scalar); 2]>
        + TryInto<NonIdentity<Self::ProjectivePoint>, Error = Error>
        + CurveGroup<AffineRepr = Self::AffinePoint>
        + Group<Scalar = Self::Scalar>;

    /// Scalar field modulo this curve's order.
    ///
    /// Note: the following bounds are provided by [`ff::Field`]:
    /// - `'static`
    /// - [`Copy`]
    /// - [`Clone`]
    /// - [`ConditionallySelectable`]
    /// - [`ConstantTimeEq`]
    /// - [`Debug`]
    /// - [`Default`]
    /// - [`Send`]
    /// - [`Sync`]
    type Scalar: AsRef<Self::Scalar>
        + DefaultIsZeroes
        + From<NonZeroScalar<Self>>
        + From<ScalarValue<Self>>
        + FromUintUnchecked<Uint = Self::Uint>
        + Into<FieldBytes<Self>>
        + Into<ScalarValue<Self>>
        + Into<Self::Uint>
        + Invert<Output = CtOption<Self::Scalar>>
        + IsHigh
        + Mul<Self::AffinePoint, Output = Self::ProjectivePoint>
        + for<'a> Mul<&'a Self::AffinePoint, Output = Self::ProjectivePoint>
        + Mul<Self::ProjectivePoint, Output = Self::ProjectivePoint>
        + for<'a> Mul<&'a Self::ProjectivePoint, Output = Self::ProjectivePoint>
        + PartialOrd
        + Reduce<Self::Uint>
        + Reduce<FieldBytes<Self>>
        + TryInto<NonZeroScalar<Self>, Error = Error>
        + ff::Field
        + ff::PrimeField<Repr = FieldBytes<Self>>;
}

/// Prime order elliptic curve with projective arithmetic implementation.
pub trait PrimeCurveArithmetic:
    PrimeCurve + CurveArithmetic<ProjectivePoint = Self::CurveGroup>
{
    /// Prime order elliptic curve group.
    type CurveGroup: group::prime::PrimeCurve<Affine = <Self as CurveArithmetic>::AffinePoint>;
}
