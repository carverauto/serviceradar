//! [`Int`] division operations.

use core::ops::{Div, DivAssign, Rem, RemAssign};

use subtle::CtOption;

use crate::{CheckedDiv, ConstChoice, ConstCtOption, DivVartime, Int, NonZero, Uint, Wrapping};

/// Checked division operations.
impl<const LIMBS: usize> Int<LIMBS> {
    #[inline]
    /// Base div_rem operation on dividing [`Int`]s.
    ///
    /// Computes the quotient and remainder of `self / rhs`.
    /// Furthermore, returns the signs of `self` and `rhs`.
    const fn div_rem_base<const RHS_LIMBS: usize>(
        &self,
        rhs: &NonZero<Int<RHS_LIMBS>>,
    ) -> (Uint<LIMBS>, Uint<RHS_LIMBS>, ConstChoice, ConstChoice) {
        // Step 1: split operands into signs and magnitudes.
        let (lhs_mag, lhs_sgn) = self.abs_sign();
        let (rhs_mag, rhs_sgn) = rhs.abs_sign();

        // Step 2. Divide magnitudes
        // safe to unwrap since rhs is NonZero.
        let (quotient, remainder) = lhs_mag.div_rem(&rhs_mag);

        (quotient, remainder, lhs_sgn, rhs_sgn)
    }

    /// Compute the quotient and remainder of `self / rhs`.
    ///
    /// Returns `none` for the quotient when [`Int::MIN`] / [`Int::MINUS_ONE`]; that quotient cannot
    /// be captured in an [`Int`].
    ///
    /// Example:
    /// ```
    /// use crypto_bigint::{I128, NonZero};
    /// let (quotient, remainder) = I128::from(8).checked_div_rem(&I128::from(3).to_nz().unwrap());
    /// assert_eq!(quotient.unwrap(), I128::from(2));
    /// assert_eq!(remainder, I128::from(2));
    ///
    /// let (quotient, remainder) = I128::from(-8).checked_div_rem(&I128::from(3).to_nz().unwrap());
    /// assert_eq!(quotient.unwrap(), I128::from(-2));
    /// assert_eq!(remainder, I128::from(-2));
    ///
    /// let (quotient, remainder) = I128::from(8).checked_div_rem(&I128::from(-3).to_nz().unwrap());
    /// assert_eq!(quotient.unwrap(), I128::from(-2));
    /// assert_eq!(remainder, I128::from(2));
    ///
    /// let (quotient, remainder) = I128::from(-8).checked_div_rem(&I128::from(-3).to_nz().unwrap());
    /// assert_eq!(quotient.unwrap(), I128::from(2));
    /// assert_eq!(remainder, I128::from(-2));
    /// ```
    pub const fn checked_div_rem<const RHS_LIMBS: usize>(
        &self,
        rhs: &NonZero<Int<RHS_LIMBS>>,
    ) -> (ConstCtOption<Self>, Int<RHS_LIMBS>) {
        let (quotient, remainder, lhs_sgn, rhs_sgn) = self.div_rem_base(rhs);
        let opposing_signs = lhs_sgn.ne(rhs_sgn);
        (
            Self::new_from_abs_sign(quotient, opposing_signs),
            remainder.as_int().wrapping_neg_if(lhs_sgn), // as_int mapping is safe; remainder < 2^{k-1} by construction.
        )
    }

    /// Perform checked division, returning a [`CtOption`] which `is_some` if
    /// - the `rhs != 0`, and
    /// - `self != MIN` or `rhs != MINUS_ONE`.
    ///
    /// Note: this operation rounds towards zero, truncating any fractional part of the exact result.
    pub fn checked_div<const RHS_LIMBS: usize>(&self, rhs: &Int<RHS_LIMBS>) -> CtOption<Self> {
        NonZero::new(*rhs).and_then(|rhs| self.checked_div_rem(&rhs).0.into())
    }

