//! The Binary Extended GCD algorithm.
use super::gcd::bingcd_step;
use crate::const_choice::u32_max;
use crate::modular::bingcd::matrix::{DividedIntMatrix, DividedPatternMatrix, PatternMatrix, Unit};
use crate::{ConstChoice, Int, Limb, NonZeroUint, Odd, OddUint, U64, U128, Uint, Word};

/// Binary XGCD update step.
///
/// This is a condensed, constant time execution of the following algorithm:
/// ```text
/// if a mod 2 == 1
///    if a < b
///        (a, b) ← (b, a)
///        (f0, g0, f1, g1) ← (f1, g1, f0, g0)
///    a ← a - b
///    (f0, g0) ← (f0 - f1, g0 - g1)
/// if a > 0
///     a ← a/2
///     (f1, g1) ← (2f1, 2g1)
/// ```
/// where `matrix` represents
/// ```text
///  (f0 g0)
///  (f1 g1).
/// ```
///
/// Note: this algorithm assumes `b` to be an odd integer. The algorithm will likely not yield
/// the correct result when this is not the case.
///
/// Ref: Pornin, Algorithm 2, L8-17, <https://eprint.iacr.org/2020/972.pdf>.
#[inline(always)]
const fn binxgcd_step<const LIMBS: usize, const MATRIX_LIMBS: usize>(
    a: &mut Uint<LIMBS>,
    b: &mut Uint<LIMBS>,
    matrix: &mut DividedPatternMatrix<MATRIX_LIMBS>,
    halt_at_zero: ConstChoice,
) -> Word {
    let (a_odd, swap, j) = bingcd_step(a, b);

    // swap if a odd and a < b
    matrix.conditional_swap_rows(swap);

    // subtract b from a when a is odd
    matrix.conditional_subtract_bottom_row_from_top(a_odd);

    // Double the bottom row of the matrix when a was ≠ 0 and when not halting.
    matrix.conditional_double_bottom_row(a.is_nonzero().or(halt_at_zero.not()));

    j
}

/// Container for the raw output of the Binary XGCD algorithm.
pub(crate) struct RawXgcdOutput<const LIMBS: usize, MATRIX> {
    gcd: OddUint<LIMBS>,
    matrix: MATRIX,
}

pub(crate) type DividedPatternXgcdOutput<const LIMBS: usize> =
    RawXgcdOutput<LIMBS, DividedPatternMatrix<LIMBS>>;

impl<const LIMBS: usize> DividedPatternXgcdOutput<LIMBS> {
    /// Divide `self.matrix.inner` by `2^self.matrix.k`, allowing us to simplify `inner` from a
    /// [`DividedPatternMatrix`] to a [`PatternMatrix`].
    ///
    /// The performed divisions are modulo `lhs/gcd` and `rhs/gcd` to maintain the correctness of
    /// the XGCD state.
    ///
    /// This operation is 'fast' since it only applies the division to the top row of the matrix.
    /// This is allowed since it is assumed that `self.matrix * (lhs, rhs) = (gcd, 0)`; dividing
    /// the bottom row of the matrix by a constant has no impact since its inner-product with the
    /// input vector is zero.
    ///
    /// Executes in variable time w.r.t. `k_upper_bound`.
    pub(crate) const fn divide(self) -> PatternXgcdOutput<LIMBS> {
        let DividedPatternMatrix {
            inner: mut matrix,
            k,
            k_upper_bound,
            ..
        } = self.matrix;

        let PatternMatrix {
            m00: x,
            m01: y,
            m10: rhs_div_gcd,
            m11: lhs_div_gcd,
            ..
        } = &mut matrix;

        if k_upper_bound > 0 {
            *x = x.bounded_div2k_mod_q(
                k,
                k_upper_bound,
                &rhs_div_gcd.to_odd().expect("odd by construction"),
            );
            *y = y.bounded_div2k_mod_q(
                k,
                k_upper_bound,
                &lhs_div_gcd.to_odd().expect("odd by construction"),
            );
        }

        PatternXgcdOutput {
            gcd: self.gcd,
            matrix,
        }
    }
}

pub(crate) type PatternXgcdOutput<const LIMBS: usize> = RawXgcdOutput<LIMBS, PatternMatrix<LIMBS>>;

impl<const LIMBS: usize> PatternXgcdOutput<LIMBS> {
    /// Obtain the `gcd`.
    pub(crate) const fn gcd(&self) -> OddUint<LIMBS> {
        self.gcd
    }

