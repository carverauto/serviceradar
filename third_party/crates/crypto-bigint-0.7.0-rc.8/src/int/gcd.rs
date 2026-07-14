//! This module implements (a constant variant of) the Optimized Extended Binary GCD algorithm,
//! which is described by Pornin in "Optimized Binary GCD for Modular Inversion".
//! Ref: <https://eprint.iacr.org/2020/972.pdf>

use crate::const_choice::u32_min;
use crate::uint::gcd::{OddUintXgcdOutput, impl_gcd_uint_lhs, impl_gcd_uint_rhs};
use crate::{
    ConstChoice, Gcd, Int, NonZero, NonZeroInt, NonZeroUint, Odd, OddInt, OddUint, Uint, Xgcd,
};

impl<const LIMBS: usize> Int<LIMBS> {
    /// Compute the greatest common divisor of `self` and `rhs`.
    pub const fn gcd_uint(&self, rhs: &Uint<LIMBS>) -> Uint<LIMBS> {
        self.abs().gcd_uint(rhs)
    }

    /// Compute the greatest common divisor of `self` and `rhs`.
    ///
    /// Executes in variable time w.r.t. all input parameters.
    pub const fn gcd_uint_vartime(&self, rhs: &Uint<LIMBS>) -> Uint<LIMBS> {
        self.abs().gcd_uint_vartime(rhs)
    }

    /// Executes the Extended GCD algorithm.
    ///
    /// Given `(self, rhs)`, computes `(g, x, y)`, s.t. `self * x + rhs * y = g = gcd(self, rhs)`.
    pub const fn xgcd(&self, rhs: &Self) -> IntXgcdOutput<LIMBS> {
        // Make sure `self` and `rhs` are nonzero.
        let self_is_zero = self.is_nonzero().not();
        let self_nz = Int::select(self, &Int::ONE, self_is_zero)
            .to_nz()
            .expect("self is non zero by construction");
        let rhs_is_zero = rhs.is_nonzero().not();
        let rhs_nz = Int::select(rhs, &Int::ONE, rhs_is_zero)
            .to_nz()
            .expect("rhs is non zero by construction");

        let NonZeroIntXgcdOutput {
            gcd,
            mut x,
            mut y,
            mut lhs_on_gcd,
            mut rhs_on_gcd,
        } = self_nz.xgcd(&rhs_nz);

        // Correct the gcd in case self and/or rhs was zero
        let mut gcd = *gcd.as_ref();
        gcd = Uint::select(&gcd, &rhs.abs(), self_is_zero);
        gcd = Uint::select(&gcd, &self.abs(), rhs_is_zero);

        // Correct the Bézout coefficients in case self and/or rhs was zero.
        let signum_self = Int::new_from_abs_sign(Uint::ONE, self.is_negative()).expect("+/- 1");
        let signum_rhs = Int::new_from_abs_sign(Uint::ONE, rhs.is_negative()).expect("+/- 1");
        x = Int::select(&x, &Int::ZERO, self_is_zero);
        y = Int::select(&y, &signum_rhs, self_is_zero);
        x = Int::select(&x, &signum_self, rhs_is_zero);
        y = Int::select(&y, &Int::ZERO, rhs_is_zero);

        // Correct the quotients in case self and/or rhs was zero.
        lhs_on_gcd = Int::select(&lhs_on_gcd, &signum_self, rhs_is_zero);
        lhs_on_gcd = Int::select(&lhs_on_gcd, &Int::ZERO, self_is_zero);
        rhs_on_gcd = Int::select(&rhs_on_gcd, &signum_rhs, self_is_zero);
        rhs_on_gcd = Int::select(&rhs_on_gcd, &Int::ZERO, rhs_is_zero);

        IntXgcdOutput {
            gcd,
            x,
            y,
            lhs_on_gcd,
            rhs_on_gcd,
        }
    }
}

