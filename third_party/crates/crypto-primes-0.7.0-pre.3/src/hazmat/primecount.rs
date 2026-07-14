use crate::hazmat::float::ln;
use core::f64;
use crypto_bigint::{Concat, NonZero, Split, Uint};

/// Estimate the number of primes smaller than x using the asymptotic expansion of `Li(x)` with 4 terms, i.e.:
///
///   $$\pi(x) \approx \frac{x}{\ln x} \left(1 + \frac{1!}{\ln x} + \frac{2!}{\ln^2 x} + \frac{3!}{\ln^3 x}\right)$$
///
/// For values of x up to ~$10^{29}$, consider using precalculated values for $\pi(x)$ from
/// e.g. <https://sweet.ua.pt/tos/primes.html>.
///
/// # Error considerations
///
/// In addition to the usual floating point math limitations, there are two components to the error:
///
/// 1. The truncation error from using a limited number of terms (4) of the asymptotic expansion of Li(x): $|Li(x) -
///    Li_{approx}(x)|$
/// 2. The theoretical error, given by the absolute difference between $\pi(x)$ and Li(x): $|\pi(x) - Li(x)|$
///
/// ## Truncation Error
///
/// The size of the truncation error for the 4-term approximation $Li_{approx}(x)$ is roughly the size of the first
/// omitted term, which is $\frac{24x}{\ln^5 x}$.
///
/// | Bits | Truncation error (abs)     | Truncation error (rel) |
/// | :--- | :------------------------- | :----------------------|
/// | 1024 | $\approx 2^{981}$          | $\approx 2^{-33}$      |
/// | 2048 | $\approx 2^{2000}$         | $\approx 2^{-37}$      |
/// | 4096 | $\approx 2^{4043}$         | $\approx 2^{-41}$      |
///
/// *(Relative error is calculated as the first omitted term divided by $Li_{approx}(x)$)*
///
/// ## Theoretical Error
///
/// Assuming RH, we can use Schoenfeld’s bound $|\pi(x) - \text{Li}(x)| < \frac{\sqrt{x} \ln x}{8\pi}$.
/// This gives a very small theoretical error bound compared to the best known unconditional bounds[^Trudgian2014].
///
/// | Bits | Error Bound (abs) | Error Bound (rel) |
/// | :--- | :---------------- | :-----------------|
/// | 1024 | < $2^{517}$       | < $2^{-497}$      |
/// | 2048 | < $2^{1030}$      | < $2^{-1007}$     |
/// | 4096 | < $2^{2055}$      | < $2^{-2029}$     |
///
/// *(Relative error bound is calculated as Schoenfeld’s Bound (abs) divided by $Li_{approx}(x)$)*
///
/// ## Discussion
///
/// Assuming RH, the dominant error term in estimating $\pi(x)$ with $Li_{approx}(x)$ comes from truncating the asymptotic
/// expansion of Li(x). While this truncation error is extremely small in relative terms, it is large in absolute terms.
/// Improving the Li(x) approximation to be the same order of magnitude as the Schoenfeld bound would require using
/// hundreds of terms from the asymptotic series (or employing more complex methods like continued fractions for the
/// remainder, which is beyond the scope of this simple approximation). In relative terms the error bound is
/// approximately $2^{-33}$ (for 1024 bits) down to $\sim 2^{-41}$ (for 4096 bits). This corresponds to an extremely small
/// percentage error (significantly less than $10^{-8}$ %).
///
/// It should be noted that while Li(x) is generally smaller than $\pi(x)$ for 'small' x, it is known that the sign of
/// $\pi(x) - Li(x)$ changes infinitely often. It has been proven that there must be a crossing below $\sim 10^{316}$
/// ($\sim 2^{1051}$), which is well within the ranges used in this library. Thus, users should be aware that the
/// estimate provided here can be both greater than and smaller than the actual value of $\pi(x)$.
///
/// [^Dusart2010]: P. Dusart, "Estimates of Some Functions Over Primes without R.H.",
///   [arXiv:1002.0442](https://arxiv.org/pdf/1002.0442) (2010)
///
/// [^Dusart2018]: P. Dusart, "Explicit estimates of some functions over primes",
///   The Ramanujan Journal 45(1) 227-251 (2018),
///   DOI: [10.1007/s11139-016-9839-4](https://link.springer.com/article/10.1007/s11139-016-9839-4)
///
/// [^Wikipedia-pcf]: <https://en.wikipedia.org/wiki/Prime-counting_function>
///
/// [^Schoenfeld1976]: L. Schoenfeld, "Sharper Bounds for the Chebyshev Functions θ(x) and ψ(x). II",
///   Math. Comp. 30(134) 337-360 (1976),
///   DOI: [10.2307/2005976](https://www.jstor.org/stable/2005976)
///
/// [^Trudgian2014]: T. Trudgian, "Updating the error term in the prime number theorem",
///   [arXiv:1401.2689](https://arxiv.org/abs/1401.2689) (2014)
pub fn estimate_primecount<const LIMBS: usize, const RHS_LIMBS: usize>(x: &Uint<LIMBS>) -> Uint<LIMBS>
where
    Uint<LIMBS>: Concat<Output = Uint<RHS_LIMBS>>,
    Uint<RHS_LIMBS>: Split<Output = Uint<LIMBS>>,
{
    // Number of bits to scale by (fractional bits during division)
    // On 64 bit CPUs and x is a U64, we use 32 bits (1 limb * 32). Else 64.
    // On 32 bit CPUs and x is a U64, we use 32 bits (2 limb * 16). Else 64.
    #[cfg(target_pointer_width = "32")]
    let scale_bits = (LIMBS as u32 * 16).min(64);
    #[cfg(target_pointer_width = "64")]
    let scale_bits = (LIMBS as u32 * 32).min(64);
    let total_scale_bits = 2 * scale_bits;
    // Scaling factor for the denominators of the expansion terms, 2^64.
    let denom_scale_factor = (1u128 << scale_bits) as f64;

    let ln_x = ln(x);

    if !ln_x.is_finite() || ln_x <= 1.0 {
        return Uint::ZERO;
    }

    // Calculate f64 denominators L, L^2, L^3, L^4
    let ln_x_2 = ln_x * ln_x;
    let ln_x_3 = ln_x_2 * ln_x;
    let ln_x_4 = ln_x_3 * ln_x;

    // Scale up a float by 2^64, round, cast to u128 and then to a wide `Uint`.
    let f64_to_scaled_uint = |value: f64| -> NonZero<Uint<RHS_LIMBS>> {
        let scaled = value * denom_scale_factor;
        let scaled = libm::round(scaled).max(1.0) as u128;
        let denom = Uint::<RHS_LIMBS>::from_u128(scaled);
        NonZero::new(denom).expect("max(1.0) ensures value is at least 1")
    };

    let d1 = f64_to_scaled_uint(ln_x);
    let d2 = f64_to_scaled_uint(ln_x_2);
    let d3 = f64_to_scaled_uint(ln_x_3);
    let d4 = f64_to_scaled_uint(ln_x_4);

    let x_wide: Uint<RHS_LIMBS> = x.concat(&Uint::ZERO);
    let x_wide_scaled = x_wide.wrapping_shl_vartime(total_scale_bits);

    let term1_scaled = x_wide_scaled.wrapping_div(&d1);
    let term2_scaled = x_wide_scaled.wrapping_div(&d2);

    // Term 3: (2x << total_scale_bits) / d3  (Factorial 2!)
    let term3_scaled = x_wide_scaled.wrapping_shl_vartime(1).wrapping_div(&d3);

    // Term 4: (6x << total_scale_bits) / d4  (Factorial 3!)
    let six = Uint::<LIMBS>::from(6u64);
    let x_times_6 = x_wide_scaled.saturating_mul(&six);
    let term4_scaled = x_times_6.wrapping_div(&d4);

    let sum_scaled = term1_scaled
        .wrapping_add(&term2_scaled)
        .wrapping_add(&term3_scaled)
        .wrapping_add(&term4_scaled);

    // Descale by right-shifting
    let li_x = sum_scaled >> scale_bits;
    let (lo, hi) = li_x.split();
    assert_eq!(hi, Uint::ZERO, "De-scaling should leave the high half zero");
    lo
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloc::vec;
    use alloc::vec::Vec;
    use crypto_bigint::{U64, U128, U256, U1024};

    #[test]
    fn pi_x_2_500() {
        let x = Uint::ONE << 500;
        let sage_est = U1024::from_be_hex(concat![
            "0000000000000000000000000000000000000000000000000000000000000000",
            "0000000000000000000000000000000000000000000000000000000000000000",
            "00000bda54dd744907290defac4f74bec507fdafd96e123c49bea56826f73702",
            "a469b67453a13a6abc40e81b760a0a5fd95870dbb8bbe99973c246c49561e101"
        ]);
        let estimate = estimate_primecount(&x);
        assert_bit_difference(estimate, sage_est, 29);
    }

    #[test]
    fn pi_x_max() {
        let x = U1024::MAX;
        let estimate = estimate_primecount(&x);
        let sage_est = Uint::from_be_hex(concat![
            "005c7682fe13533e630c22e716b35439b3dc61f1d4898d78a36dd9c9afc0745a",
            "06d3a0deb93b77423f6d11c107283fcfdb8ae17de22b5197972f37cb480a2737",
            "fe8d0f15202bb43bc1863b05f6d3849f865b95242eaec9789dcf3b40e92504d9",
            "8258f80b394ebec1c63d1186f9552689076f709c2fd8497b5f78d82cea2c2137"
        ]);
        assert_bit_difference(estimate, sage_est, 33);
    }
    #[test]
    fn pi_x_random() {
        // This is a ChaCha8Rng with seed b"01234567890123456789012345678901"
        let x = Uint::from_be_hex(concat![
            "62A211E0907141403FD3EB60A82EAB701524710BDB024EB68DFF309389258B63",
            "2EB9975D29F028F5137AC9DE870EB622D2D45A0D3A9C5801E8A3109BED220F82",
            "890E108F1778E5523E3E89CCD5DEDB667E6C17E940E9D4C3F58575C86CB76403",
            "017AD59D33AC084D2E58D81F8BB87A61B44677037A7DBDE04814256570DCBD7A"
        ]);
        let sage_est = U1024::from_be_hex(concat![
            "0023ac3184a0c4c8e9025e0ae9b44d7980cee1baacf69032bb898677841fac0e",
            "516fa6bc8c1d1d3bb282622aa62c49f2d8e622d2f9aa80af3140c8c225136301",
            "7c99621943c90ab55a6dd69a678110233254a1a3c50ceb1cdb516e7220a7514a",
            "17b20114c7bef6f316e94cf7c9181187d70e751bda2e18695fa71e8015b8cf1c"
        ]);
        let estimate = estimate_primecount(&x);
        assert_bit_difference(estimate, sage_est, 34);
    }

    #[test]
    fn pi_x_u128() {
        let x = U128::from_u128(1000000000000000000000000);
        let sage_est = U128::from_be_hex("00000000000003e76557786d0933dca8");
        let estimate = estimate_primecount(&x);
        assert_bit_difference(estimate, sage_est, 18);
    }

    #[test]
    fn pi_x_u64() {
        let x = U64::from_u64(10000000);
        let sage_est = U64::from_be_hex("00000000000A2556");
        let estimate = estimate_primecount(&x);
        assert_bit_difference(estimate, sage_est, 9);
    }

    fn assert_bit_difference<const LIMBS: usize>(candidate: Uint<LIMBS>, reference: Uint<LIMBS>, min_bit_diff: u32) {
        let delta = if reference > candidate {
            reference - candidate
        } else {
            candidate - reference
        };
        assert!(
            reference.bits_vartime() - delta.bits_vartime() >= min_bit_diff,
            "Estimate not close enough: delta has {} bits, reference has {} bits. Difference should be >= {}\nEstimate: {candidate},\nReference: {reference}",
            delta.bits_vartime(),
            reference.bits_vartime(),
            min_bit_diff
        );
    }

    #[test]
    fn pi_x_estimates_for_known_values() {
        // List of known values for π(x), expressed as a tuple of `(π(x), exponent)`, where the `exponent` is used with base 10.
        let pi_xs: Vec<(u128, u32)> = vec![
            // The error is large for small x, so we skip them.
            // (4, 1),
            // (25, 2),
            // (168, 3),
            (1229, 4),
            (9592, 5),
            (78498, 6),
            (664579, 7),
            (5761455, 8),
            (50847534, 9),
            (455052511, 10),
            (4118054813, 11),
            (37607912018, 12),
            (346065536839, 13),
            (3204941750802, 14),
            (29844570422669, 15),
            (279238341033925, 16),
            (2623557157654233, 17),
            (24739954287740860, 18),
            (234057667276344607, 19),
            (2220819602560918840, 20),
            (21127269486018731928, 21),
            (201467286689315906290, 22),
            (1925320391606803968923, 23),
            (18435599767349200867866, 24),
            (176846309399143769411680, 25),
            (1699246750872437141327603, 26),
            (16352460426841680446427399, 27),
            (157589269275973410412739598, 28),
            (1520698109714272166094258063, 29),
        ];
        for (pi_x, exponent) in pi_xs.iter() {
            let pi_x_wide = U256::from_u128(*pi_x);
            let n = U256::from_u128(10u128.pow(*exponent));
            let estimate = estimate_primecount(&n);
            let delta = if pi_x_wide > estimate {
                pi_x_wide - estimate
            } else {
                estimate - pi_x_wide
            };
            let delta = uint_to_u128(&delta);
            let estimate_128 = uint_to_u128(&estimate);
            let error = (delta as f64 / *pi_x as f64) * 100.0;
            assert!(
                error < 2.2,
                "10^{exponent}:\t{pi_x} - {estimate_128} = {delta}, err: {error:.2}"
            );
        }
    }

    fn uint_to_u128<const LIMBS: usize>(x: &Uint<LIMBS>) -> u128 {
        let limbs = x.as_limbs();
        #[cfg(target_pointer_width = "32")]
        return (limbs[3].0 as u128) << 96
            | (limbs[2].0 as u128) << 64
            | (limbs[1].0 as u128) << 32
            | limbs[0].0 as u128;
        #[cfg(target_pointer_width = "64")]
        return ((limbs[1].0 as u128) << 64) | limbs[0].0 as u128;
    }
}
