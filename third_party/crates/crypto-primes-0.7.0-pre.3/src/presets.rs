use crypto_bigint::{Odd, RandomBits, RandomMod, Unsigned};
use rand_core::CryptoRng;

use crate::{
    generic::sieve_and_find,
    hazmat::{
        AStarBase, LucasCheck, MillerRabin, Primality, SetBits, SmallFactorsSieveFactory, equals_primitive, lucas_test,
    },
};

/// The specific category of primes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Flavor {
    /// Any prime.
    Any,
    /// Safe prime, that is a prime `x` such that `(x - 1) / 2` is also prime.
    Safe,
}

/// Returns a random prime of size `bit_length` using the provided RNG.
///
/// The returned prime will have its MSB set.
///
/// Panics if `bit_length` is less than the bit length of the smallest possible prime with the requested `flavor`.
///
/// See [`is_prime`] for details about the performed checks.
pub fn random_prime<T, R>(rng: &mut R, flavor: Flavor, bit_length: u32) -> T
where
    T: Unsigned + RandomBits + RandomMod,
    R: CryptoRng + ?Sized,
{
    let factory = SmallFactorsSieveFactory::new(flavor, bit_length, SetBits::Msb)
        .unwrap_or_else(|err| panic!("Error creating the sieve: {err}"));
    sieve_and_find(rng, factory, |_rng, candidate| is_prime(flavor, candidate))
        .unwrap_or_else(|err| panic!("Error generating random candidates: {err}"))
        .expect("will produce a result eventually")
}

/// Checks if the given number is prime.
///
/// Performed tests:
/// - Miller-Rabin test with base 2;
/// - [`LucasCheck::Bpsw21`] test with [`AStarBase`].
///
/// See [`MillerRabin`] and [`lucas_test`] for more details about the tests.
///
/// This is the recommended approach by Baillie et al[^Baillie2021],
/// improving on the BPSW'80 test[^Baillie1980].
/// At the moment of the writing there are no known composites that are reported to be primes
/// by either of the approaches[^Baillie2021];
/// it is conjectured that they may exist, but their size is larger than the numbers
/// that are used in practice.
///
/// [^Baillie1980]: R. Baillie, S. S. Wagstaff, "Lucas pseudoprimes",
///       Math. Comp. 35 1391-1417 (1980),
///       DOI: [10.2307/2006406](https://dx.doi.org/10.2307/2006406),
///       <http://mpqs.free.fr/LucasPseudoprimes.pdf>
///
/// [^Baillie2021]: R. Baillie, A. Fiori, S. S. Wagstaff,
///       "Strengthening the Baillie-PSW primality test",
///       Math. Comp. 90 1931-1955 (2021),
///       DOI: [10.1090/mcom/3616](https://doi.org/10.1090/mcom/3616)
pub fn is_prime<T>(flavor: Flavor, candidate: &T) -> bool
where
    T: Unsigned + RandomMod,
{
    match flavor {
        Flavor::Any => {}
        Flavor::Safe => return is_safe_prime(candidate),
    }

    if equals_primitive(candidate, 1) {
        return false;
    }

    if equals_primitive(candidate, 2) {
        return true;
    }

    let odd_candidate: Odd<T> = match Odd::new(candidate.clone()).into() {
        Some(x) => x,
        None => return false,
    };

    let mr = MillerRabin::new(odd_candidate.clone());

    if !mr.test_base_two().is_probably_prime() {
        return false;
    }

    match lucas_test(odd_candidate, AStarBase, LucasCheck::Bpsw21) {
        Primality::Composite => false,
        Primality::Prime => true,
        Primality::ProbablyPrime => true,
    }
}

/// Checks if the given number is a safe prime.
///
/// See [`is_prime`] for details about the performed checks.
fn is_safe_prime<T>(candidate: &T) -> bool
where
    T: Unsigned + RandomMod,
{
    // Since, by the definition of safe prime, `(candidate - 1) / 2` must also be prime,
    // and therefore odd, `candidate` has to be equal to 3 modulo 4.
    // 5 is the only exception, so we check for it.
    if equals_primitive(candidate, 5) {
        return true;
    }

    // Safe primes are always of the form 4k + 3 (i.e. n ≡ 3 mod 4)
    // The last two digits of a binary number give you its value modulo 4.
    // Primes p=4n+3 will always end in 11 in binary because p ≡ 3 mod 4.
    if candidate.as_ref()[0].0 & 3 != 3 {
        return false;
    }

    is_prime(Flavor::Any, candidate) && is_prime(Flavor::Any, &candidate.wrapping_shr_vartime(1))
}

