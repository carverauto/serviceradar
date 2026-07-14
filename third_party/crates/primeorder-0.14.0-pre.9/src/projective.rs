//! Projective curve points.

#![allow(clippy::needless_range_loop, clippy::op_ref)]

use crate::{AffinePoint, Field, PrimeCurveParams, point_arithmetic::PointArithmetic};
use core::{
    array,
    borrow::Borrow,
    iter::Sum,
    ops::{Add, AddAssign, Mul, MulAssign, Neg, Sub, SubAssign},
};
use elliptic_curve::{
    BatchNormalize, CurveGroup, Error, FieldBytes, FieldBytesSize, PrimeField, PublicKey, Result,
    Scalar,
    array::ArraySize,
    bigint::{ArrayEncoding, ByteArray},
    group::{
        Group, GroupEncoding,
        cofactor::CofactorGroup,
        prime::{PrimeCurve, PrimeGroup},
    },
    ops::{BatchInvert, LinearCombination},
    point::{Double, NonIdentity},
    rand_core::TryRngCore,
    sec1::{
        CompressedPoint, EncodedPoint, FromEncodedPoint, ModulusSize, ToEncodedPoint,
        UncompressedPointSize,
    },
    subtle::{Choice, ConditionallySelectable, ConstantTimeEq, CtOption},
    zeroize::DefaultIsZeroes,
};

#[cfg(feature = "alloc")]
use alloc::vec::Vec;

#[cfg(feature = "serde")]
use serdect::serde::{Deserialize, Serialize, de, ser};

/// Point on a Weierstrass curve in projective coordinates.
#[derive(Clone, Copy, Debug)]
pub struct ProjectivePoint<C: PrimeCurveParams> {
    pub(crate) x: C::FieldElement,
    pub(crate) y: C::FieldElement,
    pub(crate) z: C::FieldElement,
}

impl<C> ProjectivePoint<C>
where
    C: PrimeCurveParams,
{
    /// Additive identity of the group a.k.a. the point at infinity.
    pub const IDENTITY: Self = Self {
        x: C::FieldElement::ZERO,
        y: C::FieldElement::ONE,
        z: C::FieldElement::ZERO,
    };

    /// Base point of the curve.
    pub const GENERATOR: Self = Self {
        x: C::GENERATOR.0,
        y: C::GENERATOR.1,
        z: C::FieldElement::ONE,
    };

    /// Returns the affine representation of this point, or `None` if it is the identity.
    pub fn to_affine(&self) -> AffinePoint<C> {
        <C::FieldElement as Field>::invert(&self.z)
            .map(|zinv| self.to_affine_internal(zinv))
            .unwrap_or(AffinePoint::IDENTITY)
    }

    pub(super) fn to_affine_internal(self, zinv: C::FieldElement) -> AffinePoint<C> {
        AffinePoint {
            x: self.x * &zinv,
            y: self.y * &zinv,
            infinity: 0,
        }
    }

    /// Returns `-self`.
    pub fn neg(&self) -> Self {
        Self {
            x: self.x,
            y: -self.y,
            z: self.z,
        }
    }

    /// Returns `self + other`.
    pub fn add(&self, other: &Self) -> Self {
        C::PointArithmetic::add(self, other)
    }

    /// Returns `self + other`.
    fn add_mixed(&self, other: &AffinePoint<C>) -> Self {
        C::PointArithmetic::add_mixed(self, other)
    }

    /// Returns `self - other`.
    pub fn sub(&self, other: &Self) -> Self {
        self.add(&other.neg())
    }

    /// Returns `self - other`.
    fn sub_mixed(&self, other: &AffinePoint<C>) -> Self {
        self.add_mixed(&other.neg())
    }

    /// Returns `[k] self`.
    fn mul(&self, k: &Scalar<C>) -> Self
    where
        Self: Double,
    {
        let mut k = Into::<C::Uint>::into(*k).to_le_byte_array();
        let mut pc = LookupTable::new(*self);

        lincomb(array::from_mut(&mut k), array::from_mut(&mut pc))
    }
}

