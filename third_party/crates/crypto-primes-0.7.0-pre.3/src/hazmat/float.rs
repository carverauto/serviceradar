//! Const-context floating point functions that are currently not present in `core`.

use core::f64;
use crypto_bigint::Uint;

/// Calculates `base^exp`.
const fn pow(mut base: f64, mut exp: u32) -> f64 {
    let mut result = 1.;
    while exp > 0 {
        if exp & 1 == 1 {
            result *= base;
        }
        base *= base;
        exp >>= 1;
    }
    result
}

/// Calculates `2^exp`.
pub(crate) const fn two_powi(exp: u32) -> f64 {
    pow(2f64, exp.abs_diff(0))
}

/// Calculates `floor(x)`.
// Taken from `libm` crate.
const fn floor(x: f64) -> f64 {
    const TOINT: f64 = 1. / f64::EPSILON;

    let ui = x.to_bits();
    let e = ((ui >> 52) & 0x7ff) as i32;

    if (e >= 0x3ff + 52) || (x == 0.) {
        return x;
    }
    /* y = int(x) - x, where int(x) is an integer neighbor of x */
    let y = if (ui >> 63) != 0 {
        x - TOINT + TOINT - x
    } else {
        x + TOINT - TOINT - x
    };
    /* special case because of non-nearest rounding modes */
    if e < 0x3ff {
        return if (ui >> 63) != 0 { -1. } else { 0. };
    }
    if y > 0. { x + y - 1. } else { x + y }
}

/// Calculates a lower bound approximation of `2^exp` where `0 <= exp <= 1`.
const fn two_powf_normalized_lower_bound(exp: f64) -> f64 {
    debug_assert!(exp >= 0.);
    debug_assert!(exp <= 1.);

    // Use the first four terms of the Taylor expansion to calculate `2^exp`.
    // The error is under 2%.
    //
    // Since it is a monotonous function, `res <= 2^exp`.

    let exp_2 = exp * exp;
    let exp_3 = exp_2 * exp;

    // The coefficients are `ln(2)^n / n!`, where `n` is the power of the corresponding term.
    const LN_2: f64 = f64::consts::LN_2;
    const C1: f64 = LN_2;
    const C2: f64 = LN_2 * LN_2 / 2.;
    const C3: f64 = LN_2 * LN_2 * LN_2 / 6.;

    1. + C1 * exp + C2 * exp_2 + C3 * exp_3
}

/// Calculates an approximation of `2^exp` where `exp < 0`.
/// The approximation is guaranteed to always be greater than `2^exp`.
pub(crate) const fn two_powf_upper_bound(exp: f64) -> f64 {
    debug_assert!(exp < 0.);

    let positive_exp = -exp;

    let int_part = floor(positive_exp);
    let frac_part = positive_exp - int_part;

    let int_res = two_powi(int_part as u32);
    let frac_res = two_powf_normalized_lower_bound(frac_part);

    // `int_res * frac_res <= 2^(int_part + frac_part)`,
    // so when we invert it, we get the upper bound approximation instead.
    1. / (int_res * frac_res)
}

/// Calculates `floor(sqrt(x))`.
pub(crate) const fn floor_sqrt(x: u32) -> u32 {
    if x < 2 {
        return x;
    }

    // Initialize the binary search bounds.
    let mut low = 1;
    let mut high = x / 2;

    while low <= high {
        let mid = (low + high) / 2;
        let mid_squared = mid * mid;

        // Check if `mid` is the floor of the square root of `x`.
        if mid_squared <= x && (mid + 1) * (mid + 1) > x {
            break;
        } else if mid_squared < x {
            low = mid + 1;
        } else {
            high = mid - 1
        }
    }

    (low + high) / 2
}

