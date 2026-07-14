//! Generate prime components for the RSA Private Key

use alloc::vec::Vec;
use crypto_bigint::{BoxedUint, Odd};
use crypto_primes::{
    hazmat::{SetBits, SmallFactorsSieveFactory},
    is_prime, sieve_and_find, Flavor,
};
use rand_core::CryptoRng;

use crate::{
    algorithms::rsa::{compute_modulus, compute_private_exponent_euler_totient},
    errors::{Error, Result},
};

pub struct RsaPrivateKeyComponents {
    pub n: Odd<BoxedUint>,
    pub e: BoxedUint,
    pub d: BoxedUint,
    pub primes: Vec<BoxedUint>,
}

/// Generates a multi-prime RSA keypair of the given bit size, public exponent,
/// and the given random source, as suggested in [1]. Although the public
/// keys are compatible (actually, indistinguishable) from the 2-prime case,
/// the private keys are not. Thus it may not be possible to export multi-prime
/// private keys in certain formats or to subsequently import them into other
/// code.
///
/// Table 1 in [2] suggests maximum numbers of primes for a given size.
///
/// [1]: https://patents.google.com/patent/US4405829A/en
/// [2]: http://www.cacr.math.uwaterloo.ca/techreports/2006/cacr2006-16.pdf
pub(crate) fn generate_multi_prime_key_with_exp<R: CryptoRng + ?Sized>(
    rng: &mut R,
    nprimes: usize,
    bit_size: usize,
    exp: BoxedUint,
) -> Result<RsaPrivateKeyComponents> {
    if nprimes < 2 {
        return Err(Error::NprimesTooSmall);
    }

    if bit_size < 64 {
        let prime_limit = (1u64 << (bit_size / nprimes) as u64) as f64;

        // pi approximates the number of primes less than prime_limit

        // Calculate `log(prime_limit)` as `log(x) = log2(x) / log2(e) = log2(x) * log(2)`.
        let mut pi = prime_limit / ((bit_size / nprimes) as f64 * core::f64::consts::LN_2 - 1.);

        // Generated primes start with 0b11, so we can only use a quarter of them.
        pi /= 4f64;
        // Use a factor of two to ensure that key generation terminates in a
        // reasonable amount of time.
        pi /= 2f64;

        if pi < nprimes as f64 {
            return Err(Error::TooFewPrimes);
        }
    }

    let mut primes = vec![BoxedUint::zero(); nprimes];
    let n_final: Odd<BoxedUint>;
    let d_final: BoxedUint;

    'next: loop {
        let mut todo = bit_size;
        // `generate_prime_with_rng` should set the top two bits in each prime.
        // Thus each prime has the form
        //   p_i = 2^bitlen(p_i) × 0.11... (in base 2).
        // And the product is:
        //   P = 2^todo × α
        // where α is the product of nprimes numbers of the form 0.11...
        //
        // If α < 1/2 (which can happen for nprimes > 2), we need to
        // shift todo to compensate for lost bits: the mean value of 0.11...
        // is 7/8, so todo + shift - nprimes * log2(7/8) ~= bits - 1/2
        // will give good results.
        if nprimes >= 7 {
            todo += (nprimes - 2) / 5;
        }

        for (i, prime) in primes.iter_mut().enumerate() {
            let bits = (todo / (nprimes - i)) as u32;
            *prime = generate_prime_with_rng(rng, bits);
            todo -= prime.bits() as usize;
        }

        // Makes sure that primes is pairwise unequal.
        for (i, prime1) in primes.iter().enumerate() {
            for prime2 in primes.iter().take(i) {
                if prime1 == prime2 {
                    continue 'next;
                }
            }
        }

        let n = compute_modulus(&primes);

        if n.bits() as usize != bit_size {
            // This should never happen for nprimes == 2 because
            // generate_prime_with_rng should set the top two bits in each prime.
            // For nprimes > 2 we hope it does not happen often.
            continue 'next;
        }

        if let Ok(d) = compute_private_exponent_euler_totient(&primes, &exp) {
            n_final = n;
            d_final = d;
            break;
        }
    }

    Ok(RsaPrivateKeyComponents {
        n: n_final,
        e: exp,
        d: d_final,
        primes,
    })
}

fn generate_prime_with_rng<R: CryptoRng + ?Sized>(rng: &mut R, bit_length: u32) -> BoxedUint {
    let factory = SmallFactorsSieveFactory::new(Flavor::Any, bit_length, SetBits::TwoMsb)
        .unwrap_or_else(|err| panic!("Error creating the sieve: {err}"));

    sieve_and_find(rng, factory, |_rng, candidate| {
        is_prime(Flavor::Any, candidate)
    })
    .unwrap_or_else(|err| panic!("Error generating random candidates: {}", err))
    .expect("will produce a result eventually")
}

#[cfg(test)]
mod tests {
    use super::*;
    use rand_chacha::{rand_core::SeedableRng, ChaCha8Rng};

    const EXP: u64 = 65537;

    #[test]
    fn test_impossible_keys() {
        let mut rng = ChaCha8Rng::from_seed([42; 32]);
        let exp = BoxedUint::from(EXP);

        for i in 0..32 {
            let _ = generate_multi_prime_key_with_exp(&mut rng, 2, i, exp.clone());
            let _ = generate_multi_prime_key_with_exp(&mut rng, 3, i, exp.clone());
            let _ = generate_multi_prime_key_with_exp(&mut rng, 4, i, exp.clone());
            let _ = generate_multi_prime_key_with_exp(&mut rng, 5, i, exp.clone());
        }
    }

    macro_rules! key_generation {
        ($name:ident, $multi:expr, $size:expr) => {
            #[test]
            fn $name() {
                let mut rng = ChaCha8Rng::from_seed([42; 32]);
                let exp = BoxedUint::from(EXP);
                for _ in 0..10 {
                    let components =
                        generate_multi_prime_key_with_exp(&mut rng, $multi, $size, exp.clone())
                            .unwrap();
                    assert_eq!(components.n.bits(), $size);
                    assert_eq!(components.primes.len(), $multi);
                }
            }
        };
    }

    key_generation!(key_generation_128, 2, 128);
    key_generation!(key_generation_1024, 2, 1024);

    key_generation!(key_generation_multi_3_256, 3, 256);

    key_generation!(key_generation_multi_4_64, 4, 64);

    key_generation!(key_generation_multi_5_64, 5, 64);
    key_generation!(key_generation_multi_8_576, 8, 576);
    // TODO: reenable, currently slow
    // key_generation!(key_generation_multi_16_1024, 16, 1024);
}
