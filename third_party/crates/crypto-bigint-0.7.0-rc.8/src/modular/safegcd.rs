//! Implementation of Bernstein-Yang modular inversion and GCD algorithm (a.k.a. safegcd)
//! as described in: <https://eprint.iacr.org/2019/266>.
//!
//! Adapted from the Apache 2.0+MIT licensed implementation originally from:
//! <https://github.com/taikoxyz/halo2curves/pull/2>
//! <https://github.com/privacy-scaling-explorations/halo2curves/pull/83>
//!
//! Copyright (c) 2023 Privacy Scaling Explorations Team

// TODO(tarcieri): optimized implementation for 32-bit platforms (#380)

#[cfg(feature = "alloc")]
pub(crate) mod boxed;

use core::fmt;

use crate::{ConstChoice, ConstCtOption, I64, Int, Limb, Odd, U64, Uint, const_choice::u32_min};

const GCD_BATCH_SIZE: u32 = 62;

/// Modular multiplicative inverter based on the Bernstein-Yang method.
///
/// The inverter can be created for a specified modulus M and adjusting parameter A to compute
/// the adjusted multiplicative inverses of positive integers, i.e. for computing
/// (1 / x) * A (mod M) for a positive integer x.
///
/// The adjusting parameter allows computing the multiplicative inverses in the case of using the
/// Montgomery representation for the input or the expected output. If R is the Montgomery
/// factor, the multiplicative inverses in the appropriate representation can be computed
/// provided that the value of A is chosen as follows:
/// - A = 1, if both the input and the expected output are in the standard form
/// - A = R^2 mod M, if both the input and the expected output are in the Montgomery form
/// - A = R mod M, if either the input or the expected output is in the Montgomery form,
///   but not both of them
///
/// The public methods of this type receive and return unsigned big integers as arrays of 64-bit
/// chunks, the ordering of which is little-endian. Both the modulus and the integer to be
/// inverted should not exceed 2 ^ (62 * L - 64).
///
/// For better understanding the implementation, the following resources are recommended:
/// - D. Bernstein, B.-Y. Yang, "Fast constant-time gcd computation and modular inversion",
///   <https://gcd.cr.yp.to/safegcd-20190413.pdf>
/// - P. Wuille, "The safegcd implementation in libsecp256k1 explained",
///   <https://github.com/bitcoin-core/secp256k1/blob/master/doc/safegcd_implementation.md>
#[derive(Clone, Debug)]
pub(crate) struct SafeGcdInverter<const LIMBS: usize> {
    /// Modulus
    pub(super) modulus: Odd<Uint<LIMBS>>,

    /// Multiplicative inverse of the modulus modulo 2^62
    inverse: u64,

    /// Adjusting parameter (see toplevel documentation).
    adjuster: Uint<LIMBS>,
}

/// Type of the Bernstein-Yang transition matrix multiplied by 2^62
type Matrix = [[i64; 2]; 2];

impl<const LIMBS: usize> SafeGcdInverter<LIMBS> {
    /// Creates the inverter for specified modulus and adjusting parameter.
    #[cfg(test)]
    pub(crate) const fn new(modulus: &Odd<Uint<LIMBS>>, adjuster: &Uint<LIMBS>) -> Self {
        Self::new_with_inverse(
            modulus,
            U64::from_u64(modulus.as_uint_ref().invert_mod_u64()),
            adjuster,
        )
    }

    #[inline]
    pub(crate) const fn new_with_inverse(
        modulus: &Odd<Uint<LIMBS>>,
        inverse: U64,
        adjuster: &Uint<LIMBS>,
    ) -> Self {
        Self {
            modulus: *modulus,
            inverse: inverse.as_uint_ref().lowest_u64(),
            adjuster: *adjuster,
        }
    }