    /// Computes `self` % `rhs`, returns the remainder.
    pub const fn rem<const RHS_LIMBS: usize>(
        &self,
        rhs: &NonZero<Int<RHS_LIMBS>>,
    ) -> Int<RHS_LIMBS> {
        self.checked_div_rem(rhs).1
    }
}

/// Vartime checked division operations.
impl<const LIMBS: usize> Int<LIMBS> {
    #[inline]
    /// Variable time equivalent of [`Self::div_rem_base`]
    ///
    /// This is variable only with respect to `rhs`.
    ///
    /// When used with a fixed `rhs`, this function is constant-time with respect
    /// to `self`.
    const fn div_rem_base_vartime<const RHS_LIMBS: usize>(
        &self,
        rhs: &NonZero<Int<RHS_LIMBS>>,
    ) -> (Uint<LIMBS>, Uint<RHS_LIMBS>, ConstChoice, ConstChoice) {
        // Step 1: split operands into signs and magnitudes.
        let (lhs_mag, lhs_sgn) = self.abs_sign();
        let (rhs_mag, rhs_sgn) = rhs.abs_sign();

        // Step 2. Divide magnitudes
        // safe to unwrap since rhs is NonZero.
        let (quotient, remainder) = lhs_mag.div_rem_vartime(&rhs_mag);

        (quotient, remainder, lhs_sgn, rhs_sgn)
    }

    /// Variable time equivalent of [`Self::checked_div_rem`]
    ///
    /// This is variable only with respect to `rhs`.
    ///
    /// When used with a fixed `rhs`, this function is constant-time with respect
    /// to `self`.
    pub const fn checked_div_rem_vartime<const RHS_LIMBS: usize>(
        &self,
        rhs: &NonZero<Int<RHS_LIMBS>>,
    ) -> (ConstCtOption<Self>, Int<RHS_LIMBS>) {
        let (quotient, remainder, lhs_sgn, rhs_sgn) = self.div_rem_base_vartime(rhs);
        let opposing_signs = lhs_sgn.ne(rhs_sgn);
        (
            Self::new_from_abs_sign(quotient, opposing_signs),
            remainder.as_int().wrapping_neg_if(lhs_sgn), // as_int mapping is safe; remainder < 2^{k-1} by construction.
        )
    }

    /// Variable time equivalent of [`Self::checked_div`]
    ///
    /// This is variable only with respect to `rhs`.
    ///
    /// When used with a fixed `rhs`, this function is constant-time with respect
    /// to `self`.
    pub fn checked_div_vartime<const RHS_LIMBS: usize>(
        &self,
        rhs: &Int<RHS_LIMBS>,
    ) -> CtOption<Self> {
        NonZero::new(*rhs).and_then(|rhs| self.checked_div_rem_vartime(&rhs).0.into())
    }

    /// Variable time equivalent of [`Self::rem`]
    ///
    /// This is variable only with respect to `rhs`.
    ///
    /// When used with a fixed `rhs`, this function is constant-time with respect
    /// to `self`.
    pub const fn rem_vartime<const RHS_LIMBS: usize>(
        &self,
        rhs: &NonZero<Int<RHS_LIMBS>>,
    ) -> Int<RHS_LIMBS> {
        self.checked_div_rem_vartime(rhs).1
    }
}

/// Vartime checked div-floor operations.
impl<const LIMBS: usize> Int<LIMBS> {
    /// Variable time equivalent of [`Self::checked_div_rem_floor`]
    ///
    /// This is variable only with respect to `rhs`.
    ///
    /// When used with a fixed `rhs`, this function is constant-time with respect
    /// to `self`.
    pub const fn checked_div_rem_floor_vartime<const RHS_LIMBS: usize>(
        &self,
        rhs: &NonZero<Int<RHS_LIMBS>>,
    ) -> (ConstCtOption<Self>, Int<RHS_LIMBS>) {
        let (lhs_mag, lhs_sgn) = self.abs_sign();
        let (rhs_mag, rhs_sgn) = rhs.abs_sign();
        let (quotient, remainder) = lhs_mag.div_rem_vartime(&rhs_mag);

        // Modify quotient and remainder when lhs and rhs have opposing signs and the remainder is
        // non-zero.
        let opposing_signs = lhs_sgn.xor(rhs_sgn);
        let modify = remainder.is_nonzero().and(opposing_signs);

        // Increase the quotient by one.
        let quotient_plus_one = quotient.wrapping_add(&Uint::ONE); // cannot wrap.
        let quotient = Uint::select(&quotient, &quotient_plus_one, modify);

        // Invert the remainder.
        let inv_remainder = rhs_mag.0.wrapping_sub(&remainder);
        let remainder = Uint::select(&remainder, &inv_remainder, modify);

        // Negate output when lhs and rhs have opposing signs.
        let quotient = Int::new_from_abs_sign(quotient, opposing_signs);
        let remainder = remainder.as_int().wrapping_neg_if(opposing_signs); // rem always small enough for safe as_int conversion

        (quotient, remainder)
    }