    /// Obtain the bezout coefficients `(x, y)` such that `lhs * x + rhs * y = gcd`.
    pub(crate) const fn bezout_coefficients(&self) -> (Int<LIMBS>, Int<LIMBS>) {
        let PatternMatrix {
            m00,
            m01,
            m10,
            m11,
            pattern,
            ..
        } = self.matrix;

        // TODO: can we simplify this?
        let m10_sub_m00 = m10.wrapping_sub(&m00);
        let m11_sub_m01 = m11.wrapping_sub(&m01);
        let apply = Uint::lte(&m10_sub_m00, &m00).and(Uint::lte(&m11_sub_m01, &m01));

        let m00 = *Uint::select(&m00, &m10_sub_m00, apply)
            .wrapping_neg_if(apply.xor(pattern.not()))
            .as_int();
        let m01 = *Uint::select(&m01, &m11_sub_m01, apply)
            .wrapping_neg_if(apply.xor(pattern))
            .as_int();
        (m00, m01)
    }

    /// Obtain the quotients `lhs/gcd` and `rhs/gcd` from `matrix`.
    pub(crate) const fn quotients(&self) -> (Uint<LIMBS>, Uint<LIMBS>) {
        let PatternMatrix {
            m10: rhs_div_gcd,
            m11: lhs_div_gcd,
            ..
        } = self.matrix;
        (lhs_div_gcd, rhs_div_gcd)
    }
}

/// Number of bits used by [`OddUint::optimized_binxgcd`] to represent a "compact" [`Uint`].
const SUMMARY_BITS: u32 = U64::BITS - 1;

/// Number of limbs used to represent [`SUMMARY_BITS`].
const SUMMARY_LIMBS: usize = U64::LIMBS;

/// Twice the number of limbs used to represent [`SUMMARY_BITS`], i.e., two times [`SUMMARY_LIMBS`].
const DOUBLE_SUMMARY_LIMBS: usize = U128::LIMBS;

impl<const LIMBS: usize> OddUint<LIMBS> {
    /// The minimal number of binary GCD iterations required to guarantee successful completion.
    const MIN_BINXGCD_ITERATIONS: u32 = 2 * Self::BITS - 1;

    /// Given `(self, rhs)`, computes `(g, x, y)` s.t. `self * x + rhs * y = g = gcd(self, rhs)`,
    /// leveraging the Binary Extended GCD algorithm.
    pub(crate) const fn binxgcd_nz(&self, rhs: &NonZeroUint<LIMBS>) -> PatternXgcdOutput<LIMBS> {
        let (lhs_, rhs_) = (self.as_ref(), rhs.as_ref());

        // The `xgcd` subroutine requires `rhs` to be odd.
        // We leverage the equality gcd(lhs, rhs) = gcd(lhs, |lhs-rhs|) to deal with the case that
        // `rhs` is even.
        let rhs_is_even = rhs_.is_odd().not();
        let (abs_diff, rhs_gt_lhs) = lhs_.abs_diff(rhs_);
        let odd_rhs = Odd(Uint::select(rhs_, &abs_diff, rhs_is_even));

        let mut output = self.binxgcd_odd(&odd_rhs);
        let matrix = &mut output.matrix;

        // Modify the output to negate the transformation applied to the input.
        let case_one = rhs_is_even.and(rhs_gt_lhs);
        matrix.conditional_subtract_right_column_from_left(case_one);

        let case_two = rhs_is_even.and(rhs_gt_lhs.not());
        matrix.conditional_add_right_column_to_left(case_two);
        matrix.conditional_negate(case_two);

        output
    }

    /// Execute the classic Extended GCD algorithm.
    ///
    /// Given `(self, rhs)`, computes `(g, x, y)` s.t. `self * x + rhs * y = g = gcd(self, rhs)`.
    #[inline]
    pub(crate) const fn binxgcd_odd(&self, rhs: &Self) -> PatternXgcdOutput<LIMBS> {
        if LIMBS < 4 {
            self.classic_binxgcd(rhs).divide()
        } else {
            self.optimized_binxgcd(rhs).divide()
        }
    }

    /// Execute the classic Binary Extended GCD algorithm.
    ///
    /// Given `(self, rhs)`, computes `(g, x, y)` s.t. `self * x + rhs * y = g = gcd(self, rhs)`.
    ///
    /// Ref: Pornin, Optimized Binary GCD for Modular Inversion, Algorithm 1.
    /// <https://eprint.iacr.org/2020/972.pdf>.
    pub(crate) const fn classic_binxgcd(&self, rhs: &Self) -> DividedPatternXgcdOutput<LIMBS> {
        let (gcd, _, matrix, _) = self.partial_binxgcd::<LIMBS>(
            rhs.as_ref(),
            Self::MIN_BINXGCD_ITERATIONS,
            ConstChoice::TRUE,
        );
        DividedPatternXgcdOutput { gcd, matrix }
    }