// Calculate the natural logarithm of a big integer using the relation ln(x) = log₂(x) / log₂(e).
// Uses fixed-point arithmetic for large values of x (> 2^53).
pub(crate) fn ln<const LIMBS: usize>(x: &Uint<LIMBS>) -> f64 {
    if x <= &Uint::ONE {
        return 0.0;
    }
    let ilog2_x = x.bits_vartime().saturating_sub(1);
    // if x is small enough to be cast losslessly to an f64 we use the normal 64-bit log2() from `libm`.
    if ilog2_x < f64::MANTISSA_DIGITS {
        let x = {
            #[cfg(target_pointer_width = "64")]
            {
                x.as_limbs()[0].0
            }
            #[cfg(target_pointer_width = "32")]
            {
                // Small enough to fit in 32 bits
                if ilog2_x < 32 {
                    x.as_limbs()[0].0 as u64
                } else {
                    let lo = x.as_limbs()[0].0;
                    let hi = x.as_limbs()[1].0;
                    (hi as u64) << 32 | lo as u64
                }
            }
        };
        return libm::log2(x as f64) * f64::consts::LN_2;
    }
    // x can be approximated by M*2^shift, where shift is `ilog2(x) - 52` and M is the integer value represented by the
    // top 53 bits of x.
    // log2(x) ~ log2(M*2^shift) ~ log2(M) + shift ~ log2(M) + ilog2(x) - 52
    let shift = ilog2_x.saturating_sub(f64::MANTISSA_DIGITS - 1);
    let shifted_x = x.wrapping_shr_vartime(shift);
    #[cfg(target_pointer_width = "64")]
    let fraction = shifted_x.as_limbs()[0].0 as f64;
    #[cfg(target_pointer_width = "32")]
    let fraction = {
        let lo = shifted_x.as_limbs()[0].0;
        let hi = shifted_x.as_limbs()[1].0;
        let fraction = (hi as u64) << 32 | lo as u64;
        fraction as f64
    };

    // Fraction is now m * 2^52, where m is the top 53 bits of x. Take log2(m) and subtract 52 to scale the result back
    // to the expected range.
    let fraction = libm::log2(fraction) - (f64::MANTISSA_DIGITS - 1) as f64;
    let log2_x = ilog2_x as f64 + fraction;
    log2_x * f64::consts::LN_2
}

#[cfg(test)]
mod tests {
    use alloc::vec;
    use alloc::vec::Vec;

    use crypto_bigint::{U128, U256, U512, U1024};
    use float_cmp::assert_approx_eq;
    use proptest::prelude::*;

    use super::{floor, floor_sqrt, ln, pow, two_powf_normalized_lower_bound};

    #[test]
    fn sqrt_corner_cases() {
        assert_eq!(floor_sqrt(0), 0);
        assert_eq!(floor_sqrt(1), 1);
        assert_eq!(floor_sqrt(2), 1);
    }

    proptest! {
        #[test]
        fn fuzzy_pow(base in 0..100u32, exp in 0..30u32) {
            let base_f = base as f64 / 100.;
            let test = pow(base_f, exp);
            let reference = base_f.powf(exp as f64);
            assert_approx_eq!(f64, test, reference, ulps = 20);
        }

        #[test]
        fn fuzzy_floor(x in proptest::num::f64::NORMAL) {
            let test = floor(x);
            let reference = x.floor();
            assert_approx_eq!(f64, test, reference);
        }

        #[test]
        fn fuzzy_two_powf_upper_bound(exp in 0..1000) {
            let exp_f = exp as f64 / 1000.;
            let test = two_powf_normalized_lower_bound(exp_f);
            let reference = 2f64.powf(exp_f);
            assert!(test <= reference);
            assert!((reference - test) / reference <= 0.02);
        }

        #[test]
        fn fuzzy_floor_sqrt(x in 0..100000u32) {
            let x_f = x as f64;
            let test = floor_sqrt(x);
            let reference = x_f.sqrt().floor() as u32;
            assert_eq!(test, reference);
        }
    }