    /// Variable time equivalent of [`Self::checked_div_floor`]
    ///
    /// This is variable only with respect to `rhs`.
    ///
    /// When used with a fixed `rhs`, this function is constant-time with respect
    /// to `self`.
    pub fn checked_div_floor_vartime<const RHS_LIMBS: usize>(
        &self,
        rhs: &Int<RHS_LIMBS>,
    ) -> CtOption<Self> {
        NonZero::new(*rhs).and_then(|rhs| self.checked_div_rem_floor_vartime(&rhs).0.into())
    }
}

/// Checked div-floor operations.
impl<const LIMBS: usize> Int<LIMBS> {
    /// Perform checked floored division, returning a [`ConstCtOption`] which `is_some` only if
    /// - the `rhs != 0`, and
    /// - `self != MIN` or `rhs != MINUS_ONE`.
    ///
    /// Note: this operation rounds down.
    ///
    /// Example:
    /// ```
    /// use crypto_bigint::I128;
    /// assert_eq!(
    ///     I128::from(8).checked_div_floor(&I128::from(3)).unwrap(),
    ///     I128::from(2)
    /// );
    /// assert_eq!(
    ///     I128::from(-8).checked_div_floor(&I128::from(3)).unwrap(),
    ///     I128::from(-3)
    /// );
    /// assert_eq!(
    ///     I128::from(8).checked_div_floor(&I128::from(-3)).unwrap(),
    ///     I128::from(-3)
    /// );
    /// assert_eq!(
    ///     I128::from(-8).checked_div_floor(&I128::from(-3)).unwrap(),
    ///     I128::from(2)
    /// )
    /// ```
    pub fn checked_div_floor<const RHS_LIMBS: usize>(
        &self,
        rhs: &Int<RHS_LIMBS>,
    ) -> CtOption<Self> {
        NonZero::new(*rhs).and_then(|rhs| self.checked_div_rem_floor(&rhs).0.into())
    }