impl<const LIMBS: usize> NonZero<Int<LIMBS>> {
    /// Compute the greatest common divisor of `self` and `rhs`.
    pub const fn gcd_uint(&self, rhs: &Uint<LIMBS>) -> NonZero<Uint<LIMBS>> {
        self.abs().gcd_uint(rhs)
    }

    /// Compute the greatest common divisor of `self` and `rhs`.
    ///
    /// Executes in variable time w.r.t. all input parameters.
    pub const fn gcd_uint_vartime(&self, rhs: &Uint<LIMBS>) -> NonZeroUint<LIMBS> {
        self.abs().gcd_uint_vartime(rhs)
    }

    /// Execute the Extended GCD algorithm.
    ///
    /// Given `(self, rhs)`, computes `(g, x, y)` s.t. `self * x + rhs * y = g = gcd(self, rhs)`.
    pub const fn xgcd(&self, rhs: &Self) -> NonZeroIntXgcdOutput<LIMBS> {
        let (mut lhs, mut rhs) = (*self.as_ref(), *rhs.as_ref());

        // Leverage the property that gcd(2^k * a, 2^k *b) = 2^k * gcd(a, b)
        let i = lhs.0.trailing_zeros();
        let j = rhs.0.trailing_zeros();
        let k = u32_min(i, j);
        lhs = lhs.shr(k);
        rhs = rhs.shr(k);

        // Note: at this point, either lhs or rhs is odd (or both).
        // Swap to make sure lhs is odd.
        let swap = ConstChoice::from_u32_lt(j, i);
        Int::conditional_swap(&mut lhs, &mut rhs, swap);
        let lhs = lhs.to_odd().expect("odd by construction");
        let rhs = rhs.to_nz().expect("non-zero by construction");

        let OddIntXgcdOutput {
            gcd,
            mut x,
            mut y,
            mut lhs_on_gcd,
            mut rhs_on_gcd,
        } = lhs.xgcd(&rhs);

        // Account for the parameter swap
        Int::conditional_swap(&mut x, &mut y, swap);
        Int::conditional_swap(&mut lhs_on_gcd, &mut rhs_on_gcd, swap);

        // Reintroduce the factor 2^k to the gcd.
        let gcd = gcd
            .as_ref()
            .shl(k)
            .to_nz()
            .expect("is non-zero by construction");

        NonZeroIntXgcdOutput {
            gcd,
            x,
            y,
            lhs_on_gcd,
            rhs_on_gcd,
        }
    }
}

impl<const LIMBS: usize> Odd<Int<LIMBS>> {
    /// Compute the greatest common divisor of `self` and `rhs`.
    pub const fn gcd_uint(&self, rhs: &Uint<LIMBS>) -> Odd<Uint<LIMBS>> {
        self.abs().gcd_uint(rhs)
    }

    /// Compute the greatest common divisor of `self` and `rhs`.
    ///
    /// Executes in variable time w.r.t. all input parameters.
    pub const fn gcd_uint_vartime(&self, rhs: &Uint<LIMBS>) -> OddUint<LIMBS> {
        self.abs().gcd_uint_vartime(rhs)
    }

    /// Execute the Extended GCD algorithm.
    ///
    /// Given `(self, rhs)`, computes `(g, x, y)` s.t. `self * x + rhs * y = g = gcd(self, rhs)`.
    pub const fn xgcd(&self, rhs: &NonZero<Int<LIMBS>>) -> OddIntXgcdOutput<LIMBS> {
        let (abs_lhs, sgn_lhs) = self.abs_sign();
        let (abs_rhs, sgn_rhs) = rhs.abs_sign();

        let OddUintXgcdOutput {
            gcd,
            mut x,
            mut y,
            lhs_on_gcd: abs_lhs_on_gcd,
            rhs_on_gcd: abs_rhs_on_gcd,
        } = OddUintXgcdOutput::from_pattern_output(abs_lhs.binxgcd_nz(&abs_rhs));

        x = x.wrapping_neg_if(sgn_lhs);
        y = y.wrapping_neg_if(sgn_rhs);
        let lhs_on_gcd = Int::new_from_abs_sign(abs_lhs_on_gcd, sgn_lhs).expect("no overflow");
        let rhs_on_gcd = Int::new_from_abs_sign(abs_rhs_on_gcd, sgn_rhs).expect("no overflow");

        OddIntXgcdOutput {
            gcd,
            x,
            y,
            lhs_on_gcd,
            rhs_on_gcd,
        }
    }
}