    /// Returns either the adjusted modular multiplicative inverse for the argument or `None`
    /// depending on invertibility of the argument, i.e. its coprimality with the modulus.
    pub const fn invert(&self, value: &Uint<LIMBS>) -> ConstCtOption<Uint<LIMBS>> {
        invert_odd_mod_precomp::<LIMBS, false>(value, &self.modulus, self.inverse, &self.adjuster)
    }

    /// Returns either the adjusted modular multiplicative inverse for the argument or `None`
    /// depending on invertibility of the argument, i.e. its coprimality with the modulus.
    ///
    /// This version is variable-time with respect to `value`.
    pub const fn invert_vartime(&self, value: &Uint<LIMBS>) -> ConstCtOption<Uint<LIMBS>> {
        invert_odd_mod_precomp::<LIMBS, true>(value, &self.modulus, self.inverse, &self.adjuster)
    }
}

#[inline]
pub const fn invert_odd_mod<const LIMBS: usize, const VARTIME: bool>(
    a: &Uint<LIMBS>,
    m: &Odd<Uint<LIMBS>>,
) -> ConstCtOption<Uint<LIMBS>> {
    let mi = m.as_uint_ref().invert_mod_u64();
    invert_odd_mod_precomp::<LIMBS, VARTIME>(a, m, mi, &Uint::ONE)
}

/// Calculate the multiplicative inverse of `a` modulo `m`.
const fn invert_odd_mod_precomp<const LIMBS: usize, const VARTIME: bool>(
    a: &Uint<LIMBS>,
    m: &Odd<Uint<LIMBS>>,
    mi: u64,
    e: &Uint<LIMBS>,
) -> ConstCtOption<Uint<LIMBS>> {
    let a_nonzero = a.is_nonzero();
    let (mut f, mut g) = (SignedInt::from_uint(*m.as_ref()), SignedInt::from_uint(*a));
    let (mut d, mut e) = (SignedInt::<LIMBS>::ZERO, SignedInt::from_uint(*e));
    let mut steps = iterations(Uint::<LIMBS>::BITS);
    let mut delta = 1;
    let mut t;

    while steps > 0 {
        if VARTIME && g.is_zero_vartime() {
            break;
        }
        let batch = u32_min(steps, GCD_BATCH_SIZE);
        (delta, t) = jump::<VARTIME>(f.lowest(), g.lowest(), delta, batch);
        (f, g) = update_fg(&f, &g, t, batch);
        (d, e) = update_de(&d, &e, m.as_ref(), mi, t, batch);
        steps -= batch;
    }

    let d = d.norm(f.is_negative(), m.as_ref());
    ConstCtOption::new(d, Uint::eq(&f.magnitude, &Uint::ONE).and(a_nonzero))
}

/// Calculate the greatest common denominator of odd `f`, and `g`.
pub const fn gcd_odd<const LIMBS: usize, const VARTIME: bool>(
    f: &Odd<Uint<LIMBS>>,
    g: &Uint<LIMBS>,
) -> Odd<Uint<LIMBS>> {
    let (mut f, mut g) = (SignedInt::from_uint(*f.as_ref()), SignedInt::from_uint(*g));
    let mut steps = iterations(Uint::<LIMBS>::BITS);
    let mut delta = 1;
    let mut t;

    while steps > 0 {
        if VARTIME && g.is_zero_vartime() {
            break;
        }
        let batch = u32_min(steps, GCD_BATCH_SIZE);
        (delta, t) = jump::<VARTIME>(f.lowest(), g.lowest(), delta, batch);
        (f, g) = update_fg(&f, &g, t, batch);
        steps -= batch;
    }

    f.magnitude().to_odd().expect("odd by construction")
}

