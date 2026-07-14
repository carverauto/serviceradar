//! Multiplication between boxed integers in Montgomery form (i.e. Montgomery multiplication).
//!
//! Some parts adapted from `monty.rs` in `num-bigint`:
//! <https://github.com/rust-num/num-bigint/blob/2cea7f4/src/biguint/monty.rs>
//!
//! Originally (c) 2014 The Rust Project Developers, dual licensed Apache 2.0+MIT.

use super::{BoxedMontyForm, BoxedMontyParams};
use crate::{BoxedUint, ConstChoice, Limb, MontyMultiplier, Square, SquareAssign};
use core::{
    borrow::Borrow,
    ops::{Mul, MulAssign},
};

#[cfg(feature = "zeroize")]
use zeroize::Zeroize;

impl BoxedMontyForm {
    /// Multiplies by `rhs`.
    pub fn mul(&self, rhs: &Self) -> Self {
        debug_assert_eq!(&self.params, &rhs.params);
        let montgomery_form = BoxedMontyMultiplier::from(self.params.borrow())
            .mul(&self.montgomery_form, &rhs.montgomery_form);

        Self {
            montgomery_form,
            params: self.params.clone(),
        }
    }

    /// Computes the (reduced) square.
    pub fn square(&self) -> Self {
        let montgomery_form =
            BoxedMontyMultiplier::from(self.params.borrow()).square(&self.montgomery_form);

        Self {
            montgomery_form,
            params: self.params.clone(),
        }
    }
}

impl Mul<&BoxedMontyForm> for &BoxedMontyForm {
    type Output = BoxedMontyForm;
    fn mul(self, rhs: &BoxedMontyForm) -> BoxedMontyForm {
        self.mul(rhs)
    }
}

impl Mul<BoxedMontyForm> for &BoxedMontyForm {
    type Output = BoxedMontyForm;
    #[allow(clippy::op_ref)]
    fn mul(self, rhs: BoxedMontyForm) -> BoxedMontyForm {
        self * &rhs
    }
}

impl Mul<&BoxedMontyForm> for BoxedMontyForm {
    type Output = BoxedMontyForm;
    #[allow(clippy::op_ref)]
    fn mul(self, rhs: &BoxedMontyForm) -> BoxedMontyForm {
        &self * rhs
    }
}

impl Mul<BoxedMontyForm> for BoxedMontyForm {
    type Output = BoxedMontyForm;
    fn mul(self, rhs: BoxedMontyForm) -> BoxedMontyForm {
        &self * &rhs
    }
}

impl MulAssign<BoxedMontyForm> for BoxedMontyForm {
    fn mul_assign(&mut self, rhs: BoxedMontyForm) {
        Self::mul_assign(self, &rhs)
    }
}

impl MulAssign<&BoxedMontyForm> for BoxedMontyForm {
    fn mul_assign(&mut self, rhs: &BoxedMontyForm) {
        debug_assert_eq!(&self.params, &rhs.params);
        BoxedMontyMultiplier::from(self.params.borrow())
            .mul_assign(&mut self.montgomery_form, &rhs.montgomery_form);
    }
}

impl Square for BoxedMontyForm {
    fn square(&self) -> Self {
        BoxedMontyForm::square(self)
    }
}

impl SquareAssign for BoxedMontyForm {
    fn square_assign(&mut self) {
        BoxedMontyMultiplier::from(self.params.borrow()).square_assign(&mut self.montgomery_form);
    }
}

/// Montgomery multiplier with a pre-allocated internal buffer to avoid additional allocations.
#[derive(Debug, Clone)]
pub struct BoxedMontyMultiplier<'a> {
    product: BoxedUint,
    modulus: &'a BoxedUint,
    mod_neg_inv: Limb,
}

impl<'a> From<&'a BoxedMontyParams> for BoxedMontyMultiplier<'a> {
    fn from(params: &'a BoxedMontyParams) -> BoxedMontyMultiplier<'a> {
        BoxedMontyMultiplier::new(params.modulus(), params.mod_neg_inv())
    }
}

impl<'a> MontyMultiplier<'a> for BoxedMontyMultiplier<'a> {
    type Monty = BoxedMontyForm;

    /// Performs a Montgomery multiplication, assigning a fully reduced result to `lhs`.
    fn mul_assign(&mut self, lhs: &mut Self::Monty, rhs: &Self::Monty) {
        self.mul_assign(&mut lhs.montgomery_form, &rhs.montgomery_form);
    }

    /// Performs a Montgomery squaring, assigning a fully reduced result to `lhs`.
    fn square_assign(&mut self, lhs: &mut Self::Monty) {
        self.square_assign(&mut lhs.montgomery_form);
    }
}

impl<'a> BoxedMontyMultiplier<'a> {
    /// Create a new Montgomery multiplier.
    pub(super) fn new(modulus: &'a BoxedUint, mod_neg_inv: Limb) -> Self {
        Self {
            product: BoxedUint::zero_with_precision(modulus.bits_precision()),
            modulus,
            mod_neg_inv,
        }
    }