impl<C> ConditionallySelectable for ProjectivePoint<C>
where
    C: PrimeCurveParams,
{
    #[inline(always)]
    fn conditional_select(a: &Self, b: &Self, choice: Choice) -> Self {
        Self {
            x: C::FieldElement::conditional_select(&a.x, &b.x, choice),
            y: C::FieldElement::conditional_select(&a.y, &b.y, choice),
            z: C::FieldElement::conditional_select(&a.z, &b.z, choice),
        }
    }
}

impl<C> ConstantTimeEq for ProjectivePoint<C>
where
    C: PrimeCurveParams,
{
    fn ct_eq(&self, other: &Self) -> Choice {
        self.to_affine().ct_eq(&other.to_affine())
    }
}

impl<C> Default for ProjectivePoint<C>
where
    C: PrimeCurveParams,
{
    fn default() -> Self {
        Self::IDENTITY
    }
}

impl<C> DefaultIsZeroes for ProjectivePoint<C> where C: PrimeCurveParams {}

impl<C: PrimeCurveParams> Double for ProjectivePoint<C> {
    fn double(&self) -> Self {
        C::PointArithmetic::double(self)
    }
}

impl<C> Eq for ProjectivePoint<C> where C: PrimeCurveParams {}

impl<C> From<AffinePoint<C>> for ProjectivePoint<C>
where
    C: PrimeCurveParams,
{
    fn from(p: AffinePoint<C>) -> Self {
        let projective = ProjectivePoint {
            x: p.x,
            y: p.y,
            z: C::FieldElement::ONE,
        };
        Self::conditional_select(&projective, &Self::IDENTITY, p.is_identity())
    }
}

impl<C> From<&AffinePoint<C>> for ProjectivePoint<C>
where
    C: PrimeCurveParams,
{
    fn from(p: &AffinePoint<C>) -> Self {
        Self::from(*p)
    }
}

impl<C> From<NonIdentity<ProjectivePoint<C>>> for ProjectivePoint<C>
where
    C: PrimeCurveParams,
{
    fn from(p: NonIdentity<ProjectivePoint<C>>) -> Self {
        p.to_point()
    }
}

impl<C> From<PublicKey<C>> for ProjectivePoint<C>
where
    C: PrimeCurveParams,
{
    fn from(public_key: PublicKey<C>) -> ProjectivePoint<C> {
        AffinePoint::from(public_key).into()
    }
}

impl<C> From<&PublicKey<C>> for ProjectivePoint<C>
where
    C: PrimeCurveParams,
{
    fn from(public_key: &PublicKey<C>) -> ProjectivePoint<C> {
        AffinePoint::<C>::from(public_key).into()
    }
}

impl<C> FromEncodedPoint<C> for ProjectivePoint<C>
where
    C: PrimeCurveParams,
    FieldBytes<C>: Copy,
    FieldBytesSize<C>: ModulusSize,
    CompressedPoint<C>: Copy,
{
    fn from_encoded_point(p: &EncodedPoint<C>) -> CtOption<Self> {
        AffinePoint::<C>::from_encoded_point(p).map(Self::from)
    }
}

//
// `group` trait impls
//

/// Prime order elliptic curves have a cofactor of 1.
impl<C> CofactorGroup for ProjectivePoint<C>
where
    C: PrimeCurveParams,
    CompressedPoint<C>: Send + Sync,
    FieldBytes<C>: Copy,
    FieldBytesSize<C>: ModulusSize,
    CompressedPoint<C>: Copy,
    <UncompressedPointSize<C> as ArraySize>::ArrayType<u8>: Copy,
{
    type Subgroup = ProjectivePoint<C>;

    fn clear_cofactor(&self) -> Self::Subgroup {
        *self
    }

    fn into_subgroup(self) -> CtOption<Self::Subgroup> {
        CtOption::new(self, Choice::from(1))
    }

    fn is_torsion_free(&self) -> Choice {
        Choice::from(1)
    }
}