    /// Given `(self, rhs)`, computes `(g, x, y)` s.t. `self * x + rhs * y = g = gcd(self, rhs)`,
    /// leveraging the Binary Extended GCD algorithm.
    ///
    /// **Warning**: `self` and `rhs` must be contained in an [U128] or larger.
    ///
    /// Note: this algorithm becomes more efficient than the classical algorithm for [Uint]s with
    /// relatively many `LIMBS`. A best-effort threshold is presented in [Self::binxgcd_].
    ///
    /// Note: the full algorithm has an additional parameter; this function selects the best-effort
    /// value for this parameter. You might be able to further tune your performance by calling the
    /// [Self::optimized_bingcd_] function directly.
    ///
    /// Ref: Pornin, Optimized Binary GCD for Modular Inversion, Algorithm 2.
    /// <https://eprint.iacr.org/2020/972.pdf>.
    pub(crate) const fn optimized_binxgcd(&self, rhs: &Self) -> DividedPatternXgcdOutput<LIMBS> {
        assert!(Self::BITS >= U128::BITS);
        self.optimized_binxgcd_::<SUMMARY_BITS, SUMMARY_LIMBS, DOUBLE_SUMMARY_LIMBS>(rhs)
    }

    /// Given `(self, rhs)`, computes `(g, x, y)`, s.t. `self * x + rhs * y = g = gcd(self, rhs)`,
    /// leveraging the optimized Binary Extended GCD algorithm.
    ///
    /// Ref: Pornin, Optimized Binary GCD for Modular Inversion, Algorithm 2.
    /// <https://eprint.iacr.org/2020/972.pdf>
    ///
    /// In summary, the optimized algorithm does not operate on `self` and `rhs` directly, but
    /// instead of condensed summaries that fit in few registers. Based on these summaries, an
    /// update matrix is constructed by which `self` and `rhs` are updated in larger steps.
    ///
    /// This function is generic over the following three values:
    /// - `K`: the number of bits used when summarizing `self` and `rhs` for the inner loop. The
    ///   `K+1` top bits and `K-1` least significant bits are selected. It is recommended to keep
    ///   `K` close to a (multiple of) the number of bits that fit in a single register.
    /// - `LIMBS_K`: should be chosen as the minimum number s.t. `Uint::<LIMBS>::BITS ≥ K`,
    /// - `LIMBS_2K`: should be chosen as the minimum number s.t. `Uint::<LIMBS>::BITS ≥ 2K`.
    pub(crate) const fn optimized_binxgcd_<
        const K: u32,
        const LIMBS_K: usize,
        const LIMBS_2K: usize,
    >(
        &self,
        rhs: &Self,
    ) -> DividedPatternXgcdOutput<LIMBS> {
        let (mut a, mut b) = (*self.as_ref(), *rhs.as_ref());
        let mut state = DividedIntMatrix::UNIT;

        let (mut a_is_negative, mut b_is_negative);
        let mut i = 0;
        while i < Self::MIN_BINXGCD_ITERATIONS.div_ceil(K - 1) {
            // Loop invariants:
            //  i) each iteration of this loop, `a.bits() + b.bits()` shrinks by at least K-1,
            //     until `b = 0`.
            // ii) `a` is odd.
            i += 1;

            // Construct compact_a and compact_b as the summary of a and b, respectively.
            let b_bits = b.bits();
            let n = u32_max(2 * K, u32_max(a.bits(), b_bits));
            let compact_a = a.compact::<K, LIMBS_2K>(n);
            let compact_b = b.compact::<K, LIMBS_2K>(n);
            let b_eq_compact_b =
                ConstChoice::from_u32_le(b_bits, K - 1).or(ConstChoice::from_u32_eq(n, 2 * K));

            // Compute the K-1 iteration update matrix from a_ and b_
            let (.., update_matrix, _) = compact_a
                .to_odd()
                .expect("a is always odd")
                .partial_binxgcd::<LIMBS_K>(&compact_b, K - 1, b_eq_compact_b);

            // Update `a` and `b` using the update matrix
            let (updated_a, updated_b) = update_matrix.extended_apply_to::<LIMBS, K>((a, b));
            (a, a_is_negative) = updated_a.dropped_abs_sign();
            (b, b_is_negative) = updated_b.dropped_abs_sign();

            state = update_matrix.mul_int_matrix(&state);

            // Correct for the sign change in a/b after dropping the extension.
            state.conditional_negate_top_row(a_is_negative);
            state.conditional_negate_bottom_row(b_is_negative);
        }

        let gcd = a
            .to_odd()
            .expect("gcd of an odd value with something else is always odd");

        let matrix = state.to_divided_pattern_matrix();
        DividedPatternXgcdOutput { gcd, matrix }
    }