    /// Perform a Montgomery multiplication, returning a fully reduced result.
    pub(super) fn mul(&mut self, a: &BoxedUint, b: &BoxedUint) -> BoxedUint {
        let mut ret = a.clone();
        self.mul_assign(&mut ret, b);
        ret
    }

    /// Perform a Montgomery multiplication, assigning a fully reduced result to `a`.
    pub(super) fn mul_assign(&mut self, a: &mut BoxedUint, b: &BoxedUint) {
        self.mul_amm_assign(a, b);
        a.sub_assign_mod_with_carry(Limb::ZERO, self.modulus, self.modulus);
        debug_assert!(&*a < self.modulus);
    }

    /// Perform a squaring using Montgomery multiplication, returning a fully reduced result.
    pub(super) fn square(&mut self, a: &BoxedUint) -> BoxedUint {
        let mut ret = a.clone();
        self.square_assign(&mut ret);
        ret
    }

    /// Perform a squaring using Montgomery multiplication, assigning a fully reduced result to `a`.
    pub(super) fn square_assign(&mut self, a: &mut BoxedUint) {
        self.square_amm_assign(a);
        a.sub_assign_mod_with_carry(Limb::ZERO, self.modulus, self.modulus);
        debug_assert!(&*a < self.modulus);
    }

    /// Perform an "Almost Montgomery Multiplication".
    ///
    /// NOTE: the resulting output will be reduced to the *bit length* of the modulus, but not fully reduced and may
    /// exceed the modulus. A final reduction is required to ensure AMM results are fully reduced, and should not be
    /// exposed outside the internals of this crate.
    pub(super) fn mul_amm(&mut self, a: &BoxedUint, b: &BoxedUint) -> BoxedUint {
        let mut ret = a.clone();
        self.mul_amm_assign(&mut ret, b);
        ret
    }

    /// Perform an "Almost Montgomery Multiplication", assigning the product to `a`.
    ///
    /// NOTE: the resulting output will be reduced to the *bit length* of the modulus, but not fully reduced and may
    /// exceed the modulus. A final reduction is required to ensure AMM results are fully reduced, and should not be
    /// exposed outside the internals of this crate.
    pub(super) fn mul_amm_assign(&mut self, a: &mut BoxedUint, b: &BoxedUint) {
        debug_assert_eq!(a.bits_precision(), self.modulus.bits_precision());
        debug_assert_eq!(b.bits_precision(), self.modulus.bits_precision());

        self.clear_product();
        almost_montgomery_mul(
            self.product.as_mut_limbs(),
            a.as_limbs(),
            b.as_limbs(),
            self.modulus.as_limbs(),
            self.mod_neg_inv,
        );
        a.limbs.copy_from_slice(&self.product.limbs);
    }

    /// Perform a squaring using "Almost Montgomery Multiplication".
    ///
    /// NOTE: the resulting output will be reduced to the *bit length* of the modulus, but not fully reduced and may
    /// exceed the modulus. A final reduction is required to ensure AMM results are fully reduced, and should not be
    /// exposed outside the internals of this crate.
    #[allow(dead_code)] // TODO(tarcieri): use this?
    pub(super) fn square_amm(&mut self, a: &BoxedUint) -> BoxedUint {
        let mut ret = a.clone();
        self.square_amm_assign(&mut ret);
        ret
    }

    /// Perform a squaring using "Almost Montgomery Multiplication", assigning the result to `a`.
    ///
    /// NOTE: the resulting output will be reduced to the *bit length* of the modulus, but not fully reduced and may
    /// exceed the modulus. A final reduction is required to ensure AMM results are fully reduced, and should not be
    /// exposed outside the internals of this crate.
    pub(super) fn square_amm_assign(&mut self, a: &mut BoxedUint) {
        debug_assert_eq!(a.bits_precision(), self.modulus.bits_precision());

        // TODO(tarcieri): optimized implementation
        self.clear_product();
        almost_montgomery_mul(
            self.product.as_mut_limbs(),
            a.as_limbs(),
            a.as_limbs(),
            self.modulus.as_limbs(),
            self.mod_neg_inv,
        );
        a.limbs.copy_from_slice(&self.product.limbs);
    }

    /// Clear the internal product buffer.
    fn clear_product(&mut self) {
        self.product
            .limbs
            .iter_mut()
            .for_each(|limb| *limb = Limb::ZERO);
    }
}

#[cfg(feature = "zeroize")]
impl Drop for BoxedMontyMultiplier<'_> {
    fn drop(&mut self) {
        self.product.zeroize();
    }
}