/// Output of the Binary XGCD algorithm applied to two [`Int`]s.
pub type IntXgcdOutput<const LIMBS: usize> = XgcdOutput<LIMBS, Uint<LIMBS>>;

/// Output of the Binary XGCD algorithm applied to two [`NonZero<Int<LIMBS>>`]s.
pub type NonZeroIntXgcdOutput<const LIMBS: usize> = XgcdOutput<LIMBS, NonZeroUint<LIMBS>>;

/// Output of the Binary XGCD algorithm applied to two [`Odd<Int<LIMBS>>`]s.
pub type OddIntXgcdOutput<const LIMBS: usize> = XgcdOutput<LIMBS, OddUint<LIMBS>>;

#[derive(Debug, Copy, Clone)]
pub struct XgcdOutput<const LIMBS: usize, T: Copy> {
    pub gcd: T,
    pub x: Int<LIMBS>,
    pub y: Int<LIMBS>,
    pub lhs_on_gcd: Int<LIMBS>,
    pub rhs_on_gcd: Int<LIMBS>,
}

impl<const LIMBS: usize, T: Copy> XgcdOutput<LIMBS, T> {
    /// Return the `gcd`.
    pub fn gcd(&self) -> T {
        self.gcd
    }

    /// Return the quotients `lhs.gcd` and `rhs/gcd`.
    pub fn quotients(&self) -> (Int<LIMBS>, Int<LIMBS>) {
        (self.lhs_on_gcd, self.rhs_on_gcd)
    }

    /// Return the Bézout coefficients `x` and `y` s.t. `lhs * x + rhs * y = gcd`.
    pub fn bezout_coefficients(&self) -> (Int<LIMBS>, Int<LIMBS>) {
        (self.x, self.y)
    }
}

macro_rules! impl_int_gcd_abs_lhs {
    ($slf:ty, [$($rhs:ty),+]) => {
        $(
            impl_int_gcd_abs_lhs!($slf, $rhs, $rhs);
        )+
    };
    ($slf:ty, $rhs:ty, $out:ty) => {
        impl<const LIMBS: usize> Gcd<$rhs> for $slf {
            type Output = $out;

            #[inline]
            fn gcd(&self, rhs: &$rhs) -> Self::Output {
                rhs.gcd_uint(&self.abs())
            }

            #[inline]
            fn gcd_vartime(&self, rhs: &$rhs) -> Self::Output {
                rhs.gcd_uint_vartime(&self.abs())
            }
        }
    };
}

macro_rules! impl_int_gcd_abs_rhs {
    ($slf:ty, [$($rhs:ty),+], $out:ty) => {
        $(
            impl_int_gcd_abs_rhs!($slf, $rhs, $out);
        )+
    };
    ($slf:ty, $rhs:ty, $out:ty) => {
        impl<const LIMBS: usize> Gcd<$rhs> for $slf {
            type Output = $out;

            #[inline]
            fn gcd(&self, rhs: &$rhs) -> Self::Output {
                self.gcd_uint(&rhs.abs())
            }

            #[inline]
            fn gcd_vartime(&self, rhs: &$rhs) -> Self::Output {
                self.gcd_uint_vartime(&rhs.abs())
            }
        }
    }
}