    /// Executes the optimized Binary GCD inner loop.
    ///
    /// Ref: Pornin, Optimized Binary GCD for Modular Inversion, Algorithm 2.
    /// <https://eprint.iacr.org/2020/972.pdf>.
    ///
    /// The function outputs the reduced values `(a, b)` for the input values `(self, rhs)` as well
    /// as the matrix that yields the former two when multiplied with the latter two.
    ///
    /// Note: this implementation deviates slightly from the paper, in that it can be instructed to
    /// "run in place" (i.e., execute iterations that do nothing) once `a` becomes zero.
    /// This is done by passing a truthy `halt_at_zero`.
    ///
    /// The function executes in time variable in `iterations`.
    #[inline(always)]
    pub(super) const fn partial_binxgcd<const UPDATE_LIMBS: usize>(
        &self,
        rhs: &Uint<LIMBS>,
        iterations: u32,
        halt_at_zero: ConstChoice,
    ) -> (Self, Uint<LIMBS>, DividedPatternMatrix<UPDATE_LIMBS>, Word) {
        let (mut a, mut b) = (*self.as_ref(), *rhs);
        // This matrix corresponds with (f0, g0, f1, g1) in the paper.
        let mut matrix = DividedPatternMatrix::UNIT;

        // Compute the update matrix.
        // Note: to be consistent with the paper, the `binxgcd_step` algorithm requires the second
        // argument to be odd. Here, we have `a` odd, so we have to swap a and b before and after
        // calling the subroutine. The columns of the matrix have to be swapped accordingly.
        Uint::swap(&mut a, &mut b);
        matrix.swap_rows();

        let mut jacobi_neg = 0;
        let mut i = 0;

        while i < iterations {
            jacobi_neg ^=
                binxgcd_step::<LIMBS, UPDATE_LIMBS>(&mut a, &mut b, &mut matrix, halt_at_zero);
            i += 1;
        }

        // Undo swap
        Uint::swap(&mut a, &mut b);
        matrix.swap_rows();

        let a = a.to_odd().expect("a is always odd");
        (a, b, matrix, jacobi_neg)
    }
}

impl<const LIMBS: usize> Uint<LIMBS> {
    /// Compute the absolute difference between `self` and `rhs`.
    /// In addition to the result, also returns whether `rhs > self`.
    const fn abs_diff(&self, rhs: &Self) -> (Self, ConstChoice) {
        let (diff, borrow) = self.borrowing_sub(rhs, Limb::ZERO);
        let rhs_gt_self = borrow.is_nonzero();
        let abs_diff = diff.wrapping_neg_if(rhs_gt_self);
        (abs_diff, rhs_gt_self)
    }
}

#[cfg(all(test, not(miri)))]
mod tests {
    use crate::modular::bingcd::xgcd::PatternXgcdOutput;
    use crate::{ConcatMixed, Gcd, Uint};
    use core::ops::Div;
    use num_traits::Zero;

    mod test_extract_quotients {
        use crate::modular::bingcd::matrix::DividedPatternMatrix;
        use crate::modular::bingcd::xgcd::{DividedPatternXgcdOutput, RawXgcdOutput};
        use crate::{ConstChoice, U64, Uint};

        fn raw_binxgcdoutput_setup<const LIMBS: usize>(
            matrix: DividedPatternMatrix<LIMBS>,
        ) -> DividedPatternXgcdOutput<LIMBS> {
            RawXgcdOutput {
                gcd: Uint::<LIMBS>::ONE.to_odd().unwrap(),
                matrix,
            }
        }

        #[test]
        fn test_extract_quotients_unit() {
            let output =
                raw_binxgcdoutput_setup(DividedPatternMatrix::<{ U64::LIMBS }>::UNIT).divide();
            let (lhs_on_gcd, rhs_on_gcd) = output.quotients();
            assert_eq!(lhs_on_gcd, Uint::ONE);
            assert_eq!(rhs_on_gcd, Uint::ZERO);
        }