impl<C> CurveGroup for ProjectivePoint<C>
where
    C: PrimeCurveParams,
    FieldBytes<C>: Copy,
{
    type AffineRepr = AffinePoint<C>;

    fn to_affine(&self) -> AffinePoint<C> {
        ProjectivePoint::to_affine(self)
    }

    #[cfg(feature = "alloc")]
    #[inline]
    fn batch_normalize(projective: &[Self], affine: &mut [Self::AffineRepr]) {
        assert_eq!(projective.len(), affine.len());
        let mut zs = vec![C::FieldElement::ONE; projective.len()];
        batch_normalize_generic(projective, zs.as_mut_slice(), affine);
    }
}

impl<C> Group for ProjectivePoint<C>
where
    C: PrimeCurveParams,
    FieldBytes<C>: Copy,
{
    type Scalar = Scalar<C>;

    fn try_from_rng<R: TryRngCore + ?Sized>(rng: &mut R) -> core::result::Result<Self, R::Error> {
        AffinePoint::try_from_rng(rng).map(Self::from)
    }

    fn identity() -> Self {
        Self::IDENTITY
    }

    fn generator() -> Self {
        Self::GENERATOR
    }

    fn is_identity(&self) -> Choice {
        self.ct_eq(&Self::IDENTITY)
    }

    fn double(&self) -> Self {
        Double::double(self)
    }
}

impl<C> GroupEncoding for ProjectivePoint<C>
where
    C: PrimeCurveParams,
    CompressedPoint<C>: Send + Sync,
    FieldBytes<C>: Copy,
    FieldBytesSize<C>: ModulusSize,
    CompressedPoint<C>: Copy,
    <UncompressedPointSize<C> as ArraySize>::ArrayType<u8>: Copy,
{
    type Repr = CompressedPoint<C>;

    fn from_bytes(bytes: &Self::Repr) -> CtOption<Self> {
        <AffinePoint<C> as GroupEncoding>::from_bytes(bytes).map(Into::into)
    }

    fn from_bytes_unchecked(bytes: &Self::Repr) -> CtOption<Self> {
        // No unchecked conversion possible for compressed points
        Self::from_bytes(bytes)
    }

    fn to_bytes(&self) -> Self::Repr {
        self.to_affine().to_bytes()
    }
}

impl<C> PrimeCurve for ProjectivePoint<C>
where
    Self: Double,
    C: PrimeCurveParams,
    CompressedPoint<C>: Copy + Send + Sync,
    FieldBytes<C>: Copy,
    FieldBytesSize<C>: ModulusSize,
    <UncompressedPointSize<C> as ArraySize>::ArrayType<u8>: Copy,
{
    type Affine = AffinePoint<C>;
}

impl<C> PrimeGroup for ProjectivePoint<C>
where
    Self: Double,
    C: PrimeCurveParams,
    CompressedPoint<C>: Copy + Send + Sync,
    FieldBytes<C>: Copy,
    FieldBytesSize<C>: ModulusSize,
    <UncompressedPointSize<C> as ArraySize>::ArrayType<u8>: Copy,
{
}

//
// Batch trait impls
//

impl<const N: usize, C> BatchNormalize<[ProjectivePoint<C>; N]> for ProjectivePoint<C>
where
    C: PrimeCurveParams,
    FieldBytes<C>: Copy,
{
    type Output = [<Self as CurveGroup>::AffineRepr; N];

    #[inline]
    fn batch_normalize(points: &[Self; N]) -> [<Self as CurveGroup>::AffineRepr; N] {
        let zs = [C::FieldElement::ONE; N];
        let mut affine_points = [C::AffinePoint::IDENTITY; N];
        batch_normalize_generic(points, zs, &mut affine_points);
        affine_points
    }
}

#[cfg(feature = "alloc")]
impl<C> BatchNormalize<[ProjectivePoint<C>]> for ProjectivePoint<C>
where
    C: PrimeCurveParams,
    FieldBytes<C>: Copy,
{
    type Output = Vec<<Self as CurveGroup>::AffineRepr>;

    #[inline]
    fn batch_normalize(points: &[Self]) -> Vec<<Self as CurveGroup>::AffineRepr> {
        let mut zs = vec![C::FieldElement::ONE; points.len()];
        let mut affine_points = vec![AffinePoint::IDENTITY; points.len()];
        batch_normalize_generic(points, zs.as_mut_slice(), &mut affine_points);
        affine_points
    }
}

