//! Miller-Rabin primality test.

use crypto_bigint::{Limb, Monty, NonZero as CTNonZero, Odd, PowBoundedExp, RandomMod, Square, Unsigned};
use rand_core::CryptoRng;

use super::{
    Primality, equals_primitive,
    float::{floor_sqrt, two_powf_upper_bound, two_powi},
};

/// Precomputed data used to perform Miller-Rabin primality test[^Pomerance1980].
///
/// The numbers that pass it are commonly called "strong probable primes"
/// (or "strong pseudoprimes" if they are, in fact, composite).
///
/// The implementation satisfies the FIPS.186-5 standard[^FIPS].
///
/// [^Pomerance1980]: C. Pomerance, J. L. Selfridge, S. S. Wagstaff "The Pseudoprimes to 25*10^9",
///   Math. Comp. 35 1003-1026 (1980),
///   DOI: [10.2307/2006210](https://dx.doi.org/10.2307/2006210)
///
/// [^FIPS]: FIPS-186.5 standard, <https://nvlpubs.nist.gov/nistpubs/FIPS/NIST.FIPS.186-5.pdf>
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MillerRabin<T: Unsigned> {
    // The odd number that may or may not be a prime.
    candidate: T,
    /// The number of bits necessesary to represent the candidate. Note: this is not the number of
    /// bits used by a `T` in memory.
    bits: u32,
    /// Pre-computed parameters for the Montgomery form of `T`.
    montgomery_params: <<T as Unsigned>::Monty as Monty>::Params,
    /// The number 1 in Montgomery form.
    one: <T as Unsigned>::Monty,
    /// The number -1 in Montgomery form.
    minus_one: <T as Unsigned>::Monty,
    /// The `s` exponent in the Miller-Rabin test, that finds `s` and `d` odd s.t. `candidate - 1 ==
    /// 2^s * d` (the pair `s` and `d` is unique).
    s: u32,
    /// The `d` factor in the Miller-Rabin test, that finds `s` and `d` odd s.t. `candidate -
    /// 1 == 2^s * d` (the pair `s` and `d` is unique).
    d: T,
}

impl<T: Unsigned + RandomMod> MillerRabin<T> {
    /// Initializes a Miller-Rabin test for `candidate`.
    pub fn new(candidate: Odd<T>) -> Self {
        let params = <T as Unsigned>::Monty::new_params_vartime(candidate.clone());
        let m_one = <T as Unsigned>::Monty::one(params.clone());
        let m_minus_one = -m_one.clone();

        let one = T::one_like(candidate.as_ref());

        // Find `s` and odd `d` such that `candidate - 1 == 2^s * d`.
        let (s, d) = if candidate.as_ref() == &one {
            (0, one)
        } else {
            let candidate_minus_one = candidate.wrapping_sub(&one);
            let s = candidate_minus_one.trailing_zeros_vartime();
            // Will not overflow because `candidate` is odd and greater than 1.
            let d = candidate_minus_one
                .overflowing_shr_vartime(s)
                .expect("shifting by `s` is within range by construction: `candidate` is odd and greater than 1");
            (s, d)
        };

        Self {
            bits: candidate.bits_vartime(),
            candidate: candidate.get(),
            montgomery_params: params,
            one: m_one,
            minus_one: m_minus_one,
            s,
            d,
        }
    }

    /// Perform a Miller-Rabin check with a given base.
    pub fn test(&self, base: &T) -> Primality {
        // One could check here if `gcd(base, candidate) == 1` and return `Composite` otherwise.
        // In practice it doesn't make any performance difference in normal operation.

        let base = <T as Unsigned>::Monty::new(base.clone(), self.montgomery_params.clone());

        // Implementation detail: bounded exp gets faster every time we decrease the bound
        // by the window length it uses, which is currently 4 bits.
        // So even when the bound isn't low enough that the number can fit
        // in a smaller number of limbs, there is still a performance gain
        // from specifying the bound.
        let mut test = base.pow_bounded_exp(&self.d, self.bits);

        if test == self.one || test == self.minus_one {
            return Primality::ProbablyPrime;
        }
        for _ in 1..self.s {
            test = test.square();
            if test == self.one {
                return Primality::Composite;
            } else if test == self.minus_one {
                return Primality::ProbablyPrime;
            }
        }
        Primality::Composite
    }

    /// Perform a Miller-Rabin check with base 2.
    pub fn test_base_two(&self) -> Primality {
        self.test(&T::from_limb_like(Limb::from(2u32), &self.candidate))
    }