        #[test]
        fn test_extract_quotients_basic() {
            let output = raw_binxgcdoutput_setup(DividedPatternMatrix::<{ U64::LIMBS }>::new_u64(
                (0, 0, 5, 7),
                ConstChoice::FALSE,
                0,
                0,
            ))
            .divide();
            let (lhs_on_gcd, rhs_on_gcd) = output.quotients();
            assert_eq!(lhs_on_gcd, Uint::from(7u32));
            assert_eq!(rhs_on_gcd, Uint::from(5u32));

            let output = raw_binxgcdoutput_setup(DividedPatternMatrix::<{ U64::LIMBS }>::new_u64(
                (0, 0, 7u64, 5u64),
                ConstChoice::TRUE,
                0,
                0,
            ))
            .divide();
            let (lhs_on_gcd, rhs_on_gcd) = output.quotients();
            assert_eq!(lhs_on_gcd, Uint::from(5u32));
            assert_eq!(rhs_on_gcd, Uint::from(7u32));
        }
    }

    mod test_derive_bezout_coefficients {
        use crate::modular::bingcd::matrix::DividedPatternMatrix;
        use crate::modular::bingcd::xgcd::RawXgcdOutput;
        use crate::{ConstChoice, Int, U64, Uint};

        #[test]
        fn test_derive_bezout_coefficients_unit() {
            let output = RawXgcdOutput {
                gcd: Uint::ONE.to_odd().unwrap(),
                matrix: DividedPatternMatrix::<{ U64::LIMBS }>::UNIT,
            }
            .divide();
            let (x, y) = output.bezout_coefficients();
            assert_eq!(x, Int::ONE);
            assert_eq!(y, Int::ZERO);
        }

        #[test]
        fn test_derive_bezout_coefficients_basic() {
            let output = RawXgcdOutput {
                gcd: U64::ONE.to_odd().unwrap(),
                matrix: DividedPatternMatrix::new_u64(
                    (2u64, 3u64, 5u64, 5u64),
                    ConstChoice::TRUE,
                    0,
                    0,
                ),
            }
            .divide();
            let (x, y) = output.bezout_coefficients();
            assert_eq!(x, Int::from(2i32));
            assert_eq!(y, Int::from(-3i32));

            let output = RawXgcdOutput {
                gcd: U64::ONE.to_odd().unwrap(),
                matrix: DividedPatternMatrix::new_u64(
                    (2u64, 3u64, 3u64, 5u64),
                    ConstChoice::FALSE,
                    0,
                    1,
                ),
            }
            .divide();
            let (x, y) = output.bezout_coefficients();
            assert_eq!(x, Int::from(1i32));
            assert_eq!(y, Int::from(-2i32));
        }

        #[test]
        fn test_derive_bezout_coefficients_removes_doublings_easy() {
            let output = RawXgcdOutput {
                gcd: U64::ONE.to_odd().unwrap(),
                matrix: DividedPatternMatrix::new_u64(
                    (2u64, 6u64, 3u64, 5u64),
                    ConstChoice::TRUE,
                    1,
                    1,
                ),
            }
            .divide();
            let (x, y) = output.bezout_coefficients();
            assert_eq!(x, Int::ONE);
            assert_eq!(y, Int::from(-3i32));

            let output = RawXgcdOutput {
                gcd: U64::ONE.to_odd().unwrap(),
                matrix: DividedPatternMatrix::new_u64(
                    (120u64, 64u64, 7u64, 5u64),
                    ConstChoice::FALSE,
                    5,
                    6,
                ),
            }
            .divide();
            let (x, y) = output.bezout_coefficients();
            assert_eq!(x, Int::from(-9i32));
            assert_eq!(y, Int::from(2i32));
        }

        #[test]
        fn test_derive_bezout_coefficients_removes_doublings_for_odd_numbers() {
            let output = RawXgcdOutput {
                gcd: U64::ONE.to_odd().unwrap(),
                matrix: DividedPatternMatrix::new_u64(
                    (2u64, 6u64, 7u64, 5u64),
                    ConstChoice::FALSE,
                    3,
                    7,
                ),
            }
            .divide();
            let (x, y) = output.bezout_coefficients();
            assert_eq!(x, Int::from(-2i32));
            assert_eq!(y, Int::from(2i32));
        }
    }

    mod test_partial_binxgcd {
        use crate::modular::bingcd::matrix::DividedPatternMatrix;
        use crate::{ConstChoice, Gcd, Odd, U64};

        const A: Odd<U64> = U64::from_be_hex("CA048AFA63CD6A1F").to_odd().expect("odd");
        const B: U64 = U64::from_be_hex("AE693BF7BE8E5566");

