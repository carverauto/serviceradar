use crate::modular::bingcd::extension::ExtendedInt;
use crate::{ConstChoice, Uint};

pub trait Unit: Sized {
    /// The unit matrix.
    const UNIT: Self;
}

type Vector<T> = (T, T);

/// [`Int`] with an extra limb.
type ExtraLimbInt<const LIMBS: usize> = ExtendedInt<LIMBS, 1>;

/// 2x2-Matrix with integers for elements.
///
/// ### Representation
/// The internal state represents the matrix
/// ```text
/// [ m00  m01 ]
/// [ m10  m11 ]
/// ```
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct IntMatrix<const LIMBS: usize> {
    m00: ExtraLimbInt<LIMBS>,
    m01: ExtraLimbInt<LIMBS>,
    m10: ExtraLimbInt<LIMBS>,
    m11: ExtraLimbInt<LIMBS>,
}

impl<const LIMBS: usize> Unit for IntMatrix<LIMBS> {
    const UNIT: Self = Self {
        m00: ExtraLimbInt::ONE,
        m01: ExtraLimbInt::ZERO,
        m10: ExtraLimbInt::ZERO,
        m11: ExtraLimbInt::ONE,
    };
}

impl<const LIMBS: usize> IntMatrix<LIMBS> {
    /// Negate the top row of this matrix if `negate`; otherwise do nothing.
    pub(super) const fn conditional_negate_top_row(&mut self, negate: ConstChoice) {
        self.m00 = self.m00.wrapping_neg_if(negate);
        self.m01 = self.m01.wrapping_neg_if(negate);
    }

    /// Negate the bottom row of this matrix if `negate`; otherwise do nothing.
    pub(super) const fn conditional_negate_bottom_row(&mut self, negate: ConstChoice) {
        self.m10 = self.m10.wrapping_neg_if(negate);
        self.m11 = self.m11.wrapping_neg_if(negate);
    }

    pub(super) const fn to_pattern_matrix(self) -> PatternMatrix<LIMBS> {
        let (abs_m00, m00_is_negative) = self.m00.abs_sign();
        let (abs_m01, m01_is_negative) = self.m01.abs_sign();
        let (abs_m10, m10_is_negative) = self.m10.abs_sign();
        let (abs_m11, m11_is_negative) = self.m11.abs_sign();

        // Construct the pattern.
        let m00_is_zero = abs_m00.is_zero();
        let m01_is_zero = abs_m01.is_zero();
        let pattern_vote_1 = m00_is_zero.not().and(m00_is_negative.not());
        let pattern_vote_2 = m01_is_zero.not().and(m01_is_negative);

        let m00_and_m01_are_zero = m00_is_zero.and(m01_is_zero);
        let m10_is_zero = abs_m10.is_zero();
        let m11_is_zero = abs_m11.is_zero();
        let pattern_vote_3 = m00_and_m01_are_zero.and(m10_is_zero.not().and(m10_is_negative));
        let pattern_vote_4 = m00_and_m01_are_zero.and(m11_is_zero.not().and(m11_is_negative.not()));
        let pattern = pattern_vote_1
            .or(pattern_vote_2)
            .or(pattern_vote_3)
            .or(pattern_vote_4);

        PatternMatrix {
            m00: abs_m00.checked_drop_extension().expect("m00 fits"),
            m01: abs_m01.checked_drop_extension().expect("m01 fits"),
            m10: abs_m10.checked_drop_extension().expect("m10 fits"),
            m11: abs_m11.checked_drop_extension().expect("m11 fits"),
            pattern,
        }
    }
}

/// 2x2-Matrix where either the diagonal or off-diagonal elements are negative.
///
/// The internal state represents the matrix
/// ```text
///      true                 false
/// [  m00 -m01 ]         [ -m00  m01 ]
/// [ -m10  m11 ]   or    [  m10 -m11 ]
/// ```
/// depending on whether `pattern` is respectively truthy or not.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct PatternMatrix<const LIMBS: usize> {
    pub m00: Uint<LIMBS>,
    pub m01: Uint<LIMBS>,
    pub m10: Uint<LIMBS>,
    pub m11: Uint<LIMBS>,
    pub pattern: ConstChoice,
}

