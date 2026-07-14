//! Traits for arithmetic operations on elliptic curve field elements.

pub use core::ops::{Add, AddAssign, Mul, MulAssign, Neg, Shr, ShrAssign, Sub, SubAssign};
pub use crypto_bigint::{Invert, Reduce};

use crate::CurveGroup;
use core::iter;
use ff::Field;
use subtle::{Choice, CtOption};

#[cfg(feature = "alloc")]
use alloc::{borrow::ToOwned, vec::Vec};

/// Perform a batched inversion on a sequence of field elements (i.e. base field elements or scalars)
/// at an amortized cost that should be practically as efficient as a single inversion.
pub trait BatchInvert<FieldElements: ?Sized> {
    /// The output of batch inversion. A container of field elements.
    type Output;

    /// Invert a batch of field elements.
    fn batch_invert(field_elements: FieldElements) -> <Self as BatchInvert<FieldElements>>::Output;
}

impl<const N: usize, T> BatchInvert<[T; N]> for T
where
    T: Field,
{
    type Output = CtOption<[Self; N]>;

    fn batch_invert(mut field_elements: [Self; N]) -> CtOption<[Self; N]> {
        let mut field_elements_pad = [Self::default(); N];
        let inversion_succeeded =
            invert_batch_internal(&mut field_elements, &mut field_elements_pad, invert);

        CtOption::new(field_elements, inversion_succeeded)
    }
}

#[cfg(feature = "alloc")]
impl<'this, T> BatchInvert<&'this mut [Self]> for T
where
    T: Field,
{
    type Output = CtOption<&'this mut [Self]>;

    fn batch_invert(field_elements: &'this mut [Self]) -> CtOption<&'this mut [Self]> {
        let mut field_elements_pad: Vec<Self> = vec![Self::default(); field_elements.len()];
        let inversion_succeeded =
            invert_batch_internal(field_elements, &mut field_elements_pad, invert);

        CtOption::new(field_elements, inversion_succeeded)
    }
}

#[cfg(feature = "alloc")]
impl<T> BatchInvert<&[Self]> for T
where
    T: Field,
{
    type Output = CtOption<Vec<Self>>;

    fn batch_invert(field_elements: &[Self]) -> CtOption<Vec<Self>> {
        let mut field_elements: Vec<Self> = field_elements.to_owned();
        let mut field_elements_pad: Vec<Self> = vec![Self::default(); field_elements.len()];
        let inversion_succeeded =
            invert_batch_internal(&mut field_elements, &mut field_elements_pad, invert);

        CtOption::new(field_elements, inversion_succeeded)
    }
}

#[cfg(feature = "alloc")]
impl<T> BatchInvert<Vec<Self>> for T
where
    T: Field,
{
    type Output = CtOption<Vec<Self>>;

    fn batch_invert(mut field_elements: Vec<Self>) -> CtOption<Vec<Self>> {
        let mut field_elements_pad: Vec<Self> = vec![Self::default(); field_elements.len()];
        let inversion_succeeded =
            invert_batch_internal(&mut field_elements, &mut field_elements_pad, invert);

        CtOption::new(field_elements, inversion_succeeded)
    }
}

fn invert<T: Field>(scalar: T) -> (T, Choice) {
    let scalar = scalar.invert();
    let choice = scalar.is_some();
    let scalar = scalar.unwrap_or(T::default());

    (scalar, choice)
}

/// Implements "Montgomery's trick", a trick for computing many modular inverses at once.
///
/// "Montgomery's trick" works by reducing the problem of computing `n` inverses
/// to computing a single inversion, plus some storage and `O(n)` extra multiplications.
///
/// See: https://iacr.org/archive/pkc2004/29470042/29470042.pdf section 2.2.
pub(crate) fn invert_batch_internal<T: Copy + Mul<Output = T> + MulAssign>(
    field_elements: &mut [T],
    field_elements_pad: &mut [T],
    invert: fn(T) -> (T, Choice),
) -> Choice {
    let batch_size = field_elements.len();
    if batch_size != field_elements_pad.len() {
        return Choice::from(0);
    }
    if batch_size == 0 {
        return Choice::from(1);
    }

    let mut acc = field_elements[0];
    field_elements_pad[0] = acc;

    for (field_element, field_element_pad) in field_elements
        .iter_mut()
        .zip(field_elements_pad.iter_mut())
        .skip(1)
    {
        // $ a_n = a_{n-1}*x_n $
        acc *= *field_element;
        *field_element_pad = acc;
    }

    let (mut acc, choice) = invert(acc);

    // Shift the iterator by one element back. The one we are skipping is served in `acc`.
    let field_elements_pad = field_elements_pad
        .iter()
        .rev()
        .skip(1)
        .map(Some)
        .chain(iter::once(None));

    for (field_element, field_element_pad) in
        field_elements.iter_mut().rev().zip(field_elements_pad)
    {
        if let Some(field_element_pad) = field_element_pad {
            // Store in a temporary so we can overwrite `field_element`.
            // $ a_{n-1} = {a_n}^{-1}*x_n $
            let tmp = acc * *field_element;
            // $ {x_n}^{-1} = a_{n}^{-1}*a_{n-1} $
            *field_element = acc * *field_element_pad;
            acc = tmp;
        } else {
            *field_element = acc;
        }
    }

    choice
}

/// Linear combination.
///
/// This trait enables optimized implementations of linear combinations (e.g. Shamir's Trick).
///
/// It's generic around `PointsAndScalars` to allow overlapping impls. For example, const generic
/// impls can use the input size to determine the size needed to store temporary variables.
pub trait LinearCombination<PointsAndScalars>: CurveGroup
where
    PointsAndScalars: AsRef<[(Self, Self::Scalar)]> + ?Sized,
{
    /// Calculates `x1 * k1 + ... + xn * kn`.
    fn lincomb(points_and_scalars: &PointsAndScalars) -> Self {
        points_and_scalars
            .as_ref()
            .iter()
            .copied()
            .map(|(point, scalar)| point * scalar)
            .sum()
    }
}

/// Modular reduction to a non-zero output.
///
/// This trait is primarily intended for use by curve implementations such
/// as the `k256` and `p256` crates.
///
/// End users should use the [`Reduce`] impl on
/// [`NonZeroScalar`][`crate::NonZeroScalar`] instead.
pub trait ReduceNonZero<T>: Reduce<T> {
    /// Perform a modular reduction, returning a field element.
    fn reduce_nonzero(n: &T) -> Self;
}