/// Generic implementation of batch normalization.
fn batch_normalize_generic<C, P, Z, I, O>(points: &P, mut zs: Z, out: &mut O)
where
    C: PrimeCurveParams,
    C::FieldElement: BatchInvert<Z, Output = CtOption<I>>,
    C::ProjectivePoint: Double,
    P: AsRef<[ProjectivePoint<C>]> + ?Sized,
    Z: AsMut<[C::FieldElement]>,
    I: AsRef<[C::FieldElement]>,
    O: AsMut<[AffinePoint<C>]> + ?Sized,
{
    let points = points.as_ref();
    let out = out.as_mut();

    for i in 0..points.len() {
        // Even a single zero value will fail inversion for the entire batch.
        // Put a dummy value (above `FieldElement::ONE`) so inversion succeeds
        // and treat that case specially later-on.
        zs.as_mut()[i].conditional_assign(&points[i].z, !points[i].z.ct_eq(&C::FieldElement::ZERO));
    }

    // This is safe to unwrap since we assured that all elements are non-zero
    let zs_inverses = <C::FieldElement as BatchInvert<Z>>::batch_invert(zs)
        .expect("all elements should be non-zero");

    for i in 0..out.len() {
        // If the `z` coordinate is non-zero, we can use it to invert;
        // otherwise it defaults to the `IDENTITY` value.
        out[i] = C::AffinePoint::conditional_select(
            &points[i].to_affine_internal(zs_inverses.as_ref()[i]),
            &C::AffinePoint::IDENTITY,
            points[i].z.ct_eq(&C::FieldElement::ZERO),
        );
    }
}

impl<C> LinearCombination<[(Self, Scalar<C>)]> for ProjectivePoint<C>
where
    C: PrimeCurveParams,
    FieldBytes<C>: Copy,
{
    #[cfg(feature = "alloc")]
    fn lincomb(points_and_scalars: &[(Self, Scalar<C>)]) -> Self {
        let (mut ks, mut pcs): (Vec<_>, Vec<_>) = points_and_scalars
            .iter()
            .map(|(point, scalar)| {
                (
                    Into::<C::Uint>::into(*scalar).to_le_byte_array(),
                    LookupTable::new(*point),
                )
            })
            .unzip();

        lincomb::<C>(&mut ks, &mut pcs)
    }
}

impl<C, const N: usize> LinearCombination<[(Self, Scalar<C>); N]> for ProjectivePoint<C>
where
    C: PrimeCurveParams,
    FieldBytes<C>: Copy,
{
    fn lincomb(points_and_scalars: &[(Self, Scalar<C>); N]) -> Self {
        let mut ks: [_; N] = array::from_fn(|index| {
            Into::<C::Uint>::into(points_and_scalars[index].1).to_le_byte_array()
        });
        let mut pcs: [_; N] = array::from_fn(|index| LookupTable::new(points_and_scalars[index].0));

        lincomb::<C>(&mut ks, &mut pcs)
    }
}

fn lincomb<C: PrimeCurveParams>(
    ks: &mut [ByteArray<C::Uint>],
    pcs: &mut [LookupTable<C>],
) -> ProjectivePoint<C> {
    let mut q = ProjectivePoint::IDENTITY;
    let mut pos = (<Scalar<C> as PrimeField>::NUM_BITS.div_ceil(8) * 8) as usize - 4;

    loop {
        for (k, pc) in ks.iter().zip(pcs.iter()) {
            let slot = (k[pos >> 3] >> (pos & 7)) & 0xf;
            q = q.add(&pc.select(slot));
        }

        if pos == 0 {
            break;
        }

        q = Double::double(&Double::double(&Double::double(&Double::double(&q))));
        pos -= 4;
    }

    q
}

struct LookupTable<C: PrimeCurveParams>([ProjectivePoint<C>; 16]);