// avoiding (NonZero|Odd)•(NonZero|Odd) combinations except for Self•Self to limit compilation time
impl_gcd_uint_lhs!(Int<LIMBS>, Uint<LIMBS>, Uint<LIMBS>);
impl_gcd_uint_lhs!(NonZeroInt<LIMBS>, Uint<LIMBS>, NonZeroUint<LIMBS>);
impl_gcd_uint_lhs!(OddInt<LIMBS>, Uint<LIMBS>, OddUint<LIMBS>);
impl_gcd_uint_rhs!(Uint<LIMBS>, Int<LIMBS>, Uint<LIMBS>);
impl_gcd_uint_rhs!(Uint<LIMBS>, NonZeroInt<LIMBS>, NonZeroUint<LIMBS>);
impl_gcd_uint_rhs!(Uint<LIMBS>, OddInt<LIMBS>, OddUint<LIMBS>);
impl_int_gcd_abs_lhs!(Int<LIMBS>, Int<LIMBS>, Uint<LIMBS>);
impl_int_gcd_abs_lhs!(Int<LIMBS>, [NonZeroUint<LIMBS>, OddUint<LIMBS>]);
impl_int_gcd_abs_rhs!(NonZeroInt<LIMBS>, [Int<LIMBS>, NonZeroInt<LIMBS>], NonZeroUint<LIMBS>);
impl_int_gcd_abs_rhs!(OddInt<LIMBS>, [Int<LIMBS>, OddInt<LIMBS>], OddUint<LIMBS>);

impl<const LIMBS: usize> Xgcd for Int<LIMBS> {
    type Output = IntXgcdOutput<LIMBS>;

    fn xgcd(&self, rhs: &Int<LIMBS>) -> Self::Output {
        self.xgcd(rhs)
    }

    fn xgcd_vartime(&self, rhs: &Int<LIMBS>) -> Self::Output {
        // TODO(#853): implement vartime
        self.xgcd(rhs)
    }
}

impl<const LIMBS: usize> Xgcd for NonZeroInt<LIMBS> {
    type Output = NonZeroIntXgcdOutput<LIMBS>;

    fn xgcd(&self, rhs: &NonZeroInt<LIMBS>) -> Self::Output {
        self.xgcd(rhs)
    }

    fn xgcd_vartime(&self, rhs: &NonZeroInt<LIMBS>) -> Self::Output {
        // TODO(#853): implement vartime
        self.xgcd(rhs)
    }
}

impl<const LIMBS: usize> Xgcd for OddInt<LIMBS> {
    type Output = OddIntXgcdOutput<LIMBS>;

    fn xgcd(&self, rhs: &OddInt<LIMBS>) -> Self::Output {
        self.xgcd(rhs.as_nz_ref())
    }

    fn xgcd_vartime(&self, rhs: &OddInt<LIMBS>) -> Self::Output {
        // TODO(#853): implement vartime
        self.xgcd(rhs.as_nz_ref())
    }
}

#[cfg(all(test, not(miri)))]
mod tests {
    use crate::int::gcd::{IntXgcdOutput, NonZeroIntXgcdOutput, OddIntXgcdOutput};
    use crate::{ConcatMixed, Gcd, Int, Uint};
    use num_traits::Zero;

    impl<const LIMBS: usize> From<NonZeroIntXgcdOutput<LIMBS>> for IntXgcdOutput<LIMBS> {
        fn from(value: NonZeroIntXgcdOutput<LIMBS>) -> Self {
            let NonZeroIntXgcdOutput {
                gcd,
                x,
                y,
                lhs_on_gcd,
                rhs_on_gcd,
            } = value;
            IntXgcdOutput {
                gcd: *gcd.as_ref(),
                x,
                y,
                lhs_on_gcd,
                rhs_on_gcd,
            }
        }
    }

    impl<const LIMBS: usize> From<OddIntXgcdOutput<LIMBS>> for IntXgcdOutput<LIMBS> {
        fn from(value: OddIntXgcdOutput<LIMBS>) -> Self {
            let OddIntXgcdOutput {
                gcd,
                x,
                y,
                lhs_on_gcd,
                rhs_on_gcd,
            } = value;
            IntXgcdOutput {
                gcd: *gcd.as_ref(),
                x,
                y,
                lhs_on_gcd,
                rhs_on_gcd,
            }
        }
    }

    mod gcd {