    /// Perform checked division and mod, returning the quotient and remainder.
    ///
    /// The quotient is a [`ConstCtOption`] which `is_some` only if
    /// - the `rhs != 0`, and
    /// - `self != MIN` or `rhs != MINUS_ONE`.
    ///
    /// Note: this operation rounds down.
    ///
    /// Example:
    /// ```
    /// use crypto_bigint::I128;
    ///
    /// let three = I128::from(3).to_nz().unwrap();
    /// let (quotient, remainder) = I128::from(8).checked_div_rem_floor(&three);
    /// assert_eq!(quotient.unwrap(), I128::from(2));
    /// assert_eq!(remainder, I128::from(2));
    ///
    /// let (quotient, remainder) = I128::from(-8).checked_div_rem_floor(&three);
    /// assert_eq!(quotient.unwrap(), I128::from(-3));
    /// assert_eq!(remainder, I128::from(-1));
    ///
    /// let minus_three = I128::from(-3).to_nz().unwrap();
    /// let (quotient, remainder) = I128::from(8).checked_div_rem_floor(&minus_three);
    /// assert_eq!(quotient.unwrap(), I128::from(-3));
    /// assert_eq!(remainder, I128::from(-1));
    ///
    /// let (quotient, remainder) = I128::from(-8).checked_div_rem_floor(&minus_three);
    /// assert_eq!(quotient.unwrap(), I128::from(2));
    /// assert_eq!(remainder, I128::from(2));
    /// ```
    pub const fn checked_div_rem_floor<const RHS_LIMBS: usize>(
        &self,
        rhs: &NonZero<Int<RHS_LIMBS>>,
    ) -> (ConstCtOption<Self>, Int<RHS_LIMBS>) {
        let (lhs_mag, lhs_sgn) = self.abs_sign();
        let (rhs_mag, rhs_sgn) = rhs.abs_sign();
        let (quotient, remainder) = lhs_mag.div_rem(&rhs_mag);

        // Modify quotient and remainder when lhs and rhs have opposing signs and the remainder is
        // non-zero.
        let opposing_signs = lhs_sgn.xor(rhs_sgn);
        let modify = remainder.is_nonzero().and(opposing_signs);

        // Increase the quotient by one.
        let quotient_plus_one = quotient.wrapping_add(&Uint::ONE); // cannot wrap.
        let quotient = Uint::select(&quotient, &quotient_plus_one, modify);

        // Invert the remainder.
        let inv_remainder = rhs_mag.0.wrapping_sub(&remainder);
        let remainder = Uint::select(&remainder, &inv_remainder, modify);

        // Negate output when lhs and rhs have opposing signs.
        let quotient = Int::new_from_abs_sign(quotient, opposing_signs);
        let remainder = remainder.as_int().wrapping_neg_if(opposing_signs); // rem always small enough for safe as_int conversion

        (quotient, remainder)
    }
}

impl<const LIMBS: usize, const RHS_LIMBS: usize> CheckedDiv<Int<RHS_LIMBS>> for Int<LIMBS> {
    fn checked_div(&self, rhs: &Int<RHS_LIMBS>) -> CtOption<Self> {
        self.checked_div(rhs)
    }
}

impl<const LIMBS: usize, const RHS_LIMBS: usize> Div<&NonZero<Int<RHS_LIMBS>>> for &Int<LIMBS> {
    type Output = CtOption<Int<LIMBS>>;

    fn div(self, rhs: &NonZero<Int<RHS_LIMBS>>) -> Self::Output {
        *self / *rhs
    }
}

impl<const LIMBS: usize, const RHS_LIMBS: usize> Div<&NonZero<Int<RHS_LIMBS>>> for Int<LIMBS> {
    type Output = CtOption<Int<LIMBS>>;

    fn div(self, rhs: &NonZero<Int<RHS_LIMBS>>) -> Self::Output {
        self / *rhs
    }
}

impl<const LIMBS: usize, const RHS_LIMBS: usize> Div<NonZero<Int<RHS_LIMBS>>> for &Int<LIMBS> {
    type Output = CtOption<Int<LIMBS>>;

    fn div(self, rhs: NonZero<Int<RHS_LIMBS>>) -> Self::Output {
        *self / rhs
    }
}

impl<const LIMBS: usize, const RHS_LIMBS: usize> Div<NonZero<Int<RHS_LIMBS>>> for Int<LIMBS> {
    type Output = CtOption<Int<LIMBS>>;

    fn div(self, rhs: NonZero<Int<RHS_LIMBS>>) -> Self::Output {
        self.checked_div(&rhs)
    }
}

impl<const LIMBS: usize> DivAssign<&NonZero<Int<LIMBS>>> for Int<LIMBS> {
    fn div_assign(&mut self, rhs: &NonZero<Int<LIMBS>>) {
        *self /= *rhs
    }
}

impl<const LIMBS: usize> DivAssign<NonZero<Int<LIMBS>>> for Int<LIMBS> {
    fn div_assign(&mut self, rhs: NonZero<Int<LIMBS>>) {
        *self = (*self / rhs).expect("cannot represent positive equivalent of Int::MIN as int");
    }
}