impl<C: PrimeCurveParams> LookupTable<C> {
    fn new(point: ProjectivePoint<C>) -> Self {
        let mut pc = [ProjectivePoint::default(); 16];
        pc[0] = ProjectivePoint::IDENTITY;
        pc[1] = point;

        for i in 2..16 {
            pc[i] = if i % 2 == 0 {
                Double::double(&pc[i / 2])
            } else {
                pc[i - 1].add(point)
            };
        }

        Self(pc)
    }

    fn select(&self, slot: u8) -> ProjectivePoint<C> {
        let mut t = ProjectivePoint::IDENTITY;

        for i in 1..16 {
            t.conditional_assign(
                &self.0[i],
                Choice::from(((slot as usize ^ i).wrapping_sub(1) >> 8) as u8 & 1),
            );
        }

        t
    }
}

impl<C> PartialEq for ProjectivePoint<C>
where
    C: PrimeCurveParams,
{
    fn eq(&self, other: &Self) -> bool {
        self.ct_eq(other).into()
    }
}

impl<C> ToEncodedPoint<C> for ProjectivePoint<C>
where
    C: PrimeCurveParams,
    CompressedPoint<C>: Copy,
    FieldBytesSize<C>: ModulusSize,
    <UncompressedPointSize<C> as ArraySize>::ArrayType<u8>: Copy,
{
    fn to_encoded_point(&self, compress: bool) -> EncodedPoint<C> {
        self.to_affine().to_encoded_point(compress)
    }
}

/// The constant-time alternative is available at [`NonIdentity::new()`].
impl<C> TryFrom<ProjectivePoint<C>> for NonIdentity<ProjectivePoint<C>>
where
    C: PrimeCurveParams,
{
    type Error = Error;

    fn try_from(point: ProjectivePoint<C>) -> Result<Self> {
        NonIdentity::new(point).into_option().ok_or(Error)
    }
}

impl<C> TryFrom<ProjectivePoint<C>> for PublicKey<C>
where
    C: PrimeCurveParams,
{
    type Error = Error;

    fn try_from(point: ProjectivePoint<C>) -> Result<PublicKey<C>> {
        AffinePoint::<C>::from(point).try_into()
    }
}

impl<C> TryFrom<&ProjectivePoint<C>> for PublicKey<C>
where
    C: PrimeCurveParams,
{
    type Error = Error;

    fn try_from(point: &ProjectivePoint<C>) -> Result<PublicKey<C>> {
        AffinePoint::<C>::from(point).try_into()
    }
}

//
// `core::ops` trait impls
//

impl<C> Add<ProjectivePoint<C>> for ProjectivePoint<C>
where
    C: PrimeCurveParams,
{
    type Output = ProjectivePoint<C>;

    fn add(self, other: ProjectivePoint<C>) -> ProjectivePoint<C> {
        ProjectivePoint::add(&self, &other)
    }
}

impl<C> Add<&ProjectivePoint<C>> for &ProjectivePoint<C>
where
    C: PrimeCurveParams,
{
    type Output = ProjectivePoint<C>;

    fn add(self, other: &ProjectivePoint<C>) -> ProjectivePoint<C> {
        ProjectivePoint::add(self, other)
    }
}

impl<C> Add<&ProjectivePoint<C>> for ProjectivePoint<C>
where
    C: PrimeCurveParams,
{
    type Output = ProjectivePoint<C>;

    fn add(self, other: &ProjectivePoint<C>) -> ProjectivePoint<C> {
        ProjectivePoint::add(&self, other)
    }
}

impl<C> AddAssign<ProjectivePoint<C>> for ProjectivePoint<C>
where
    C: PrimeCurveParams,
{
    fn add_assign(&mut self, rhs: ProjectivePoint<C>) {
        *self = ProjectivePoint::add(self, &rhs);
    }
}

impl<C> AddAssign<&ProjectivePoint<C>> for ProjectivePoint<C>
where
    C: PrimeCurveParams,
{
    fn add_assign(&mut self, rhs: &ProjectivePoint<C>) {
        *self = ProjectivePoint::add(self, rhs);
    }
}