        use crate::{Gcd, I64, I128, I256, I512, I1024, I2048, I4096, Int, Uint};

        fn test<const LIMBS: usize>(lhs: Int<LIMBS>, rhs: Int<LIMBS>, target: Uint<LIMBS>) {
            assert_eq!(lhs.gcd(&rhs), target);
            assert_eq!(lhs.gcd_vartime(&rhs), target);
        }

        fn run_tests<const LIMBS: usize>() {
            let abs_min = *Int::MIN.as_uint();
            let max = *Int::MAX.as_uint();
            test(Int::<LIMBS>::MIN, Int::MIN, abs_min);
            test(Int::<LIMBS>::MIN, Int::MINUS_ONE, Uint::ONE);
            test(Int::<LIMBS>::MIN, Int::ZERO, abs_min);
            test(Int::<LIMBS>::MIN, Int::ONE, Uint::ONE);
            test(Int::<LIMBS>::MIN, Int::MAX, Uint::ONE);
            test(Int::<LIMBS>::MINUS_ONE, Int::MIN, Uint::ONE);
            test(Int::<LIMBS>::MINUS_ONE, Int::MINUS_ONE, Uint::ONE);
            test(Int::<LIMBS>::MINUS_ONE, Int::ZERO, Uint::ONE);
            test(Int::<LIMBS>::MINUS_ONE, Int::ONE, Uint::ONE);
            test(Int::<LIMBS>::MINUS_ONE, Int::MAX, Uint::ONE);
            test(Int::<LIMBS>::ZERO, Int::MIN, abs_min);
            test(Int::<LIMBS>::ZERO, Int::MINUS_ONE, Uint::ONE);
            test(Int::<LIMBS>::ZERO, Int::ZERO, Uint::ZERO);
            test(Int::<LIMBS>::ZERO, Int::ONE, Uint::ONE);
            test(Int::<LIMBS>::ZERO, Int::MAX, max);
            test(Int::<LIMBS>::ONE, Int::MIN, Uint::ONE);
            test(Int::<LIMBS>::ONE, Int::MINUS_ONE, Uint::ONE);
            test(Int::<LIMBS>::ONE, Int::ZERO, Uint::ONE);
            test(Int::<LIMBS>::ONE, Int::ONE, Uint::ONE);
            test(Int::<LIMBS>::ONE, Int::MAX, Uint::ONE);
            test(Int::<LIMBS>::MAX, Int::MIN, Uint::ONE);
            test(Int::<LIMBS>::MAX, Int::MINUS_ONE, Uint::ONE);
            test(Int::<LIMBS>::MAX, Int::ZERO, max);
            test(Int::<LIMBS>::MAX, Int::ONE, Uint::ONE);
            test(Int::<LIMBS>::MAX, Int::MAX, max);
        }

        #[test]
        fn gcd_sizes() {
            run_tests::<{ I64::LIMBS }>();
            run_tests::<{ I128::LIMBS }>();
            run_tests::<{ I256::LIMBS }>();
            run_tests::<{ I512::LIMBS }>();
            run_tests::<{ I1024::LIMBS }>();
            run_tests::<{ I2048::LIMBS }>();
            run_tests::<{ I4096::LIMBS }>();
        }
    }