    /// Perform a Miller-Rabin check with a random base (in the range `[2, candidate-2]`,
    /// because the test holds trivially for bases 1 or `candidate-1`) drawn using the provided RNG.
    ///
    /// *Note:* if `candidate == 1` or `candidate == 3` (which would make the above range contain no numbers)
    /// no check is actually performed, since we already know the result
    /// ([`Primality::Composite`] for 1, [`Primality::Prime`] for 3).
    pub fn test_random_base<R: CryptoRng + ?Sized>(&self, rng: &mut R) -> Primality {
        if equals_primitive(&self.candidate, 1) {
            // As per standard convention
            return Primality::Composite;
        }

        if equals_primitive(&self.candidate, 3) {
            // As per standard convention
            return Primality::Prime;
        }

        // The candidate is odd, so by now it is guaranteed to be >= 5.
        let range = self.candidate.wrapping_sub(&T::from(3u32));
        let range_nonzero = CTNonZero::new(range).expect("the range should be non-zero by construction");
        // This should not overflow as long as `random_mod()` behaves according to the contract
        // (that is, returns a number within the given range).
        let random = T::random_mod(rng, &range_nonzero)
            .checked_add(&T::from(2u32))
            .expect("addition should not overflow by construction");
        self.test(&random)
    }
}

/**
Returns the probability `p_{k,t}` of an odd `k`-bit integer passing `t` rounds of MR testing with random bases
is actually composite.

Taken from FIPS-186.5[^FIPS], Section C.1, Eq. (2); FIPS in turn quotes Damgård et al[^Damgard].
There it can be found as Eq. (4.1), with the factors bounded by Proposition 1 and Proposition 2 in Section 4.

**Warning**:[^FIPS]
Care must be taken when using the phrase "error probability" in connection with
the recommended number of rounds of MR testing. The probability that a composite number of bit length `k`
survives `t` rounds of Miller-Rabin testing is not the same as `p_{k,t}`, which is the probability that a
number surviving `t` rounds of Miller-Rabin testing is composite. Ordinarily, the latter probability
is the one that should be of most interest to a party responsible for generating primes, while the
former may be more important to a party responsible for validating the primality of a number
generated by someone else. However, for sufficiently large `k` (e.g., `k ≥ 51`), it can be shown that
`p_{k,t} ≤ 4^{–t}` under the same assumptions concerning the selection of candidates as those made to
obtain formula for `p_{k,t}` (see Damgård et al[^Damgard]).
In such cases, `t = ceil(–log2(p_target)/2)` rounds of Miller-Rabin testing
can be used to both generate and validate primes with `p_target` serving as an upper bound on both
the probability that the generation process yields a composite number and the probability that a
composite number would survive an attempt to validate its primality.

[^FIPS]: FIPS-186.5 standard, <https://nvlpubs.nist.gov/nistpubs/FIPS/NIST.FIPS.186-5.pdf>
[^Damgard]:
    Damgård I, Landrock P, Pomerance C (1993) Average Case Error Estimates for the Strong
    Probable Prime Test. Mathematics of Computation 61(203):177-194 (1993),
    <https://www.ams.org/journals/mcom/1993-61-203/S0025-5718-1993-1189518-9/S0025-5718-1993-1189518-9.pdf>
*/
const fn pseudoprime_probability(k: u32, t: u32, cap_m: u32) -> f64 {
    // Simplify Eq. (2) from [^FIPS] by factoring out `2^{k-2}`, which makes it
    // p_{k,t} = 2.000743 ln(2) k 2^{-2} (
    //     2^{-Mt} +
    //     8 (pi^2 - 6) / 3 * sum(m=3..M) sum(j=2..m) 2^{m - (m-1)t - j - (k-1)/j})

    // `2.00743 ln(2) k` comes from Proposition 2 in [^Damgard], from the estimate for `(pi(2^k) - pi(2^{k-1}))^{-1}`.

    // Calculate the powers of 2 under the summations.
    //
    // Technically, only a few terms really contribute to the result, and the rest are extremely small in comparison.
    // But finding out which ones specifically is a little messy.
    // Can be done if more performance is desired.
    let mut s = 0.;
    let mut m = 3i32;
    while m <= cap_m as i32 {
        let mut j = 2i32;
        while j <= m {
            // Note that we are using `two_powf_upper_bound()` which means we are getting a slightly larger result,
            // and therefore very slightly overestimating the resulting probability.
            // This means safety is not compromised.
            s += two_powf_upper_bound((m - (m - 1) * (t as i32) - j) as f64 - (k - 1) as f64 / j as f64);
            j += 1;
        }
        m += 1;
    }

    const PI: f64 = core::f64::consts::PI;

    // `2.00743 * ln(2) * 2^(-2)`
    const COEFF: f64 = 0.3478611111678627;

    COEFF * k as f64 * (1. / two_powi(cap_m * t) + 8. * (PI * PI - 6.) / 3. * s)
}