impl<C> Add<AffinePoint<C>> for ProjectivePoint<C>
where
    C: PrimeCurveParams,
{
    type Output = ProjectivePoint<C>;

    fn add(self, other: AffinePoint<C>) -> ProjectivePoint<C> {
        ProjectivePoint::add_mixed(&self, &other)
    }
}

impl<C> Add<&AffinePoint<C>> for &ProjectivePoint<C>
where
    C: PrimeCurveParams,
{
    type Output = ProjectivePoint<C>;

    fn add(self, other: &AffinePoint<C>) -> ProjectivePoint<C> {
        ProjectivePoint::add_mixed(self, other)
    }
}

impl<C> Add<&AffinePoint<C>> for ProjectivePoint<C>
where
    C: PrimeCurveParams,
{
    type Output = ProjectivePoint<C>;

    fn add(self, other: &AffinePoint<C>) -> ProjectivePoint<C> {
        ProjectivePoint::add_mixed(&self, other)
    }
}

impl<C> AddAssign<AffinePoint<C>> for ProjectivePoint<C>
where
    C: PrimeCurveParams,
{
    fn add_assign(&mut self, rhs: AffinePoint<C>) {
        *self = ProjectivePoint::add_mixed(self, &rhs);
    }
}

impl<C> AddAssign<&AffinePoint<C>> for ProjectivePoint<C>
where
    C: PrimeCurveParams,
{
    fn add_assign(&mut self, rhs: &AffinePoint<C>) {
        *self = ProjectivePoint::add_mixed(self, rhs);
    }
}

impl<C> Sum for ProjectivePoint<C>
where
    C: PrimeCurveParams,
{
    fn sum<I: Iterator<Item = Self>>(iter: I) -> Self {
        iter.fold(ProjectivePoint::IDENTITY, |a, b| a + b)
    }
}

impl<'a, C> Sum<&'a ProjectivePoint<C>> for ProjectivePoint<C>
where
    C: PrimeCurveParams,
{
    fn sum<I: Iterator<Item = &'a ProjectivePoint<C>>>(iter: I) -> Self {
        iter.cloned().sum()
    }
}

impl<C> Sub<ProjectivePoint<C>> for ProjectivePoint<C>
where
    C: PrimeCurveParams,
{
    type Output = ProjectivePoint<C>;

    fn sub(self, other: ProjectivePoint<C>) -> ProjectivePoint<C> {
        ProjectivePoint::sub(&self, &other)
    }
}

impl<C> Sub<&ProjectivePoint<C>> for &ProjectivePoint<C>
where
    C: PrimeCurveParams,
{
    type Output = ProjectivePoint<C>;

    fn sub(self, other: &ProjectivePoint<C>) -> ProjectivePoint<C> {
        ProjectivePoint::sub(self, other)
    }
}

impl<C> Sub<&ProjectivePoint<C>> for ProjectivePoint<C>
where
    C: PrimeCurveParams,
{
    type Output = ProjectivePoint<C>;

    fn sub(self, other: &ProjectivePoint<C>) -> ProjectivePoint<C> {
        ProjectivePoint::sub(&self, other)
    }
}

impl<C> SubAssign<ProjectivePoint<C>> for ProjectivePoint<C>
where
    C: PrimeCurveParams,
{
    fn sub_assign(&mut self, rhs: ProjectivePoint<C>) {
        *self = ProjectivePoint::sub(self, &rhs);
    }
}

impl<C> SubAssign<&ProjectivePoint<C>> for ProjectivePoint<C>
where
    C: PrimeCurveParams,
{
    fn sub_assign(&mut self, rhs: &ProjectivePoint<C>) {
        *self = ProjectivePoint::sub(self, rhs);
    }
}

impl<C> Sub<AffinePoint<C>> for ProjectivePoint<C>
where
    C: PrimeCurveParams,
{
    type Output = ProjectivePoint<C>;

    fn sub(self, other: AffinePoint<C>) -> ProjectivePoint<C> {
        ProjectivePoint::sub_mixed(&self, &other)
    }
}