    #[test]
    fn test_ln_x_small() {
        let test_cases: Vec<(u128, f64)> = vec![
            (1, 0.0),
            (3, 1.09861228866811),
            (4, 1.3862943611198906),
            (5, 1.6094379124341004),
            (10u128.pow(2), 4.60517018598809),
            (10u128.pow(3), 6.90775527898214),
            (10u128.pow(4), 9.21034037197618),
            (10u128.pow(5), 11.51292546497023),
            (10u128.pow(6), 13.81551055796427),
            (10u128.pow(7), 16.11809565095832),
            (10u128.pow(8), 18.42068074395237),
            (10u128.pow(9), 20.72326583694641),
            (10u128.pow(10), 23.02585092994046),
            (10u128.pow(11), 25.3284360229345),
            (10u128.pow(12), 27.63102111592855),
            (10u128.pow(13), 29.93360620892259),
            (10u128.pow(14), 32.23619130191664),
            (10u128.pow(15), 34.53877639491069),
            (10u128.pow(16), 36.84136148790473),
            (10u128.pow(17), 39.14394658089878),
            (10u128.pow(18), 41.44653167389282),
            (10u128.pow(19), 43.74911676688687),
            (10u128.pow(20), 46.05170185988091),
            (10u128.pow(21), 48.35428695287496),
            (10u128.pow(22), 50.65687204586901),
            (10u128.pow(23), 52.95945713886305),
            (10u128.pow(24), 55.262042231857096),
            (10u128.pow(25), 57.56462732485114),
            (10u128.pow(26), 59.86721241784519),
            (10u128.pow(27), 62.16979751083923),
            (10u128.pow(28), 64.47238260383328),
            (10u128.pow(29), 66.77496769682733),
            (10u128.pow(30), 69.07755278982137),
            (10u128.pow(31), 71.38013788281542),
            (10u128.pow(32), 73.68272297580946),
            (10u128.pow(33), 75.9853080688035),
            (10u128.pow(34), 78.28789316179756),
            (10u128.pow(35), 80.5904782547916),
            (10u128.pow(36), 82.89306334778564),
            (10u128.pow(37), 85.19564844077969),
            (10u128.pow(38), 87.49823353377374),
        ];
        for (x, expected) in test_cases.iter() {
            let x_big = U128::from_u128(*x);
            let result = ln(&x_big);
            assert!(
                (result - *expected).abs() < f64::EPSILON * 100.0,
                "x: {x}, mine: {result}, expected: {expected}"
            );
        }
    }

    #[test]
    fn test_ln_x_large() {
        // Random xs are from seed "01234567890123456789012345678901"/ChaCha8Rng
        let x = U256::from_be_hex("017AD59D33AC084D2E58D81F8BB87A61B44677037A7DBDE04814256570DCBD7A");
        let expected_256 = 172.29242258375361;

        let ln_x = ln(&x);
        assert!(
            (ln_x - expected_256).abs() < f64::EPSILON,
            "x: {x}, ln x: {ln_x}, expected: {expected_256}"
        );

        let x = U512::from_be_hex(concat![
            "890E108F1778E5523E3E89CCD5DEDB667E6C17E940E9D4C3F58575C86CB76403",
            "017AD59D33AC084D2E58D81F8BB87A61B44677037A7DBDE04814256570DCBD7A"
        ]);
        let expected_512 = 354.2665608707877;
        let ln_x = ln(&x);
        assert!(
            (ln_x - expected_512).abs() < f64::EPSILON,
            "x: {x}, ln x: {ln_x}, expected: {expected_512}"
        );

        let x = U1024::from_be_hex(concat![
            "62A211E0907141403FD3EB60A82EAB701524710BDB024EB68DFF309389258B63",
            "2EB9975D29F028F5137AC9DE870EB622D2D45A0D3A9C5801E8A3109BED220F82",
            "890E108F1778E5523E3E89CCD5DEDB667E6C17E940E9D4C3F58575C86CB76403",
            "017AD59D33AC084D2E58D81F8BB87A61B44677037A7DBDE04814256570DCBD7A"
        ]);

        let expected_1024 = 708.828942204781;
        let ln_x = ln(&x);
        assert!(
            (ln_x - expected_1024).abs() < f64::EPSILON,
            "x: {x}, ln x: {ln_x}, expected: {expected_1024}"
        );
    }
}