/// Perform `batch` steps of the gcd reduction process on signed tail values `f` and `g`.
#[inline]
const fn jump<const VARTIME: bool>(
    mut f: i64,
    mut g: i64,
    mut delta: i64,
    mut batch: u32,
) -> (i64, Matrix) {
    debug_assert!(f & 1 == 1, "f must be odd");
    let mut t = [[1i64, 0], [0, 1]];
    while batch > 0 {
        (f, g, delta, t) = if VARTIME {
            jump_step_vartime(f, g, delta, t)
        } else {
            jump_step(f, g, delta, t)
        };
        batch -= 1;
    }
    (delta, t)
}

/// Perform one step of the gcd reduction in constant time.
/// This follows the half-delta variant of safegcd-bounds which reduces the round count.
/// https://github.com/sipa/safegcd-bounds
#[inline(always)]
const fn jump_step(
    mut f: i64,
    mut g: i64,
    mut delta: i64,
    mut t: Matrix,
) -> (i64, i64, i64, Matrix) {
    let d_gtz = ConstChoice::from_u64_nonzero((delta & !(delta >> 63)) as u64);
    let g_odd = ConstChoice::from_u64_lsb((g & 1) as u64);
    let g_adj = g_odd.select_i64(0, f);
    let swap = d_gtz.and(g_odd);
    delta = swap.select_i64(2i64.wrapping_add(delta), 2i64.wrapping_sub(delta));
    f = swap.select_i64(f, g);
    g = swap.select_i64(g.wrapping_add(g_adj), g.wrapping_sub(g_adj)) >> 1;
    t = [
        [
            swap.select_i64(t[0][0], t[1][0]) << 1,
            swap.select_i64(t[0][1], t[1][1]) << 1,
        ],
        [
            t[1][0].wrapping_add(g_odd.select_i64(0, d_gtz.select_i64(t[0][0], -t[0][0]))),
            t[1][1].wrapping_add(g_odd.select_i64(0, d_gtz.select_i64(t[0][1], -t[0][1]))),
        ],
    ];
    (f, g, delta, t)
}

/// Perform one step of the gcd reduction in variable time.
#[inline(always)]
const fn jump_step_vartime(
    mut f: i64,
    mut g: i64,
    mut delta: i64,
    mut t: Matrix,
) -> (i64, i64, i64, Matrix) {
    if (g & 1) != 0 {
        (f, g, delta, t) = if delta > 0 {
            (
                g,
                g.wrapping_sub(f),
                2i64.wrapping_sub(delta),
                [
                    t[1],
                    [t[1][0].wrapping_sub(t[0][0]), t[1][1].wrapping_sub(t[0][1])],
                ],
            )
        } else {
            (
                f,
                g.wrapping_add(f),
                2i64.wrapping_add(delta),
                [
                    t[0],
                    [t[1][0].wrapping_add(t[0][0]), t[1][1].wrapping_add(t[0][1])],
                ],
            )
        };
    } else {
        delta = 2i64.wrapping_add(delta);
    }
    g >>= 1;
    t[0][0] <<= 1;
    t[0][1] <<= 1;
    (f, g, delta, t)
}

#[inline]
const fn update_fg<const LIMBS: usize>(
    a: &SignedInt<LIMBS>,
    b: &SignedInt<LIMBS>,
    t: Matrix,
    shift: u32,
) -> (SignedInt<LIMBS>, SignedInt<LIMBS>) {
    (
        SignedInt::lincomb_int_reduce_shift(
            a,
            b,
            &I64::from_i64(t[0][0]),
            &I64::from_i64(t[0][1]),
            shift,
        ),
        SignedInt::lincomb_int_reduce_shift(
            a,
            b,
            &I64::from_i64(t[1][0]),
            &I64::from_i64(t[1][1]),
            shift,
        ),
    )
}