impl<const LIMBS: usize> PatternMatrix<LIMBS> {
    pub const UNIT: Self = Self {
        m00: Uint::ONE,
        m01: Uint::ZERO,
        m10: Uint::ZERO,
        m11: Uint::ONE,
        pattern: ConstChoice::TRUE,
    };

    /// Apply this matrix to a vector of [Uint]s, returning the result as a vector of
    /// [ExtendedInt]s.
    #[inline]
    pub(crate) const fn extended_apply_to<const VEC_LIMBS: usize>(
        &self,
        vec: Vector<Uint<VEC_LIMBS>>,
    ) -> Vector<ExtendedInt<VEC_LIMBS, LIMBS>> {
        let (a, b) = vec;
        let m00a = ExtendedInt::from_product(a, self.m00);
        let m10a = ExtendedInt::from_product(a, self.m10);
        let m01b = ExtendedInt::from_product(b, self.m01);
        let m11b = ExtendedInt::from_product(b, self.m11);
        (
            m00a.wrapping_sub(&m01b).wrapping_neg_if(self.pattern.not()),
            m11b.wrapping_sub(&m10a).wrapping_neg_if(self.pattern.not()),
        )
    }

    /// Wrapping apply this matrix to `rhs`. Return the result in a [`IntMatrix<RHS_LIMBS>`].
    #[inline]
    pub(super) const fn mul_int_matrix<const RHS_LIMBS: usize>(
        &self,
        rhs: &IntMatrix<RHS_LIMBS>,
    ) -> IntMatrix<RHS_LIMBS> {
        let a0 = rhs.m00.wrapping_mul((&self.m00, &self.pattern.not()));
        let a1 = rhs.m10.wrapping_mul((&self.m01, &self.pattern));
        let m00 = a0.wrapping_add(&a1);

        let b0 = rhs.m01.wrapping_mul((&self.m00, &self.pattern.not()));
        let b1 = rhs.m11.wrapping_mul((&self.m01, &self.pattern));
        let m01 = b0.wrapping_add(&b1);

        let c0 = rhs.m00.wrapping_mul((&self.m10, &self.pattern));
        let c1 = rhs.m10.wrapping_mul((&self.m11, &self.pattern.not()));
        let m10 = c0.wrapping_add(&c1);

        let d0 = rhs.m01.wrapping_mul((&self.m10, &self.pattern));
        let d1 = rhs.m11.wrapping_mul((&self.m11, &self.pattern.not()));
        let m11 = d0.wrapping_add(&d1);

        IntMatrix { m00, m01, m10, m11 }
    }

    /// Swap the rows of this matrix if `swap` is truthy. Otherwise, do nothing.
    #[inline]
    pub(crate) const fn conditional_swap_rows(&mut self, swap: ConstChoice) {
        Uint::conditional_swap(&mut self.m00, &mut self.m10, swap);
        Uint::conditional_swap(&mut self.m01, &mut self.m11, swap);
        self.pattern = self.pattern.xor(swap);
    }

    /// Subtract the bottom row from the top if `subtract` is truthy. Otherwise, do nothing.
    #[inline]
    pub(crate) const fn conditional_subtract_bottom_row_from_top(&mut self, subtract: ConstChoice) {
        // Note: because the signs of the internal representation are stored in `pattern`,
        // subtracting one row from another involves _adding_ these rows instead.
        self.m00 = Uint::select(&self.m00, &self.m00.wrapping_add(&self.m10), subtract);
        self.m01 = Uint::select(&self.m01, &self.m01.wrapping_add(&self.m11), subtract);
    }