impl<const LIMBS: usize> DivVartime for Int<LIMBS> {
    fn div_vartime(&self, rhs: &NonZero<Int<LIMBS>>) -> Self {
        let (q, _r, lhs_sign, rhs_sign) = self.div_rem_base_vartime(rhs);
        let opposing_signs = lhs_sign.xor(rhs_sign);
        let q = Int::new_from_abs_sign(q, opposing_signs);
        q.expect("int divided by int fits in uint by construction")
    }
}

impl<const LIMBS: usize, const RHS_LIMBS: usize> Div<NonZero<Int<RHS_LIMBS>>>
    for Wrapping<Int<LIMBS>>
{
    type Output = Wrapping<Int<LIMBS>>;

    fn div(self, rhs: NonZero<Int<RHS_LIMBS>>) -> Self::Output {
        Wrapping((self.0 / rhs).expect("cannot represent positive equivalent of Int::MIN as int"))
    }
}

impl<const LIMBS: usize, const RHS_LIMBS: usize> Div<NonZero<Int<RHS_LIMBS>>>
    for &Wrapping<Int<LIMBS>>
{
    type Output = Wrapping<Int<LIMBS>>;

    fn div(self, rhs: NonZero<Int<RHS_LIMBS>>) -> Self::Output {
        *self / rhs
    }
}

impl<const LIMBS: usize, const RHS_LIMBS: usize> Div<&NonZero<Int<RHS_LIMBS>>>
    for &Wrapping<Int<LIMBS>>
{
    type Output = Wrapping<Int<LIMBS>>;

    fn div(self, rhs: &NonZero<Int<RHS_LIMBS>>) -> Self::Output {
        *self / *rhs
    }
}

impl<const LIMBS: usize, const RHS_LIMBS: usize> Div<&NonZero<Int<RHS_LIMBS>>>
    for Wrapping<Int<LIMBS>>
{
    type Output = Wrapping<Int<LIMBS>>;

    fn div(self, rhs: &NonZero<Int<RHS_LIMBS>>) -> Self::Output {
        self / *rhs
    }
}

impl<const LIMBS: usize> DivAssign<&NonZero<Int<LIMBS>>> for Wrapping<Int<LIMBS>> {
    fn div_assign(&mut self, rhs: &NonZero<Int<LIMBS>>) {
        *self = Wrapping(
            (self.0 / rhs).expect("cannot represent positive equivalent of Int::MIN as int"),
        );
    }
}

impl<const LIMBS: usize> DivAssign<NonZero<Int<LIMBS>>> for Wrapping<Int<LIMBS>> {
    fn div_assign(&mut self, rhs: NonZero<Int<LIMBS>>) {
        *self /= &rhs;
    }
}

impl<const LIMBS: usize, const RHS_LIMBS: usize> Rem<&NonZero<Int<RHS_LIMBS>>> for &Int<LIMBS> {
    type Output = Int<RHS_LIMBS>;

    fn rem(self, rhs: &NonZero<Int<RHS_LIMBS>>) -> Self::Output {
        *self % *rhs
    }
}

impl<const LIMBS: usize, const RHS_LIMBS: usize> Rem<&NonZero<Int<RHS_LIMBS>>> for Int<LIMBS> {
    type Output = Int<RHS_LIMBS>;

    fn rem(self, rhs: &NonZero<Int<RHS_LIMBS>>) -> Self::Output {
        self % *rhs
    }
}

impl<const LIMBS: usize, const RHS_LIMBS: usize> Rem<NonZero<Int<RHS_LIMBS>>> for &Int<LIMBS> {
    type Output = Int<RHS_LIMBS>;

    fn rem(self, rhs: NonZero<Int<RHS_LIMBS>>) -> Self::Output {
        *self % rhs
    }
}

impl<const LIMBS: usize, const RHS_LIMBS: usize> Rem<NonZero<Int<RHS_LIMBS>>> for Int<LIMBS> {
    type Output = Int<RHS_LIMBS>;

    fn rem(self, rhs: NonZero<Int<RHS_LIMBS>>) -> Self::Output {
        Self::rem(&self, &rhs)
    }
}

