//! Functions implementing the functionality prescribed by FIPS-186.5 standard[^FIPS].
//!
//! [^FIPS]: FIPS-186.5 standard, <https://nvlpubs.nist.gov/nistpubs/FIPS/NIST.FIPS.186-5.pdf>

use crypto_bigint::{Odd, RandomMod, Unsigned};
use rand_core::CryptoRng;

use crate::{
    hazmat::{LucasCheck, MillerRabin, Primality, SelfridgeBase, equals_primitive, lucas_test},
    presets::Flavor,
};

/// Probabilistically checks if the given number is prime using the provided RNG
/// according to FIPS-186.5[^FIPS] standard.
///
/// Performed checks:
/// - `mr_iterations` of Miller-Rabin check with random bases;
/// - Regular Lucas check with Selfridge base (see [`SelfridgeBase`] for details), if `add_lucas_test` is `true`.
///
/// See [`MillerRabin`] and [`lucas_test`] for more details about the checks;
/// use [`minimum_mr_iterations`](`crate::hazmat::minimum_mr_iterations`)
/// to calculate the number of required iterations.
///
/// [^FIPS]: FIPS-186.5 standard, <https://nvlpubs.nist.gov/nistpubs/FIPS/NIST.FIPS.186-5.pdf>
pub fn is_prime<T>(
    rng: &mut (impl CryptoRng + ?Sized),
    flavor: Flavor,
    candidate: &T,
    mr_iterations: usize,
    add_lucas_test: bool,
) -> bool
where
    T: Unsigned + RandomMod,
{
    match flavor {
        Flavor::Any => {}
        Flavor::Safe => return is_safe_prime(rng, candidate, mr_iterations, add_lucas_test),
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

    // The random base test only makes sense when `candidate > 3`.
    if !equals_primitive(candidate, 3) {
        let mr = MillerRabin::new(odd_candidate.clone());
        for _ in 0..mr_iterations {
            if !mr.test_random_base(rng).is_probably_prime() {
                return false;
            }
        }
    }

    if add_lucas_test {
        match lucas_test(odd_candidate, SelfridgeBase, LucasCheck::Strong) {
            Primality::Composite => return false,
            Primality::Prime => return true,
            _ => {}
        }
    }

    true
}

/// Probabilistically checks if the given number is a safe prime using the provided RNG
/// according to FIPS-186.5[^FIPS] standard.
///
/// See [`fips_is_prime`] for details about the performed checks.
///
/// [^FIPS]: FIPS-186.5 standard, <https://nvlpubs.nist.gov/nistpubs/FIPS/NIST.FIPS.186-5.pdf>
fn is_safe_prime<T>(
    rng: &mut (impl CryptoRng + ?Sized),
    candidate: &T,
    mr_iterations: usize,
    add_lucas_test: bool,
) -> bool
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

    is_prime(rng, Flavor::Any, candidate, mr_iterations, add_lucas_test)
        && is_prime(
            rng,
            Flavor::Any,
            &candidate.wrapping_shr_vartime(1),
            mr_iterations,
            add_lucas_test,
        )
}