    /// Subtract the right column from the left if `subtract` is truthy. Otherwise, do nothing.
    #[inline]
    pub(crate) const fn conditional_subtract_right_column_from_left(
        &mut self,
        subtract: ConstChoice,
    ) {
        // Note: because the signs of the internal representation are stored in `pattern`,
        // subtracting one column from another involves _adding_ these columns instead.
        self.m00 = Uint::select(&self.m00, &self.m00.wrapping_add(&self.m01), subtract);
        self.m10 = Uint::select(&self.m10, &self.m10.wrapping_add(&self.m11), subtract);
    }

    /// If `add` is truthy, add the right column to the left. Otherwise, do nothing.
    #[inline]
    pub(crate) const fn conditional_add_right_column_to_left(&mut self, add: ConstChoice) {
        // Note: because the signs of the internal representation are stored in `pattern`,
        // subtracting one column from another involves _adding_ these columns instead.
        self.m00 = Uint::select(&self.m00, &self.m01.wrapping_sub(&self.m00), add);
        self.m10 = Uint::select(&self.m10, &self.m11.wrapping_sub(&self.m10), add);
    }

    /// Double the bottom row of this matrix if `double` is truthy. Otherwise, do nothing.
    #[inline]
    pub(crate) const fn conditional_double_bottom_row(&mut self, double: ConstChoice) {
        self.m10 = Uint::select(&self.m10, &self.m10.overflowing_shl1().0, double);
        self.m11 = Uint::select(&self.m11, &self.m11.overflowing_shl1().0, double);
    }

    /// Negate the elements in this matrix if `negate` is truthy. Otherwise, do nothing.
    #[inline]
    pub(crate) const fn conditional_negate(&mut self, negate: ConstChoice) {
        self.pattern = self.pattern.xor(negate);
    }
}

/// A matrix whose elements still need to be divided by `2^k`.
///
/// Since some of the operations conditionally increase `k`, this struct furthermore keeps track of
/// `k_upper_bound`; an upper bound on the value of `k`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct DividedMatrix<const LIMBS: usize, MATRIX: Unit> {
    pub(super) inner: MATRIX,
    pub k: u32,
    pub k_upper_bound: u32,
}

impl<const LIMBS: usize, Matrix: Unit> Unit for DividedMatrix<LIMBS, Matrix> {
    const UNIT: Self = Self {
        inner: Matrix::UNIT,
        k: 0,
        k_upper_bound: 0,
    };
}

/// Variation on [`PatternMatrix`], where the contents of the matrix need to be divided by
/// `2^k`.
/// The internal state represents the matrix
/// ```text
///      true                       false
/// [  m00 -m01 ]               [ -m00  m01 ]
/// [ -m10  m11 ] / 2^k   or    [  m10 -m11 ] / 2^k
/// ```
/// depending on whether `pattern` is respectively truthy or not.
///
/// Since some of the operations conditionally increase `k`, this struct furthermore keeps track of
/// `k_upper_bound`; an upper bound on the value of `k`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct DividedPatternMatrix<const LIMBS: usize> {
    pub(super) inner: PatternMatrix<LIMBS>,
    pub k: u32,
    pub k_upper_bound: u32,
}

impl<const LIMBS: usize> DividedPatternMatrix<LIMBS> {
    /// The unit matrix.
    pub const UNIT: Self = Self {
        inner: PatternMatrix::UNIT,
        k: 0,
        k_upper_bound: 0,
    };

    /// Apply this matrix to a vector of [Uint]s, returning the result as a vector of
    /// [ExtendedInt]s.
    #[inline]
    #[allow(unused)] // save for optimized xgcd
    pub const fn extended_apply_to<const VEC_LIMBS: usize, const UPPER_BOUND: u32>(
        &self,
        vec: Vector<Uint<VEC_LIMBS>>,
    ) -> Vector<ExtendedInt<VEC_LIMBS, LIMBS>> {
        let (a, b) = self.inner.extended_apply_to(vec);
        (
            a.bounded_div_2k::<UPPER_BOUND>(self.k),
            b.bounded_div_2k::<UPPER_BOUND>(self.k),
        )
    }