impl<const LIMBS: usize> RemAssign<&NonZero<Int<LIMBS>>> for Int<LIMBS> {
    fn rem_assign(&mut self, rhs: &NonZero<Int<LIMBS>>) {
        *self %= *rhs
    }
}

impl<const LIMBS: usize> RemAssign<NonZero<Int<LIMBS>>> for Int<LIMBS> {
    fn rem_assign(&mut self, rhs: NonZero<Int<LIMBS>>) {
        *self = *self % rhs;
    }
}

impl<const LIMBS: usize, const RHS_LIMBS: usize> Rem<NonZero<Int<RHS_LIMBS>>>
    for Wrapping<Int<LIMBS>>
{
    type Output = Wrapping<Int<RHS_LIMBS>>;

    fn rem(self, rhs: NonZero<Int<RHS_LIMBS>>) -> Self::Output {
        Wrapping(self.0 % rhs)
    }
}

impl<const LIMBS: usize, const RHS_LIMBS: usize> Rem<NonZero<Int<RHS_LIMBS>>>
    for &Wrapping<Int<LIMBS>>
{
    type Output = Wrapping<Int<RHS_LIMBS>>;

    fn rem(self, rhs: NonZero<Int<RHS_LIMBS>>) -> Self::Output {
        *self % rhs
    }
}

impl<const LIMBS: usize, const RHS_LIMBS: usize> Rem<&NonZero<Int<RHS_LIMBS>>>
    for &Wrapping<Int<LIMBS>>
{
    type Output = Wrapping<Int<RHS_LIMBS>>;

    fn rem(self, rhs: &NonZero<Int<RHS_LIMBS>>) -> Self::Output {
        *self % *rhs
    }
}

impl<const LIMBS: usize, const RHS_LIMBS: usize> Rem<&NonZero<Int<RHS_LIMBS>>>
    for Wrapping<Int<LIMBS>>
{
    type Output = Wrapping<Int<RHS_LIMBS>>;

    fn rem(self, rhs: &NonZero<Int<RHS_LIMBS>>) -> Self::Output {
        self % *rhs
    }
}

impl<const LIMBS: usize> RemAssign<NonZero<Int<LIMBS>>> for Wrapping<Int<LIMBS>> {
    fn rem_assign(&mut self, rhs: NonZero<Int<LIMBS>>) {
        *self %= &rhs;
    }
}

impl<const LIMBS: usize> RemAssign<&NonZero<Int<LIMBS>>> for Wrapping<Int<LIMBS>> {
    fn rem_assign(&mut self, rhs: &NonZero<Int<LIMBS>>) {
        *self = Wrapping(self.0 % rhs)
    }
}

#[cfg(test)]
mod tests {
    use crate::{ConstChoice, DivVartime, I128, Int, NonZero, Zero};