    fn xgcd_test<const LIMBS: usize, const DOUBLE: usize>(
        lhs: Int<LIMBS>,
        rhs: Int<LIMBS>,
        output: IntXgcdOutput<LIMBS>,
    ) where
        Uint<LIMBS>: ConcatMixed<Uint<LIMBS>, MixedOutput = Uint<DOUBLE>>,
    {
        let gcd = lhs.gcd(&rhs);
        assert_eq!(gcd, output.gcd);

        // Test quotients
        let (lhs_on_gcd, rhs_on_gcd) = output.quotients();
        if gcd.is_zero() {
            assert_eq!(lhs_on_gcd, Int::ZERO);
            assert_eq!(rhs_on_gcd, Int::ZERO);
        } else {
            assert_eq!(lhs_on_gcd, lhs.div_uint(&gcd.to_nz().unwrap()));
            assert_eq!(rhs_on_gcd, rhs.div_uint(&gcd.to_nz().unwrap()));
        }

        // Test the Bezout coefficients on minimality
        let (x, y) = output.bezout_coefficients();
        assert!(x.abs() <= rhs_on_gcd.abs() || rhs_on_gcd.is_zero());
        assert!(y.abs() <= lhs_on_gcd.abs() || lhs_on_gcd.is_zero());
        if lhs.abs() != rhs.abs() {
            assert!(x.abs() <= rhs_on_gcd.abs().shr(1) || rhs_on_gcd.is_zero());
            assert!(y.abs() <= lhs_on_gcd.abs().shr(1) || lhs_on_gcd.is_zero());
        }

        // Test the Bezout coefficients for correctness
        assert_eq!(
            x.concatenating_mul(&lhs)
                .wrapping_add(&y.concatenating_mul(&rhs)),
            *gcd.resize().as_int()
        );
    }

    mod test_int_xgcd {
        use crate::int::gcd::tests::xgcd_test;
        use crate::{
            ConcatMixed, Gcd, Int, U64, U128, U192, U256, U384, U512, U768, U1024, U2048, U4096,
            U8192, Uint,
        };

        fn test<const LIMBS: usize, const DOUBLE: usize>(lhs: Int<LIMBS>, rhs: Int<LIMBS>)
        where
            Uint<LIMBS>: ConcatMixed<Uint<LIMBS>, MixedOutput = Uint<DOUBLE>>,
            Int<LIMBS>: Gcd<Output = Uint<LIMBS>>,
        {
            xgcd_test(lhs, rhs, lhs.xgcd(&rhs))
        }

        fn run_tests<const LIMBS: usize, const DOUBLE: usize>()
        where
            Uint<LIMBS>: ConcatMixed<Uint<LIMBS>, MixedOutput = Uint<DOUBLE>>,
            Int<LIMBS>: Gcd<Output = Uint<LIMBS>>,
        {
            test(Int::MIN, Int::MIN);
            test(Int::MIN, Int::MINUS_ONE);
            test(Int::MIN, Int::ZERO);
            test(Int::MIN, Int::ONE);
            test(Int::MIN, Int::MAX);
            test(Int::ONE, Int::MIN);
            test(Int::ONE, Int::MINUS_ONE);
            test(Int::ONE, Int::ZERO);
            test(Int::ONE, Int::ONE);
            test(Int::ONE, Int::MAX);
            test(Int::ZERO, Int::MIN);
            test(Int::ZERO, Int::MINUS_ONE);
            test(Int::ZERO, Int::ZERO);
            test(Int::ZERO, Int::ONE);
            test(Int::ZERO, Int::MAX);
            test(Int::ONE, Int::MIN);
            test(Int::ONE, Int::MINUS_ONE);
            test(Int::ONE, Int::ZERO);
            test(Int::ONE, Int::ONE);
            test(Int::ONE, Int::MAX);
            test(Int::MAX, Int::MIN);
            test(Int::MAX, Int::MINUS_ONE);
            test(Int::MAX, Int::ZERO);
            test(Int::MAX, Int::ONE);
            test(Int::MAX, Int::MAX);
        }