    /// Apply this matrix to a vector of [Uint]s, returning the result as a vector of
    /// [ExtendedInt]s.
    #[inline]
    pub const fn extended_apply_to_vartime<const VEC_LIMBS: usize>(
        &self,
        vec: Vector<Uint<VEC_LIMBS>>,
    ) -> Vector<ExtendedInt<VEC_LIMBS, LIMBS>> {
        let (a, b) = self.inner.extended_apply_to(vec);
        (a.div_2k_vartime(self.k), b.div_2k_vartime(self.k))
    }

    /// Multiply `self` with `rhs`. Return the result as a [`DividedIntMatrix<LIMBS>`].
    #[inline]
    pub const fn mul_int_matrix<const RHS_LIMBS: usize>(
        &self,
        rhs: &DividedIntMatrix<RHS_LIMBS>,
    ) -> DividedIntMatrix<RHS_LIMBS> {
        DividedIntMatrix {
            inner: self.inner.mul_int_matrix(&rhs.inner),
            k: self.k + rhs.k,
            k_upper_bound: self.k_upper_bound + rhs.k_upper_bound,
        }
    }

    /// Swap the rows of this matrix if `swap` is truthy. Otherwise, do nothing.
    #[inline]
    pub const fn conditional_swap_rows(&mut self, swap: ConstChoice) {
        self.inner.conditional_swap_rows(swap);
    }

    /// Swap the rows of this matrix.
    #[inline]
    pub const fn swap_rows(&mut self) {
        self.conditional_swap_rows(ConstChoice::TRUE);
    }

    /// Subtract the bottom row from the top if `subtract` is truthy. Otherwise, do nothing.
    #[inline]
    pub const fn conditional_subtract_bottom_row_from_top(&mut self, subtract: ConstChoice) {
        self.inner
            .conditional_subtract_bottom_row_from_top(subtract);
    }

    /// Double the bottom row of this matrix if `double` is truthy. Otherwise, do nothing.
    #[inline]
    pub const fn conditional_double_bottom_row(&mut self, double: ConstChoice) {
        self.inner.conditional_double_bottom_row(double);
        self.k = double.select_u32(self.k, self.k + 1);
        self.k_upper_bound += 1;
    }
}

pub(crate) type DividedIntMatrix<const LIMBS: usize> = DividedMatrix<LIMBS, IntMatrix<LIMBS>>;

impl<const LIMBS: usize> DividedIntMatrix<LIMBS> {
    /// Negate the top row of this matrix if `negate`; otherwise do nothing.
    pub(super) const fn conditional_negate_top_row(&mut self, negate: ConstChoice) {
        self.inner.conditional_negate_top_row(negate);
    }

    /// Negate the bottom row of this matrix if `negate`; otherwise do nothing.
    pub(super) const fn conditional_negate_bottom_row(&mut self, negate: ConstChoice) {
        self.inner.conditional_negate_bottom_row(negate);
    }

    pub(super) const fn to_divided_pattern_matrix(self) -> DividedPatternMatrix<LIMBS> {
        DividedPatternMatrix {
            inner: self.inner.to_pattern_matrix(),
            k: self.k,
            k_upper_bound: self.k_upper_bound,
        }
    }
}

#[cfg(test)]
mod tests {
    use crate::modular::bingcd::matrix::{DividedPatternMatrix, PatternMatrix};
    use crate::{ConstChoice, U64, U256, Uint};

    impl<const LIMBS: usize> PatternMatrix<LIMBS> {
        pub(crate) const fn new_u64(matrix: (u64, u64, u64, u64), pattern: ConstChoice) -> Self {
            Self {
                m00: Uint::from_u64(matrix.0),
                m01: Uint::from_u64(matrix.1),
                m10: Uint::from_u64(matrix.2),
                m11: Uint::from_u64(matrix.3),
                pattern,
            }
        }
    }