        #[test]
        fn test_partial_binxgcd() {
            let (.., matrix, _) = A.partial_binxgcd::<{ U64::LIMBS }>(&B, 5, ConstChoice::TRUE);
            assert_eq!(matrix.k, 5);
            assert_eq!(
                matrix,
                DividedPatternMatrix::new_u64((8u64, 4u64, 2u64, 5u64), ConstChoice::TRUE, 5, 5)
            );
        }

        #[test]
        fn test_partial_binxgcd_constructs_correct_matrix() {
            let target_a = U64::from_be_hex("1CB3FB3FA1218FDB").to_odd().unwrap();
            let target_b = U64::from_be_hex("0EA028AF0F8966B6");

            let (new_a, new_b, matrix, _) =
                A.partial_binxgcd::<{ U64::LIMBS }>(&B, 5, ConstChoice::TRUE);

            assert_eq!(new_a, target_a);
            assert_eq!(new_b, target_b);

            let (computed_a, computed_b) =
                matrix.extended_apply_to::<{ U64::LIMBS }, 6>((A.get(), B));
            let computed_a = computed_a.dropped_abs_sign().0;
            let computed_b = computed_b.dropped_abs_sign().0;

            assert_eq!(computed_a, target_a);
            assert_eq!(computed_b, target_b);
        }

        const SMALL_A: Odd<U64> = U64::from_be_hex("0000000003CD6A1F").to_odd().expect("odd");
        const SMALL_B: U64 = U64::from_be_hex("000000000E8E5566");

        #[test]
        fn test_partial_binxgcd_halts() {
            let (gcd, _, matrix, _) =
                SMALL_A.partial_binxgcd::<{ U64::LIMBS }>(&SMALL_B, 60, ConstChoice::TRUE);
            assert_eq!(matrix.k, 35);
            assert_eq!(matrix.k_upper_bound, 60);
            assert_eq!(gcd.get(), SMALL_A.gcd(&SMALL_B));
        }

        #[test]
        fn test_partial_binxgcd_does_not_halt() {
            let (gcd, .., matrix, _) =
                SMALL_A.partial_binxgcd::<{ U64::LIMBS }>(&SMALL_B, 60, ConstChoice::FALSE);
            assert_eq!(matrix.k, 60);
            assert_eq!(matrix.k_upper_bound, 60);
            assert_eq!(gcd.get(), SMALL_A.gcd(&SMALL_B));
        }
    }

    /// Helper function to effectively test xgcd.
    fn test_xgcd<const LIMBS: usize, const DOUBLE: usize>(
        lhs: Uint<LIMBS>,
        rhs: Uint<LIMBS>,
        output: PatternXgcdOutput<LIMBS>,
    ) where
        Uint<LIMBS>: ConcatMixed<Uint<LIMBS>, MixedOutput = Uint<DOUBLE>>,
    {
        // Test the gcd
        assert_eq!(lhs.gcd(&rhs), output.gcd, "{lhs} {rhs}");

        // Test the quotients
        let (lhs_on_gcd, rhs_on_gcd) = output.quotients();
        assert_eq!(lhs_on_gcd, lhs.div(output.gcd.as_nz_ref()));
        assert_eq!(rhs_on_gcd, rhs.div(output.gcd.as_nz_ref()));

        // Test the Bezout coefficients for correctness
        let (x, y) = output.bezout_coefficients();
        assert_eq!(
            x.concatenating_mul_uint(&lhs) + y.concatenating_mul_uint(&rhs),
            *output.gcd.resize().as_int(),
        );

        // Test the Bezout coefficients for minimality
        assert!(x.abs() <= rhs.div(output.gcd.as_nz_ref()));
        assert!(y.abs() <= lhs.div(output.gcd.as_nz_ref()));
        if lhs != rhs {
            assert!(x.abs() <= rhs_on_gcd.shr(1) || rhs_on_gcd.is_zero());
            assert!(y.abs() <= lhs_on_gcd.shr(1) || lhs_on_gcd.is_zero());
        }
    }

    mod test_binxgcd_nz {
        use crate::modular::bingcd::xgcd::tests::test_xgcd;
        use crate::{
            ConcatMixed, Int, U64, U128, U192, U256, U384, U512, U768, U1024, U2048, U4096, U8192,
            Uint,
        };

        fn binxgcd_nz_test<const LIMBS: usize, const DOUBLE: usize>(
            lhs: Uint<LIMBS>,
            rhs: Uint<LIMBS>,
        ) where
            Uint<LIMBS>: ConcatMixed<Uint<LIMBS>, MixedOutput = Uint<DOUBLE>>,
        {
            let output = lhs.to_odd().unwrap().binxgcd_nz(&rhs.to_nz().unwrap());
            test_xgcd(lhs, rhs, output);
        }