#[cfg(test)]
mod tests {
    use crypto_bigint::{BoxedUint, CheckedAdd, RandomMod, U64, U128, Uint, Unsigned, Word, nlimbs};
    use num_prime::nt_funcs::is_prime64;
    use rand_core::{OsRng, TryRngCore};

    use super::{Flavor, is_prime, random_prime};
    use crate::{
        fips,
        hazmat::{minimum_mr_iterations, primes, pseudoprimes},
    };

    fn fips_is_prime<T: Unsigned + RandomMod>(flavor: Flavor, num: &T) -> bool {
        let mr_iterations = minimum_mr_iterations(128, 100).unwrap();
        fips::is_prime(&mut OsRng.unwrap_mut(), flavor, num, mr_iterations, false)
    }

    fn test_large_primes<const L: usize>(nums: &[Uint<L>]) {
        for num in nums {
            assert!(is_prime(Flavor::Any, num));
            assert!(fips_is_prime(Flavor::Any, num));
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

    fn test_pseudoprimes(nums: &[u32]) {
        for num in nums {
            assert!(!is_prime(Flavor::Any, &U64::from(*num)));
            assert!(!fips_is_prime(Flavor::Any, &U64::from(*num)));
        }
    }

    #[test]
    fn pseudoprimes() {
        test_pseudoprimes(pseudoprimes::EXTRA_STRONG_LUCAS);
        test_pseudoprimes(pseudoprimes::STRONG_LUCAS);
        test_pseudoprimes(pseudoprimes::ALMOST_EXTRA_STRONG_LUCAS);
        test_pseudoprimes(pseudoprimes::STRONG_BASE_2);
        test_pseudoprimes(pseudoprimes::FIBONACCI);
        test_pseudoprimes(pseudoprimes::BRUCKMAN_LUCAS);
        test_pseudoprimes(pseudoprimes::LUCAS);

        for num in pseudoprimes::STRONG_FIBONACCI {
            assert!(!is_prime(Flavor::Any, num));
            assert!(!fips_is_prime(Flavor::Any, num));
        }

        assert!(!is_prime(Flavor::Any, &pseudoprimes::LARGE_CARMICHAEL_NUMBER));
        assert!(!fips_is_prime(Flavor::Any, &pseudoprimes::LARGE_CARMICHAEL_NUMBER));
    }

    fn test_cunningham_chain<const L: usize>(length: usize, num: &Uint<L>) {
        let mut next = *num;
        for i in 0..length {
            assert!(is_prime(Flavor::Any, &next));
            assert!(fips_is_prime(Flavor::Any, &next));

            // The start of the chain isn't a safe prime by definition
            if i > 0 {
                assert!(is_prime(Flavor::Safe, &next));
                assert!(fips_is_prime(Flavor::Safe, &next));
            }

            next = next.wrapping_shl_vartime(1).checked_add(&Uint::<L>::ONE).unwrap();
        }

        // The chain ended.
        assert!(!is_prime(Flavor::Any, &next));
        assert!(!fips_is_prime(Flavor::Any, &next));
    }

    #[test]
    fn cunningham_chains() {
        for (length, num) in primes::CUNNINGHAM_CHAINS_128 {
            test_cunningham_chain(*length, num);
        }
        for (length, num) in primes::CUNNINGHAM_CHAINS_512 {
            test_cunningham_chain(*length, num);
        }
    }

    #[test]
    fn prime_generation() {
        for bit_length in (28..=128).step_by(10) {
            let p: U128 = random_prime(&mut OsRng.unwrap_mut(), Flavor::Any, bit_length);
            assert!(p.bits_vartime() == bit_length);
            assert!(is_prime(Flavor::Any, &p));
            assert!(fips_is_prime(Flavor::Any, &p));
        }
    }

    #[test]
    fn prime_generation_boxed() {
        for bit_length in (28..=128).step_by(10) {
            let p: BoxedUint = random_prime(&mut OsRng.unwrap_mut(), Flavor::Any, bit_length);
            assert!(p.bits_vartime() == bit_length);
            assert!(p.to_words().len() == nlimbs!(bit_length));
            assert!(is_prime(Flavor::Any, &p));
            assert!(fips_is_prime(Flavor::Any, &p));
        }
    }

    #[test]
    fn safe_prime_generation() {
        for bit_length in (28..=128).step_by(10) {
            let p: U128 = random_prime(&mut OsRng.unwrap_mut(), Flavor::Safe, bit_length);
            assert!(p.bits_vartime() == bit_length);
            assert!(is_prime(Flavor::Safe, &p));
            assert!(fips_is_prime(Flavor::Safe, &p));
        }
    }

    #[test]
    fn safe_prime_generation_boxed() {
        for bit_length in (28..=189).step_by(10) {
            let p: BoxedUint = random_prime(&mut OsRng.unwrap_mut(), Flavor::Safe, bit_length);
            assert!(p.bits_vartime() == bit_length);
            assert!(p.to_words().len() == nlimbs!(bit_length));
            assert!(is_prime(Flavor::Safe, &p));
            assert!(fips_is_prime(Flavor::Safe, &p));
        }
    }

    #[test]
    fn corner_cases_is_prime() {
        for num in 0u64..30 {
            let is_prime_ref = is_prime64(num);
            let is_safe_prime_ref = is_prime_ref && is_prime64(num / 2);

            let num_uint = U64::from(num);

            let is_prime_test = is_prime(Flavor::Any, &num_uint);
            assert_eq!(
                is_prime_ref, is_prime_test,
                "num={num}, expected={is_prime_ref}, actual={is_prime_test}"
            );

            let is_safe_prime_test = is_prime(Flavor::Safe, &num_uint);
            assert_eq!(
                is_safe_prime_ref, is_safe_prime_test,
                "num={num}, expected={is_safe_prime_ref}, actual={is_safe_prime_test}"
            );

            let is_prime_test = fips_is_prime(Flavor::Any, &num_uint);
            assert_eq!(
                is_prime_ref, is_prime_test,
                "num={num}, expected={is_prime_ref}, actual={is_prime_test}"
            );

            let is_safe_prime_test = fips_is_prime(Flavor::Safe, &num_uint);
            assert_eq!(
                is_safe_prime_ref, is_safe_prime_test,
                "num={num}, expected={is_safe_prime_ref}, actual={is_safe_prime_test}"
            );
        }
    }

    #[test]
    fn inconclusive_sieving_result() {
        // Coverage test.
        // This number is a product of two primes larger than the maximum prime in `SMALL_PRIMES`,
        // so the initial sieving cannot tell if it is prime or not,
        // and a full primality test is run.
        assert!(!is_prime(Flavor::Safe, &U64::from(17881u32 * 17891u32)));
        assert!(!fips_is_prime(Flavor::Safe, &U64::from(17881u32 * 17891u32)));
    }

    #[test]
    #[should_panic(
        expected = "Error generating random candidates: The requested bit length of the candidate (65) is larger than the maximum size of the target integer type (64)."
    )]
    fn generate_prime_too_many_bits() {
        let _p: U64 = random_prime(&mut OsRng.unwrap_mut(), Flavor::Any, 65);
    }