#[inline]
const fn update_de<const LIMBS: usize>(
    d: &SignedInt<LIMBS>,
    e: &SignedInt<LIMBS>,
    m: &Uint<LIMBS>,
    mi: u64,
    t: Matrix,
    shift: u32,
) -> (SignedInt<LIMBS>, SignedInt<LIMBS>) {
    (
        SignedInt::lincomb_int_reduce_shift_mod(
            d,
            e,
            &Int::from_i64(t[0][0]),
            &Int::from_i64(t[0][1]),
            shift,
            m,
            U64::from_u64(mi),
        ),
        SignedInt::lincomb_int_reduce_shift_mod(
            d,
            e,
            &Int::from_i64(t[1][0]),
            &Int::from_i64(t[1][1]),
            shift,
            m,
            U64::from_u64(mi),
        ),
    )
}

/// Conditionally negate a wide Uint represented by `(lo, hi)`.
#[inline]
const fn conditional_negate_in_place_wide<const L: usize, const H: usize>(
    lo: &mut Uint<L>,
    hi: &mut Uint<H>,
    flag: ConstChoice,
) {
    let (neg, carry) = lo.carrying_neg();
    let hi_neg = hi
        .not()
        .wrapping_add(&Uint::select(&Uint::ZERO, &Uint::ONE, carry));
    *lo = Uint::select(lo, &neg, flag);
    *hi = Uint::select(hi, &hi_neg, flag);
}

/// Right shift a wide Uint represented by `(lo, hi)` returning any remaining high bits.
#[inline]
const fn shr_in_place_wide<const L: usize, const H: usize>(
    lo: &mut Uint<L>,
    hi: &mut Uint<H>,
    shift: u32,
) {
    debug_assert!(H <= L);
    debug_assert!(shift < Uint::<H>::BITS);
    let copy = hi.shl_vartime(Uint::<H>::BITS - shift);
    *hi = hi.shr_vartime(shift);
    *lo = lo.shr_vartime(shift);
    let mut offs = shift.div_ceil(Limb::BITS) as usize;
    lo.limbs[L - offs] = lo.limbs[L - offs].bitor(copy.limbs[H - offs]);
    loop {
        offs -= 1;
        if offs == 0 {
            break;
        }
        lo.limbs[L - offs] = copy.limbs[H - offs];
    }
}

/// Calculate the maximum number of iterations required according to
/// safegcd-bounds: https://github.com/sipa/safegcd-bounds
#[inline]
const fn iterations(bits: u32) -> u32 {
    (45907 * bits + 30179) / 19929
}

/// A `Uint` which carries a separate sign in order to maintain the same range.
#[derive(Clone, Copy)]
struct SignedInt<const LIMBS: usize> {
    sign: ConstChoice,
    magnitude: Uint<LIMBS>,
}

impl<const LIMBS: usize> SignedInt<LIMBS> {
    pub const ZERO: Self = Self::from_uint(Uint::ZERO);

    /// Construct a new `SignedInt` from a `Uint`.
    pub const fn from_uint(uint: Uint<LIMBS>) -> Self {
        Self {
            sign: ConstChoice::FALSE,
            magnitude: uint,
        }
    }

    /// Construct a new `SignedInt` from a `Uint` and a sign flag.
    pub const fn from_uint_sign(magnitude: Uint<LIMBS>, sign: ConstChoice) -> Self {
        Self { sign, magnitude }
    }

    /// Obtain the magnitude of the `SignedInt`, ie. its absolute value.
    pub const fn magnitude(&self) -> Uint<LIMBS> {
        self.magnitude
    }

    /// Determine if the `SignedInt` is non-zero.
    pub const fn is_nonzero(&self) -> ConstChoice {
        self.magnitude.is_nonzero()
    }

    /// Determine if the `SignedInt` is zero in variable time.
    pub const fn is_zero_vartime(&self) -> bool {
        self.magnitude.is_zero_vartime()
    }

    /// Determine if the `SignedInt` is negative.
    /// Note: `-0` is representable in this type, so it may be necessary
    /// to check `self.is_nonzero()` as well.
    pub const fn is_negative(&self) -> ConstChoice {
        self.sign
    }