        fn binxgcd_nz_tests<const LIMBS: usize, const DOUBLE: usize>()
        where
            Uint<LIMBS>: ConcatMixed<Uint<LIMBS>, MixedOutput = Uint<DOUBLE>>,
        {
            let max_int = *Int::MAX.as_uint();
            let int_abs_min = Int::MIN.abs();

            binxgcd_nz_test(Uint::ONE, Uint::ONE);
            binxgcd_nz_test(Uint::ONE, max_int);
            binxgcd_nz_test(Uint::ONE, int_abs_min);
            binxgcd_nz_test(Uint::ONE, Uint::MAX);
            binxgcd_nz_test(max_int, Uint::ONE);
            binxgcd_nz_test(max_int, max_int);
            binxgcd_nz_test(max_int, int_abs_min);
            binxgcd_nz_test(max_int, Uint::MAX);
            binxgcd_nz_test(Uint::MAX, Uint::ONE);
            binxgcd_nz_test(Uint::MAX, max_int);
            binxgcd_nz_test(Uint::MAX, int_abs_min);
            binxgcd_nz_test(Uint::MAX, Uint::MAX);
        }

        #[test]
        fn test_binxgcd_nz() {
            binxgcd_nz_tests::<{ U64::LIMBS }, { U128::LIMBS }>();
            binxgcd_nz_tests::<{ U128::LIMBS }, { U256::LIMBS }>();
            binxgcd_nz_tests::<{ U192::LIMBS }, { U384::LIMBS }>();
            binxgcd_nz_tests::<{ U256::LIMBS }, { U512::LIMBS }>();
            binxgcd_nz_tests::<{ U384::LIMBS }, { U768::LIMBS }>();
            binxgcd_nz_tests::<{ U512::LIMBS }, { U1024::LIMBS }>();
            binxgcd_nz_tests::<{ U1024::LIMBS }, { U2048::LIMBS }>();
            binxgcd_nz_tests::<{ U2048::LIMBS }, { U4096::LIMBS }>();
            binxgcd_nz_tests::<{ U4096::LIMBS }, { U8192::LIMBS }>();
        }
    }

    mod test_classic_binxgcd {
        use crate::modular::bingcd::xgcd::tests::test_xgcd;
        use crate::{
            ConcatMixed, Int, U64, U128, U192, U256, U384, U512, U768, U1024, U2048, U4096, U8192,
            Uint,
        };

        fn classic_binxgcd_test<const LIMBS: usize, const DOUBLE: usize>(
            lhs: Uint<LIMBS>,
            rhs: Uint<LIMBS>,
        ) where
            Uint<LIMBS>: ConcatMixed<Uint<LIMBS>, MixedOutput = Uint<DOUBLE>>,
        {
            let output = lhs
                .to_odd()
                .unwrap()
                .classic_binxgcd(&rhs.to_odd().unwrap())
                .divide();
            test_xgcd(lhs, rhs, output);
        }

        fn classic_binxgcd_tests<const LIMBS: usize, const DOUBLE: usize>()
        where
            Uint<LIMBS>: ConcatMixed<Uint<LIMBS>, MixedOutput = Uint<DOUBLE>>,
        {
            let max_int = *Int::MAX.as_uint();

            classic_binxgcd_test(Uint::ONE, Uint::ONE);
            classic_binxgcd_test(Uint::ONE, max_int);
            classic_binxgcd_test(Uint::ONE, Uint::MAX);
            classic_binxgcd_test(max_int, Uint::ONE);
            classic_binxgcd_test(max_int, max_int);
            classic_binxgcd_test(max_int, Uint::MAX);
            classic_binxgcd_test(Uint::MAX, Uint::ONE);
            classic_binxgcd_test(Uint::MAX, max_int);
            classic_binxgcd_test(Uint::MAX, Uint::MAX);
        }

        #[test]
        fn test_classic_binxgcd() {
            classic_binxgcd_tests::<{ U64::LIMBS }, { U128::LIMBS }>();
            classic_binxgcd_tests::<{ U128::LIMBS }, { U256::LIMBS }>();
            classic_binxgcd_tests::<{ U192::LIMBS }, { U384::LIMBS }>();
            classic_binxgcd_tests::<{ U256::LIMBS }, { U512::LIMBS }>();
            classic_binxgcd_tests::<{ U384::LIMBS }, { U768::LIMBS }>();
            classic_binxgcd_tests::<{ U512::LIMBS }, { U1024::LIMBS }>();
            classic_binxgcd_tests::<{ U1024::LIMBS }, { U2048::LIMBS }>();
            classic_binxgcd_tests::<{ U2048::LIMBS }, { U4096::LIMBS }>();
            classic_binxgcd_tests::<{ U4096::LIMBS }, { U8192::LIMBS }>();
        }
    }