impl<C> Sub<&AffinePoint<C>> for &ProjectivePoint<C>
where
    C: PrimeCurveParams,
{
    type Output = ProjectivePoint<C>;

    fn sub(self, other: &AffinePoint<C>) -> ProjectivePoint<C> {
        ProjectivePoint::sub_mixed(self, other)
    }
}

impl<C> Sub<&AffinePoint<C>> for ProjectivePoint<C>
where
    C: PrimeCurveParams,
{
    type Output = ProjectivePoint<C>;

    fn sub(self, other: &AffinePoint<C>) -> ProjectivePoint<C> {
        ProjectivePoint::sub_mixed(&self, other)
    }
}

impl<C> SubAssign<AffinePoint<C>> for ProjectivePoint<C>
where
    C: PrimeCurveParams,
{
    fn sub_assign(&mut self, rhs: AffinePoint<C>) {
        *self = ProjectivePoint::sub_mixed(self, &rhs);
    }
}

impl<C> SubAssign<&AffinePoint<C>> for ProjectivePoint<C>
where
    C: PrimeCurveParams,
{
    fn sub_assign(&mut self, rhs: &AffinePoint<C>) {
        *self = ProjectivePoint::sub_mixed(self, rhs);
    }
}

impl<C, S> Mul<S> for ProjectivePoint<C>
where
    Self: Double,
    C: PrimeCurveParams,
    S: Borrow<Scalar<C>>,
{
    type Output = Self;

    fn mul(self, scalar: S) -> Self {
        ProjectivePoint::mul(&self, scalar.borrow())
    }
}

impl<C, S> Mul<S> for &ProjectivePoint<C>
where
    Self: Double,
    C: PrimeCurveParams,
    S: Borrow<Scalar<C>>,
{
    type Output = ProjectivePoint<C>;

    fn mul(self, scalar: S) -> ProjectivePoint<C> {
        ProjectivePoint::mul(self, scalar.borrow())
    }
}

impl<C> Mul<&Scalar<C>> for &ProjectivePoint<C>
where
    C: PrimeCurveParams,
    ProjectivePoint<C>: Double,
{
    type Output = ProjectivePoint<C>;

    fn mul(self, scalar: &Scalar<C>) -> ProjectivePoint<C> {
        ProjectivePoint::mul(self, scalar)
    }
}

impl<C, S> MulAssign<S> for ProjectivePoint<C>
where
    Self: Double,
    C: PrimeCurveParams,
    S: Borrow<Scalar<C>>,
{
    fn mul_assign(&mut self, scalar: S) {
        *self = ProjectivePoint::mul(self, scalar.borrow());
    }
}

impl<C> Neg for ProjectivePoint<C>
where
    C: PrimeCurveParams,
{
    type Output = ProjectivePoint<C>;

    fn neg(self) -> ProjectivePoint<C> {
        ProjectivePoint::neg(&self)
    }
}

impl<C> Neg for &ProjectivePoint<C>
where
    C: PrimeCurveParams,
{
    type Output = ProjectivePoint<C>;

    fn neg(self) -> ProjectivePoint<C> {
        ProjectivePoint::neg(self)
    }
}

//
// serde support
//

#[cfg(feature = "serde")]
impl<C> Serialize for ProjectivePoint<C>
where
    C: PrimeCurveParams,
    FieldBytesSize<C>: ModulusSize,
    CompressedPoint<C>: Copy,
    <UncompressedPointSize<C> as ArraySize>::ArrayType<u8>: Copy,
{
    fn serialize<S>(&self, serializer: S) -> core::result::Result<S::Ok, S::Error>
    where
        S: ser::Serializer,
    {
        self.to_affine().serialize(serializer)
    }
}

#[cfg(feature = "serde")]
impl<'de, C> Deserialize<'de> for ProjectivePoint<C>
where
    C: PrimeCurveParams,
    FieldBytes<C>: Copy,
    FieldBytesSize<C>: ModulusSize,
    CompressedPoint<C>: Copy,
{
    fn deserialize<D>(deserializer: D) -> core::result::Result<Self, D::Error>
    where
        D: de::Deserializer<'de>,
    {
        AffinePoint::<C>::deserialize(deserializer).map(Self::from)
    }
}