    // Extract the lowest 63 bits and convert to its signed representation.
    pub const fn lowest(&self) -> i64 {
        let mag = (self.magnitude.as_uint_ref().lowest_u64() & (u64::MAX >> 1)) as i64;
        self.sign.select_i64(mag, mag.wrapping_neg())
    }

    /// Compute the linear combination `a•b + c•d`, returning `(lo, hi, sign)`.
    #[inline]
    pub(crate) const fn lincomb_int<const RHS: usize>(
        a: &SignedInt<LIMBS>,
        b: &SignedInt<LIMBS>,
        c: &Int<RHS>,
        d: &Int<RHS>,
    ) -> (Uint<LIMBS>, Uint<RHS>, ConstChoice) {
        let (c, c_sign) = c.abs_sign();
        let (d, d_sign) = d.abs_sign();
        // Each SignedInt • abs(Int) product leaves an empty upper bit.
        let (mut x, mut x_hi) = a.magnitude.widening_mul(&c);
        let x_neg = a.sign.xor(c_sign);
        let (mut y, mut y_hi) = b.magnitude.widening_mul(&d);
        let y_neg = b.sign.xor(d_sign);
        let odd_neg = x_neg.xor(y_neg);

        // Negate y if none or both of the multiplication results are negative.
        conditional_negate_in_place_wide(&mut y, &mut y_hi, odd_neg.not());

        let mut borrow;
        (x, borrow) = x.borrowing_sub(&y, Limb::ZERO);
        (x_hi, borrow) = x_hi.borrowing_sub(&y_hi, borrow);
        let swap = borrow.is_nonzero().and(odd_neg);

        // Negate the result if we did not negate y and there was a borrow,
        // indicating that |y| > |x|.
        conditional_negate_in_place_wide(&mut x, &mut x_hi, swap);

        let sign = x_neg.and(swap.not()).or(y_neg.and(swap));
        (x, x_hi, sign)
    }

    /// Compute the linear combination `a•b + c•d`, and shift the result
    /// `shift` bits to the right, returning a signed value in the same range
    /// as the `SignedInt` inputs.
    pub(crate) const fn lincomb_int_reduce_shift<const S: usize>(
        a: &Self,
        b: &Self,
        c: &Int<S>,
        d: &Int<S>,
        shift: u32,
    ) -> Self {
        debug_assert!(shift < Uint::<S>::BITS);
        let (mut a, mut a_hi, a_sign) = Self::lincomb_int(a, b, c, d);
        shr_in_place_wide(&mut a, &mut a_hi, shift);
        SignedInt::from_uint_sign(a, a_sign)
    }

    /// Compute the linear combination `a•b + c•d`, and shift the result
    /// `shift` bits to the right modulo `m`, returning a signed value in the
    /// same range as the `SignedInt` inputs.
    pub(crate) const fn lincomb_int_reduce_shift_mod<const S: usize>(
        a: &Self,
        b: &Self,
        c: &Int<S>,
        d: &Int<S>,
        shift: u32,
        m: &Uint<LIMBS>,
        mi: Uint<S>,
    ) -> SignedInt<LIMBS> {
        debug_assert!(shift < Uint::<S>::BITS);
        let (mut x, mut x_hi, mut x_sign) = SignedInt::lincomb_int(a, b, c, d);

        // Compute the multiple of m that will clear the low N bits of (x, x_hi).
        let mut mf = x.resize::<S>().wrapping_mul(&mi);
        mf = mf.bitand(&Uint::MAX.shr_vartime(Uint::<S>::BITS - shift));
        let (xa, xa_hi) = m.widening_mul(&mf);

        // Subtract the adjustment from (x, x_hi) potentially producing a borrow.
        let mut borrow;
        (x, borrow) = x.borrowing_sub(&xa, Limb::ZERO);
        (x_hi, borrow) = x_hi.borrowing_sub(&xa_hi, borrow);

        // Negate (x, x_hi) if the subtraction borrowed.
        let swap = borrow.is_nonzero();
        conditional_negate_in_place_wide(&mut x, &mut x_hi, swap);
        x_sign = x_sign.xor(swap);

        // Shift the result, eliminating the trailing zeros.
        shr_in_place_wide(&mut x, &mut x_hi, shift);
        debug_assert!(
            x_hi.shr1().is_nonzero().not().to_bool_vartime(),
            "overflow was larger than one bit"
        );

        // The magnitude x is now in the range [0, 2m). We conditionally subtract
        // m in order to keep the output in (-m, m).
        x = x.sub_mod_with_carry(x_hi.limbs[0], m, m);

        SignedInt::from_uint_sign(x, x_sign)
    }