    #[test]
    #[should_panic(
        expected = "Error generating random candidates: The requested bit length of the candidate (65) is larger than the maximum size of the target integer type (64)."
    )]
    fn generate_safe_prime_too_many_bits() {
        let _p: U64 = random_prime(&mut OsRng.unwrap_mut(), Flavor::Safe, 65);
    }

    fn is_prime_ref(num: Word) -> bool {
        num_prime::nt_funcs::is_prime(&num, None).probably()
    }

    #[test]
    fn corner_cases_generate_prime() {
        for bits in 2..5 {
            for _ in 0..100 {
                let p: U64 = random_prime(&mut OsRng.unwrap_mut(), Flavor::Any, bits);
                let p_word = p.as_words()[0];
                assert!(is_prime_ref(p_word));
            }
        }
    }

    #[test]
    fn corner_cases_generate_safe_prime() {
        for bits in 3..5 {
            for _ in 0..100 {
                let p: U64 = random_prime(&mut OsRng.unwrap_mut(), Flavor::Safe, bits);
                let p_word = p.as_words()[0];
                assert!(is_prime_ref(p_word) && is_prime_ref(p_word / 2));
            }
        }
    }
}

#[cfg(test)]
#[cfg(feature = "tests-openssl")]
mod tests_openssl {
    use alloc::format;
    use core::num::NonZero;

    use crypto_bigint::U128;
    use openssl::bn::{BigNum, BigNumContext};
    use rand_core::{OsRng, TryRngCore};

    use super::{Flavor, is_prime, random_prime};
    use crate::{
        fips,
        hazmat::{SetBits, minimum_mr_iterations, random_odd_integer},
    };

    fn openssl_is_prime(num: &BigNum, ctx: &mut BigNumContext) -> bool {
        num.is_prime(64, ctx).unwrap()
    }

    fn to_openssl(num: &U128) -> BigNum {
        BigNum::from_hex_str(&format!("{num:x}")).unwrap()
    }

    fn from_openssl(num: &BigNum) -> U128 {
        U128::from_be_hex(&num.to_hex_str().unwrap())
    }