/// For a candidate of size `bit_length`, returns the minimum number of Miller-Rabin tests with random bases
/// required for the probability of hitting a pseudoprime (that is, a composite for which all M-R tests pass)
/// to be smaller than `2^{-log2_target}`.
///
/// Returns `None` if the number of iterations could not be found for the given bounds.
///
/// This function implements the formula prescribed by the FIPS.186-5 standard[^FIPS].
///
/// [^FIPS]: FIPS-186.5 standard, <https://nvlpubs.nist.gov/nistpubs/FIPS/NIST.FIPS.186-5.pdf>
pub const fn minimum_mr_iterations(bit_length: u32, log2_target: u32) -> Option<usize> {
    let mut t = 1;
    while t <= log2_target.div_ceil(2) {
        let cap_m_limit = floor_sqrt(4 * (bit_length - 1)) - 1;

        let mut cap_m = 3;
        while cap_m <= cap_m_limit {
            let p = pseudoprime_probability(bit_length, t, cap_m);
            if p < 1. / two_powi(log2_target) {
                return Some(t as usize);
            }
            cap_m += 1;
        }

        t += 1;
    }

    None
}

#[cfg(test)]
mod tests {
    use alloc::format;
    use core::num::NonZero;

    use crypto_bigint::{Odd, RandomMod, U64, U128, U1024, U1536, Uint, Unsigned};
    use rand_chacha::ChaCha8Rng;
    use rand_core::{CryptoRng, OsRng, SeedableRng, TryRngCore};

    #[cfg(feature = "tests-exhaustive")]
    use num_prime::nt_funcs::is_prime64;

    use super::{MillerRabin, minimum_mr_iterations};
    use crate::hazmat::{Primality, SetBits, SmallFactorsSieve, primes, pseudoprimes, random_odd_integer};

    #[test]
    fn miller_rabin_derived_traits() {
        let mr = MillerRabin::new(Odd::new(U64::ONE).unwrap());
        assert!(format!("{mr:?}").starts_with("MillerRabin"));
        assert_eq!(mr.clone(), mr);
    }

    #[test]
    fn random_base_corner_cases() {
        let mr = MillerRabin::new(Odd::new(U64::from(1u32)).unwrap());
        assert!(mr.test_random_base(&mut OsRng.unwrap_mut()) == Primality::Composite);

        let mr = MillerRabin::new(Odd::new(U64::from(3u32)).unwrap());
        assert!(mr.test_random_base(&mut OsRng.unwrap_mut()) == Primality::Prime);
    }

    fn is_spsp(num: u32) -> bool {
        pseudoprimes::STRONG_BASE_2.contains(&num)
    }

    fn random_checks<T: Unsigned + RandomMod, R: CryptoRng + ?Sized>(
        rng: &mut R,
        mr: &MillerRabin<T>,
        count: usize,
    ) -> usize {
        (0..count)
            .map(|_| -> usize { mr.test_random_base(rng).is_probably_prime().into() })
            .sum()
    }

    fn test_composites(numbers: &[u32], expected_result: bool) {
        let mut rng = ChaCha8Rng::from_seed(*b"01234567890123456789012345678901");
        for num in numbers.iter() {
            let base_2_false_positive = is_spsp(*num);
            let actual_expected_result = if base_2_false_positive { true } else { expected_result };

            // A random base MR test is expected to report a composite as a prime
            // with about 1/4 probability. So we're expecting less than
            // 35 out of 100 false positives, seems to work.

            let mr = MillerRabin::new(Odd::new(U64::from(*num)).unwrap());
            assert_eq!(mr.test_base_two().is_probably_prime(), actual_expected_result);
            let reported_prime = random_checks(&mut rng, &mr, 100);
            assert!(
                reported_prime < 35,
                "reported as prime in {reported_prime} out of 100 tests",
            );
        }
    }

    #[test]
    fn trivial() {
        let mut rng = ChaCha8Rng::from_seed(*b"01234567890123456789012345678901");
        let start = random_odd_integer::<U1024, _>(&mut rng, NonZero::new(1024).unwrap(), SetBits::Msb).unwrap();
        for num in SmallFactorsSieve::new(start.get(), NonZero::new(1024).unwrap(), false)
            .unwrap()
            .take(10)
        {
            let mr = MillerRabin::new(Odd::new(num).unwrap());

            // Trivial tests, must always be true.
            assert!(mr.test(&1u32.into()).is_probably_prime());
            assert!(mr.test(&num.wrapping_sub(&1u32.into())).is_probably_prime());
        }
    }

    #[test]
    fn mersenne_prime() {
        let mut rng = ChaCha8Rng::from_seed(*b"01234567890123456789012345678901");

        // Mersenne prime 2^127-1
        let num = Odd::new(U128::from_be_hex("7fffffffffffffffffffffffffffffff")).unwrap();

        let mr = MillerRabin::new(num);
        assert!(mr.test_base_two().is_probably_prime());
        for _ in 0..10 {
            assert!(mr.test_random_base(&mut rng).is_probably_prime());
        }
    }