        #[test]
        fn xgcd_sizes() {
            run_tests::<{ U64::LIMBS }, { U128::LIMBS }>();
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

    mod test_nonzero_int_xgcd {
        use crate::int::gcd::tests::xgcd_test;
        use crate::{
            ConcatMixed, Int, U64, U128, U192, U256, U384, U512, U768, U1024, U2048, U4096, U8192,
            Uint,
        };

        fn test<const LIMBS: usize, const DOUBLE: usize>(lhs: Int<LIMBS>, rhs: Int<LIMBS>)
        where
            Uint<LIMBS>: ConcatMixed<Uint<LIMBS>, MixedOutput = Uint<DOUBLE>>,
        {
            let output = lhs.to_nz().unwrap().xgcd(&rhs.to_nz().unwrap());
            xgcd_test(lhs, rhs, output.into());
        }

        fn run_tests<const LIMBS: usize, const DOUBLE: usize>()
        where
            Uint<LIMBS>: ConcatMixed<Uint<LIMBS>, MixedOutput = Uint<DOUBLE>>,
        {
            test(Int::MIN, Int::MIN);
            test(Int::MIN, Int::MINUS_ONE);
            test(Int::MIN, Int::ONE);
            test(Int::MIN, Int::MAX);
            test(Int::MINUS_ONE, Int::MIN);
            test(Int::MINUS_ONE, Int::MINUS_ONE);
            test(Int::MINUS_ONE, Int::ONE);
            test(Int::MINUS_ONE, Int::MAX);
            test(Int::ONE, Int::MIN);
            test(Int::ONE, Int::MINUS_ONE);
            test(Int::ONE, Int::ONE);
            test(Int::ONE, Int::MAX);
            test(Int::MAX, Int::MIN);
            test(Int::MAX, Int::MINUS_ONE);
            test(Int::MAX, Int::ONE);
            test(Int::MAX, Int::MAX);
        }

        #[test]
        fn binxgcd() {
            run_tests::<{ U64::LIMBS }, { U128::LIMBS }>();
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

    mod test_odd_int_xgcd {
        use crate::int::gcd::tests::xgcd_test;
        use crate::{
            ConcatMixed, Int, U64, U128, U192, U256, U384, U512, U768, U1024, U2048, U4096, U8192,
            Uint,
        };

        fn test<const LIMBS: usize, const DOUBLE: usize>(lhs: Int<LIMBS>, rhs: Int<LIMBS>)
        where
            Uint<LIMBS>: ConcatMixed<Uint<LIMBS>, MixedOutput = Uint<DOUBLE>>,
        {
            let output = lhs.to_odd().unwrap().xgcd(&rhs.to_nz().unwrap());
            xgcd_test(lhs, rhs, output.into());
        }

        fn run_tests<const LIMBS: usize, const DOUBLE: usize>()
        where
            Uint<LIMBS>: ConcatMixed<Uint<LIMBS>, MixedOutput = Uint<DOUBLE>>,
        {
            let neg_max = Int::MAX.wrapping_neg();
            test(neg_max, neg_max);
            test(neg_max, Int::MINUS_ONE);
            test(neg_max, Int::ONE);
            test(neg_max, Int::MAX);
            test(Int::ONE, neg_max);
            test(Int::ONE, Int::MINUS_ONE);
            test(Int::ONE, Int::ONE);
            test(Int::ONE, Int::MAX);
            test(Int::MAX, neg_max);
            test(Int::MAX, Int::MINUS_ONE);
            test(Int::MAX, Int::ONE);
            test(Int::MAX, Int::MAX);
        }

        #[test]
        fn binxgcd() {
            run_tests::<{ U64::LIMBS }, { U128::LIMBS }>();
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

    mod traits {
        use crate::{Gcd, I256, U256};

        #[test]
        fn gcd_always_positive() {
            // Two numbers with a shared factor of 61
            let f = I256::from(59i32 * 61);
            let g = I256::from(61i32 * 71);

            assert_eq!(U256::from(61u32), f.gcd(&g));
            assert_eq!(U256::from(61u32), f.wrapping_neg().gcd(&g));
            assert_eq!(U256::from(61u32), f.gcd(&g.wrapping_neg()));
            assert_eq!(U256::from(61u32), f.wrapping_neg().gcd(&g.wrapping_neg()));
        }

        #[test]
        fn gcd_int_uint() {
            // Two numbers with a shared factor of 61
            let f = I256::from(59i32 * 61);
            let g = U256::from(61u32 * 71);

            assert_eq!(U256::from(61u32), f.gcd(&g));
            assert_eq!(U256::from(61u32), f.wrapping_neg().gcd(&g));
        }
    }
}