    impl<const LIMBS: usize> DividedPatternMatrix<LIMBS> {
        pub(crate) const fn new_u64(
            matrix: (u64, u64, u64, u64),
            pattern: ConstChoice,
            k: u32,
            k_upper_bound: u32,
        ) -> Self {
            Self {
                inner: PatternMatrix::new_u64(matrix, pattern),
                k,
                k_upper_bound,
            }
        }
    }

    const X: DividedPatternMatrix<{ U256::LIMBS }> =
        DividedPatternMatrix::new_u64((1u64, 7u64, 23u64, 53u64), ConstChoice::TRUE, 6, 8);

    #[test]
    fn test_wrapping_apply_to() {
        let a = U64::from_be_hex("CA048AFA63CD6A1F");
        let b = U64::from_be_hex("AE693BF7BE8E5566");
        let matrix = DividedPatternMatrix::<{ U64::LIMBS }>::new_u64(
            (288, 208, 310, 679),
            ConstChoice::TRUE,
            17,
            17,
        );

        let (a_, b_) = matrix.extended_apply_to::<{ U64::LIMBS }, 18>((a, b));
        assert_eq!(
            a_.dropped_abs_sign().0,
            Uint::from_be_hex("002AC7CDD032B9B9")
        );
        assert_eq!(
            b_.dropped_abs_sign().0,
            Uint::from_be_hex("006CFBCEE172C863")
        );
    }

    #[test]
    fn test_swap() {
        let mut y = X;
        y.swap_rows();
        let target = DividedPatternMatrix::new_u64((23, 53, 1, 7), ConstChoice::FALSE, 6, 8);
        assert_eq!(y, target);
    }

    #[test]
    fn test_conditional_swap() {
        let mut y = X;
        y.conditional_swap_rows(ConstChoice::FALSE);
        assert_eq!(y, X);
        y.conditional_swap_rows(ConstChoice::TRUE);
        let target = DividedPatternMatrix::new_u64((23, 53, 1, 7), ConstChoice::FALSE, 6, 8);
        assert_eq!(y, target);
    }

    #[test]
    fn test_conditional_subtract_bottom_row_from_top() {
        let mut y = X;
        y.conditional_subtract_bottom_row_from_top(ConstChoice::FALSE);
        assert_eq!(y, X);
        y.conditional_subtract_bottom_row_from_top(ConstChoice::TRUE);
        let target =
            DividedPatternMatrix::new_u64((24u64, 60u64, 23u64, 53u64), ConstChoice::TRUE, 6, 8);
        assert_eq!(y, target);
    }

    #[test]
    fn test_conditional_double() {
        let mut y = X;
        y.conditional_double_bottom_row(ConstChoice::FALSE);
        let target =
            DividedPatternMatrix::new_u64((1u64, 7u64, 23u64, 53u64), ConstChoice::TRUE, 6, 9);
        assert_eq!(y, target);
        y.conditional_double_bottom_row(ConstChoice::TRUE);
        let target =
            DividedPatternMatrix::new_u64((1u64, 7u64, 46u64, 106u64), ConstChoice::TRUE, 7, 10);
        assert_eq!(y, target);
    }

    #[test]
    fn test_conditional_add_right_column_to_left() {
        let mut y = X.inner;
        y.conditional_add_right_column_to_left(ConstChoice::FALSE);
        assert_eq!(y, X.inner);
        y.conditional_add_right_column_to_left(ConstChoice::TRUE);

        let target = PatternMatrix::new_u64((6u64, 7u64, 30u64, 53u64), ConstChoice::TRUE);
        assert_eq!(y, target);
    }

    #[test]
    fn test_conditional_subtract_right_column_from_left() {
        let mut y = X.inner;
        y.conditional_subtract_right_column_from_left(ConstChoice::FALSE);
        assert_eq!(y, X.inner);
        y.conditional_subtract_right_column_from_left(ConstChoice::TRUE);
        let target = PatternMatrix::new_u64((8u64, 7u64, 76u64, 53u64), ConstChoice::TRUE);
        assert_eq!(y, target);
    }
}