    /// Normalize the value to a `Uint` in the range `[0, m)`.
    const fn norm(&self, f_sign: ConstChoice, m: &Uint<LIMBS>) -> Uint<LIMBS> {
        let swap = f_sign.xor(self.sign).and(self.is_nonzero());
        Uint::select(&self.magnitude, &m.wrapping_sub(&self.magnitude), swap)
    }

    /// Compare two `SignedInt` in constant time.
    pub const fn eq(a: &Self, b: &Self) -> ConstChoice {
        Uint::eq(&a.magnitude, &b.magnitude).and(a.sign.eq(b.sign).or(a.is_nonzero().not()))
    }
}

impl<const LIMBS: usize> fmt::Debug for SignedInt<LIMBS> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_fmt(format_args!(
            "{}0x{}",
            if self.sign.is_true_vartime() {
                "-"
            } else {
                "+"
            },
            &self.magnitude
        ))
    }
}

impl<const LIMBS: usize> PartialEq for SignedInt<LIMBS> {
    fn eq(&self, other: &Self) -> bool {
        Self::eq(self, other).to_bool_vartime()
    }
}

impl<const LIMBS: usize> ConstCtOption<Odd<SignedInt<LIMBS>>> {
    /// Returns the contained value, consuming the `self` value.
    ///
    /// # Panics
    ///
    /// Panics if the value is none with a custom panic message provided by
    /// `msg`.
    #[inline]
    #[track_caller]
    pub const fn expect(self, msg: &str) -> Odd<SignedInt<LIMBS>> {
        assert!(self.is_some().is_true_vartime(), "{}", msg);
        *self.components_ref().0
    }
}

#[cfg(test)]
mod tests {
    use super::SafeGcdInverter;
    use crate::{U128, U256, modular::safegcd::shr_in_place_wide};

    #[test]
    fn invert() {
        let g =
            U256::from_be_hex("00000000CBF9350842F498CE441FC2DC23C7BF47D3DE91C327B2157C5E4EED77");
        let modulus =
            U256::from_be_hex("FFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551")
                .to_odd()
                .unwrap();
        let inverter = SafeGcdInverter::new(&modulus, &U256::ONE);
        let result = inverter.invert(&g).unwrap();
        assert_eq!(
            U256::from_be_hex("FB668F8F509790BC549B077098918604283D42901C92981062EB48BC723F617B"),
            result
        );
    }

    #[test]
    fn shr_wide() {
        let hi = U128::from_u128(0x11111111222222223333333344444444);
        let lo = U256::MAX;
        let (mut a, mut a_hi) = (lo, hi);
        shr_in_place_wide(&mut a, &mut a_hi, 16);
        assert_eq!(
            a,
            U256::from_be_hex("4444FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF")
        );
        assert_eq!(a_hi, U128::from_u128(0x1111111122222222333333334444));
        let (mut b, mut b_hi) = (lo, hi);
        shr_in_place_wide(&mut b, &mut b_hi, 68);
        assert_eq!(
            b,
            U256::from_be_hex("23333333344444444FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF")
        );
        assert_eq!(b_hi, U128::from_u128(0x111111112222222));
    }
}