    #[test]
    fn openssl_cross_check() {
        let mut ctx = BigNumContext::new().unwrap();

        // Generate primes, let OpenSSL check them
        for _ in 0..100 {
            let p: U128 = random_prime(&mut OsRng.unwrap_mut(), Flavor::Any, 128);
            let p_bn = to_openssl(&p);
            assert!(openssl_is_prime(&p_bn, &mut ctx), "OpenSSL reports {p} as composite",);
        }

        let mr_iterations = minimum_mr_iterations(U128::BITS, 100).unwrap();

        // Generate primes with OpenSSL, check them
        let mut p_bn = BigNum::new().unwrap();
        for _ in 0..100 {
            p_bn.generate_prime(128, false, None, None).unwrap();
            let p = from_openssl(&p_bn);
            assert!(is_prime(Flavor::Any, &p), "we report {p} as composite");
            assert!(
                fips::is_prime(&mut OsRng.unwrap_mut(), Flavor::Any, &p, mr_iterations, false),
                "we report {p} as composite"
            );
        }

        // Generate random numbers, check if our test agrees with OpenSSL
        for _ in 0..100 {
            let p = random_odd_integer::<U128, _>(&mut OsRng.unwrap_mut(), NonZero::new(128).unwrap(), SetBits::Msb)
                .unwrap();
            let p_bn = to_openssl(&p);
            let expected = openssl_is_prime(&p_bn, &mut ctx);

            let actual = is_prime(Flavor::Any, p.as_ref());
            assert_eq!(
                actual, expected,
                "difference between OpenSSL and us: OpenSSL reports {expected}, we report {actual}",
            );

            let actual = fips::is_prime(&mut OsRng.unwrap_mut(), Flavor::Any, p.as_ref(), mr_iterations, false);
            assert_eq!(
                actual, expected,
                "difference between OpenSSL and us: OpenSSL reports {expected}, we report {actual}",
            );
        }
    }
}

#[cfg(test)]
#[cfg(feature = "tests-gmp")]
mod tests_gmp {
    use core::num::NonZero;

    use crypto_bigint::U128;
    use rand_core::{OsRng, TryRngCore};
    use rug::{
        Integer,
        integer::{IsPrime, Order},
    };

    use super::{Flavor, is_prime, random_prime};
    use crate::{
        fips,
        hazmat::{SetBits, minimum_mr_iterations, random_odd_integer},
    };

    fn gmp_is_prime(num: &Integer) -> bool {
        matches!(num.is_probably_prime(25), IsPrime::Yes | IsPrime::Probably)
    }

    fn to_gmp(num: &U128) -> Integer {
        Integer::from_digits(num.as_words(), Order::Lsf)
    }

    fn from_gmp(num: &Integer) -> U128 {
        U128::from_words(num.to_digits(Order::Lsf).try_into().unwrap())
    }

    #[test]
    fn gmp_cross_check() {
        // Generate primes, let GMP check them
        for _ in 0..100 {
            let p: U128 = random_prime(&mut OsRng.unwrap_mut(), Flavor::Any, 128);
            let p_bn = to_gmp(&p);
            assert!(gmp_is_prime(&p_bn), "GMP reports {p} as composite");
        }

        let mr_iterations = minimum_mr_iterations(U128::BITS, 100).unwrap();

        // Generate primes with GMP, check them
        for _ in 0..100 {
            let start =
                random_odd_integer::<U128, _>(&mut OsRng.unwrap_mut(), NonZero::new(128).unwrap(), SetBits::Msb)
                    .unwrap();
            let start_bn = to_gmp(&start);
            let p_bn = start_bn.next_prime();
            let p = from_gmp(&p_bn);
            assert!(is_prime(Flavor::Any, &p), "we report {p} as composite");
            assert!(
                fips::is_prime(&mut OsRng.unwrap_mut(), Flavor::Any, &p, mr_iterations, false),
                "we report {p} as composite"
            );
        }

        // Generate random numbers, check if our test agrees with GMP
        for _ in 0..100 {
            let p = random_odd_integer::<U128, _>(&mut OsRng.unwrap_mut(), NonZero::new(128).unwrap(), SetBits::Msb)
                .unwrap();
            let p_bn = to_gmp(&p);
            let expected = gmp_is_prime(&p_bn);

            let actual = is_prime(Flavor::Any, p.as_ref());
            assert_eq!(
                actual, expected,
                "difference between GMP and us: GMP reports {expected}, we report {actual}",
            );

            let actual = fips::is_prime(&mut OsRng.unwrap_mut(), Flavor::Any, p.as_ref(), mr_iterations, false);
            assert_eq!(
                actual, expected,
                "difference between GMP and us: GMP reports {expected}, we report {actual}",
            );
        }
    }
}