    #[test]
    #[allow(clippy::init_numbered_fields)]
    fn test_checked_div() {
        let min_plus_one = Int {
            0: I128::MIN.0.wrapping_add(&I128::ONE.0),
        };

        // lhs = min

        let result = I128::MIN.checked_div(&I128::MIN);
        assert_eq!(result.unwrap(), I128::ONE);

        let result = I128::MIN.checked_div(&I128::MINUS_ONE);
        assert!(bool::from(result.is_none()));

        let result = I128::MIN.checked_div(&I128::ZERO);
        assert!(bool::from(result.is_none()));

        let result = I128::MIN.checked_div(&I128::ONE);
        assert_eq!(result.unwrap(), I128::MIN);

        let result = I128::MIN.checked_div(&I128::MAX);
        assert_eq!(result.unwrap(), I128::MINUS_ONE);

        // lhs = -1

        let result = I128::MINUS_ONE.checked_div(&I128::MIN);
        assert_eq!(result.unwrap(), I128::ZERO);

        let result = I128::MINUS_ONE.checked_div(&I128::MINUS_ONE);
        assert_eq!(result.unwrap(), I128::ONE);

        let result = I128::MINUS_ONE.checked_div(&I128::ZERO);
        assert!(bool::from(result.is_none()));

        let result = I128::MINUS_ONE.checked_div(&I128::ONE);
        assert_eq!(result.unwrap(), I128::MINUS_ONE);

        let result = I128::MINUS_ONE.checked_div(&I128::MAX);
        assert_eq!(result.unwrap(), I128::ZERO);

        // lhs = 0

        let result = I128::ZERO.checked_div(&I128::MIN);
        assert_eq!(result.unwrap(), I128::ZERO);

        let result = I128::ZERO.checked_div(&I128::MINUS_ONE);
        assert_eq!(result.unwrap(), I128::ZERO);

        let result = I128::ZERO.checked_div(&I128::ZERO);
        assert!(bool::from(result.is_none()));

        let result = I128::ZERO.checked_div(&I128::ONE);
        assert_eq!(result.unwrap(), I128::ZERO);

        let result = I128::ZERO.checked_div(&I128::MAX);
        assert_eq!(result.unwrap(), I128::ZERO);

        // lhs = 1

        let result = I128::ONE.checked_div(&I128::MIN);
        assert_eq!(result.unwrap(), I128::ZERO);

        let result = I128::ONE.checked_div(&I128::MINUS_ONE);
        assert_eq!(result.unwrap(), I128::MINUS_ONE);

        let result = I128::ONE.checked_div(&I128::ZERO);
        assert!(bool::from(result.is_none()));

        let result = I128::ONE.checked_div(&I128::ONE);
        assert_eq!(result.unwrap(), I128::ONE);

        let result = I128::ONE.checked_div(&I128::MAX);
        assert_eq!(result.unwrap(), I128::ZERO);

        // lhs = max

        let result = I128::MAX.checked_div(&I128::MIN);
        assert_eq!(result.unwrap(), I128::ZERO);

        let result = I128::MAX.checked_div(&I128::MINUS_ONE);
        assert_eq!(result.unwrap(), min_plus_one);

        let result = I128::MAX.checked_div(&I128::ZERO);
        assert!(bool::from(result.is_none()));

        let result = I128::MAX.checked_div(&I128::ONE);
        assert_eq!(result.unwrap(), I128::MAX);

        let result = I128::MAX.checked_div(&I128::MAX);
        assert_eq!(result.unwrap(), I128::ONE);
    }

    #[test]
    fn test_checked_div_floor() {
        assert_eq!(
            I128::from(8).checked_div_floor(&I128::from(3)).unwrap(),
            I128::from(2)
        );
        assert_eq!(
            I128::from(-8).checked_div_floor(&I128::from(3)).unwrap(),
            I128::from(-3)
        );
        assert_eq!(
            I128::from(8).checked_div_floor(&I128::from(-3)).unwrap(),
            I128::from(-3)
        );
        assert_eq!(
            I128::from(-8).checked_div_floor(&I128::from(-3)).unwrap(),
            I128::from(2)
        );
    }

    #[test]
    fn test_checked_div_mod_floor() {
        let (quotient, remainder) =
            I128::MIN.checked_div_rem_floor(&I128::MINUS_ONE.to_nz().unwrap());
        assert_eq!(quotient.is_some(), ConstChoice::FALSE);
        assert_eq!(remainder, I128::ZERO);
    }

    #[test]
    fn div_vartime_through_trait() {
        fn myfn<T: DivVartime + Zero>(x: T, y: T) -> T {
            x.div_vartime(&NonZero::new(y).unwrap())
        }
        assert_eq!(myfn(I128::from(8), I128::from(3)), I128::from(2));
        assert_eq!(myfn(I128::from(-8), I128::from(3)), I128::from(-2));
        assert_eq!(myfn(I128::from(8), I128::from(-3)), I128::from(-2));
        assert_eq!(myfn(I128::from(-8), I128::from(-3)), I128::from(2));
        assert_eq!(myfn(I128::MAX, I128::from(1)), I128::MAX);
        assert_eq!(myfn(I128::MAX, I128::MAX), I128::from(1));
    }
}