/**
Computes Montgomery multiplication of `x` and `y` into `z`, that is
`z mod m = x * y * 2^(-n*W) mod m` assuming `k = -1/m mod 2^W`,
where `W` is the bit size of the limb, and `n * W` is the full bit size of the integer.

NOTE: `z` is assumed to be pre-zeroized.

This function implements the Coarsely Integrated Operand Scanning (CIOS) variation
of Montgomery multiplication, using the classification from
"Analyzing and Comparing Montgomery Multiplication Algorithms" by Koc et al
(<https://www.microsoft.com/en-us/research/wp-content/uploads/1996/01/j37acmon.pdf>).

Additionally, unlike in Koc et al, we are reducing the final result only if it overflows
`2^(n*W)`, not when it overflows `m`.
This means that this function does not assume `x` and `y` are reduced `mod m`,
and the result will be correct `mod m`, but potentially greater than `m`,
and smaller than `2^(n * W) + m`.
See "Efficient Software Implementations of Modular Exponentiation" by S. Gueron for details
(<https://eprint.iacr.org/2011/239.pdf>).

This function exhibits certain properties which were discovered via randomized tests,
but (to my knowledge at this moment) have not been proven formally.
Hereinafter I denote `f(x) = floor(x / m)`, that is `f` is the number of subtractions
of the modulus required to fully reduce `x`.

1. In general, if `f(x) = k` and `f(y) = n`, then `f(AMM(x, y)) <= min(k, n) + 1`.
   That is the "reduction error" grows with every operation,
   but is determined by the argument with the lower error.
2. To retrieve the number from Montgomery form we MM it by 1. In this case `f(AMM(x, 1)) = 0`,
   that is the result is always fully reduced regardless of `f(x)`.
3. `f(AMM(x, x)) <= 1` regardless of `f(x)`. That is, squaring resets the error to at most 1.
*/
// TODO(tarcieri): refactor into `reduction.rs`, share impl with `MontyForm`?
pub(crate) const fn almost_montgomery_mul(
    z: &mut [Limb],
    x: &[Limb],
    y: &[Limb],
    m: &[Limb],
    k: Limb,
) {
    let n = z.len();

    // This preconditions check allows compiler to remove bound checks later in the code.
    if !(x.len() == n && y.len() == n && m.len() == n) {
        panic!("Failed preconditions in `almost_montgomery_mul`");
    }

    let mut ts = Limb::ZERO;

    let mut i = 0;
    while i < n {
        let mut c = add_mul_carry(z, x, y[i]);
        (ts, c) = ts.overflowing_add(c);
        let ts1 = c;

        let t = z[0].wrapping_mul(k);

        c = add_mul_carry_and_shift(z, m, t);
        (z[n - 1], c) = ts.overflowing_add(c);
        ts = ts1.wrapping_add(c);

        i += 1;
    }

    // If the result overflows the integer size, subtract the modulus.
    let overflow = ConstChoice::from_word_lsb(ts.0);
    conditional_sub(z, m, overflow);
}

/// Calcaultes `z += x * y` and returns the carry.
#[inline]
const fn add_mul_carry(z: &mut [Limb], x: &[Limb], y: Limb) -> Limb {
    let n = z.len();
    if n != x.len() {
        panic!("Failed preconditions in `add_mul_carry`");
    }

    let mut c = Limb::ZERO;
    let mut i = 0;
    while i < n {
        (z[i], c) = x[i].carrying_mul_add(y, z[i], c);
        i += 1;
    }
    c
}

/// Calcaultes `z = (z + x * y) / 2^W` and returns the carry (of the `z + x * y`).
#[inline]
const fn add_mul_carry_and_shift(z: &mut [Limb], x: &[Limb], y: Limb) -> Limb {
    let n = z.len();
    if n != x.len() {
        panic!("Failed preconditions in `add_mul_carry_and_shift`");
    }

    let (_, mut c) = x[0].carrying_mul_add(y, z[0], Limb::ZERO);

    let mut i = 1;
    let mut i1 = 0;
    // Help the compiler elide bound checking
    while i < n && i1 < n {
        (z[i1], c) = x[i].carrying_mul_add(y, z[i], c);
        i += 1;
        i1 += 1;
    }

    c
}

/// Calculates `z -= x` if `c` is truthy, otherwise `z` is unchanged.
#[inline(always)]
const fn conditional_sub(z: &mut [Limb], x: &[Limb], c: ConstChoice) {
    let n = z.len();
    if n != x.len() {
        panic!("Failed preconditions in `conditional_sub`");
    }

    let mut borrow = Limb::ZERO;
    let mut i = 0;
    while i < n {
        let (zi, new_borrow) = z[i].borrowing_sub(Limb(c.if_true_word(x[i].0)), borrow);
        z[i] = zi;
        borrow = new_borrow;
        i += 1;
    }
}

#[cfg(test)]
mod tests {
    use super::{BoxedMontyForm, BoxedMontyParams, BoxedUint};

    /// Regression test for RustCrypto/crypto-bigint#441
    #[test]
    fn square() {
        let x = 0x20u128;
        let modulus = 0xB44677037A7DBDE04814256570DCBD8Du128;

        let boxed_modulus = BoxedUint::from(modulus);
        let boxed_params = BoxedMontyParams::new(boxed_modulus.to_odd().unwrap());
        let boxed_monty = BoxedMontyForm::new(BoxedUint::from(x), boxed_params);
        let boxed_square = boxed_monty.square();

        // TODO(tarcieri): test for correct output
        assert!(boxed_square.as_montgomery() < boxed_square.params().modulus());
    }
}