    mod test_optimized_binxgcd {
        use crate::modular::bingcd::xgcd::tests::test_xgcd;
        use crate::modular::bingcd::xgcd::{DOUBLE_SUMMARY_LIMBS, SUMMARY_BITS, SUMMARY_LIMBS};
        use crate::{
            ConcatMixed, Int, U64, U128, U192, U256, U384, U512, U768, U1024, U2048, U4096, U8192,
            Uint,
        };

        fn test<const LIMBS: usize, const DOUBLE: usize>(lhs: Uint<LIMBS>, rhs: Uint<LIMBS>)
        where
            Uint<LIMBS>: ConcatMixed<Uint<LIMBS>, MixedOutput = Uint<DOUBLE>>,
        {
            let output = lhs
                .to_odd()
                .unwrap()
                .optimized_binxgcd(&rhs.to_odd().unwrap())
                .divide();
            test_xgcd(lhs, rhs, output);
        }

        fn run_tests<const LIMBS: usize, const DOUBLE: usize>()
        where
            Uint<LIMBS>: ConcatMixed<Uint<LIMBS>, MixedOutput = Uint<DOUBLE>>,
        {
            let upper_bound = *Int::MAX.as_uint();
            test(Uint::ONE, Uint::ONE);
            test(Uint::ONE, upper_bound);
            test(Uint::ONE, Uint::MAX);
            test(upper_bound, Uint::ONE);
            test(upper_bound, upper_bound);
            test(upper_bound, Uint::MAX);
            test(Uint::MAX, Uint::ONE);
            test(Uint::MAX, upper_bound);
            test(Uint::MAX, Uint::MAX);
        }

        #[test]
        fn test_optimized_binxgcd_edge_cases() {
            // If one of these tests fails, you have probably tweaked the SUMMARY_BITS,
            // SUMMARY_LIMBS or DOUBLE_SUMMARY_LIMBS settings. Please make sure to update these
            // tests accordingly.
            assert_eq!(SUMMARY_BITS, 63);
            assert_eq!(SUMMARY_LIMBS, U64::LIMBS);
            assert_eq!(DOUBLE_SUMMARY_LIMBS, U128::LIMBS);

            // Case #1: a > b but a.compact() < b.compact()
            let a = U256::from_be_hex(
                "1234567890ABCDEF80000000000000000000000000000000BEDCBA0987654321",
            );
            let b = U256::from_be_hex(
                "1234567890ABCDEF800000000000000000000000000000007EDCBA0987654321",
            );
            assert!(a > b);
            assert!(
                a.compact::<SUMMARY_BITS, DOUBLE_SUMMARY_LIMBS>(U256::BITS)
                    < b.compact::<SUMMARY_BITS, DOUBLE_SUMMARY_LIMBS>(U256::BITS)
            );
            test(a, b);

            // Case #2: a < b but a.compact() > b.compact()
            test(b, a);

            // Case #3: a > b but a.compact() = b.compact()
            let a = U256::from_be_hex(
                "1234567890ABCDEF80000000000000000000000000000000FEDCBA0987654321",
            );
            let b = U256::from_be_hex(
                "1234567890ABCDEF800000000000000000000000000000007EDCBA0987654321",
            );
            assert!(a > b);
            assert_eq!(
                a.compact::<SUMMARY_BITS, DOUBLE_SUMMARY_LIMBS>(U256::BITS),
                b.compact::<SUMMARY_BITS, DOUBLE_SUMMARY_LIMBS>(U256::BITS)
            );
            test(a, b);

            // Case #4: a < b but a.compact() = b.compact()
            test(b, a);
        }

        #[test]
        fn optimized_binxgcd() {
            run_tests::<{ U128::LIMBS }, { U256::LIMBS }>();
            run_tests::<{ U192::LIMBS }, { U384::LIMBS }>();
            run_tests::<{ U256::LIMBS }, { U512::LIMBS }>();
            run_tests::<{ U384::LIMBS }, { U768::LIMBS }>();
            run_tests::<{ U512::LIMBS }, { U1024::LIMBS }>();
            run_tests::<{ U1024::LIMBS }, { U2048::LIMBS }>();
            run_tests::<{ U2048::LIMBS }, { U4096::LIMBS }>();
            run_tests::<{ U4096::LIMBS }, { U8192::LIMBS }>();
        }
    }
}