    #[test]
    fn strong_fibonacci_pseudoprimes() {
        let mut rng = ChaCha8Rng::from_seed(*b"01234567890123456789012345678901");

        for num in pseudoprimes::STRONG_FIBONACCI.iter() {
            let mr = MillerRabin::new(Odd::new(*num).unwrap());
            assert!(!mr.test_base_two().is_probably_prime());
            for _ in 0..1000 {
                assert!(!mr.test_random_base(&mut rng).is_probably_prime());
            }
        }
    }

    #[test]
    fn strong_pseudoprimes_base_2() {
        // These known exceptions for the base 2 MR test.
        test_composites(pseudoprimes::STRONG_BASE_2, true);
    }

    #[test]
    fn lucas_pseudoprimes() {
        // Cross-test against the pseudoprimes that circumvent the Lucas test.
        // We expect the MR test to correctly classify them as composites (most of the time).
        test_composites(pseudoprimes::EXTRA_STRONG_LUCAS, false);
        test_composites(pseudoprimes::STRONG_LUCAS, false);
        test_composites(pseudoprimes::ALMOST_EXTRA_STRONG_LUCAS, false);
        test_composites(pseudoprimes::FIBONACCI, false);
        test_composites(pseudoprimes::BRUCKMAN_LUCAS, false);
        test_composites(pseudoprimes::LUCAS, false);
    }

    #[test]
    fn large_carmichael_number() {
        let mr = MillerRabin::new(Odd::new(pseudoprimes::LARGE_CARMICHAEL_NUMBER).unwrap());

        // It is known to pass MR tests for all prime bases <307
        assert!(mr.test_base_two().is_probably_prime());
        assert!(mr.test(&U1536::from(293u64)).is_probably_prime());

        // A test with base 307 correctly reports the number as composite.
        assert!(!mr.test(&U1536::from(307u64)).is_probably_prime());
    }

    fn test_large_primes<const L: usize>(nums: &[Uint<L>]) {
        let mut rng = ChaCha8Rng::from_seed(*b"01234567890123456789012345678901");
        for num in nums {
            let mr = MillerRabin::new(Odd::new(*num).unwrap());
            assert!(mr.test_base_two().is_probably_prime());
            for _ in 0..10 {
                assert!(mr.test_random_base(&mut rng).is_probably_prime());
            }
        }
    }

    #[test]
    fn large_primes() {
        test_large_primes(primes::PRIMES_128);
        test_large_primes(primes::PRIMES_256);
        test_large_primes(primes::PRIMES_384);
        test_large_primes(primes::PRIMES_512);
        test_large_primes(primes::PRIMES_1024);
    }

    #[test]
    fn mr_iterations() {
        // The test values are taken from Table B.1 in FIPS-186.5 standard.

        assert_eq!(minimum_mr_iterations(140, 100).unwrap(), 32);
        assert_eq!(minimum_mr_iterations(140, 112).unwrap(), 38);
        assert_eq!(minimum_mr_iterations(1024, 100).unwrap(), 4);
        assert_eq!(minimum_mr_iterations(1024, 112).unwrap(), 5);

        assert_eq!(minimum_mr_iterations(170, 100).unwrap(), 27);
        assert_eq!(minimum_mr_iterations(170, 128).unwrap(), 41);
        assert_eq!(minimum_mr_iterations(1536, 100).unwrap(), 3);
        assert_eq!(minimum_mr_iterations(1536, 128).unwrap(), 4);

        assert_eq!(minimum_mr_iterations(200, 100).unwrap(), 22);
        assert_eq!(minimum_mr_iterations(200, 144).unwrap(), 44);
        assert_eq!(minimum_mr_iterations(2048, 100).unwrap(), 2);
        assert_eq!(minimum_mr_iterations(2048, 144).unwrap(), 4);

        // Test the case where the requested error probability cannot be reached.
        assert!(minimum_mr_iterations(128, 1024).is_none());
    }

    #[cfg(feature = "tests-exhaustive")]
    #[test]
    fn exhaustive() {
        // Test all the odd numbers up to the limit where we know the false positives,
        // and compare the results with the reference.
        for num in (3..pseudoprimes::EXHAUSTIVE_TEST_LIMIT).step_by(2) {
            let res_ref = is_prime64(num.into());

            let spsp = is_spsp(num);

            let mr = MillerRabin::new(Odd::new(U64::from(num)).unwrap());
            let res = mr.test_base_two().is_probably_prime();
            let expected = spsp || res_ref;
            assert_eq!(
                res, expected,
                "Miller-Rabin: n={num}, expected={expected}, actual={res}",
            );
        }
    }
}
