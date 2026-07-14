//! Prime-finding functions that can parallelize across multiple cores.

use crypto_bigint::{RandomBits, RandomMod, Unsigned};
use rand_core::CryptoRng;
use rayon::iter::{ParallelBridge, ParallelIterator};

use crate::{
    error::Error,
    hazmat::{SetBits, SieveFactory, SmallFactorsSieveFactory},
    presets::{Flavor, is_prime},
};

/// Sieves through the results of `sieve_factory` using a thread pool with `threadcount` threads,
/// and returns the first item for which `predicate` is `true`.
///
/// If `sieve_factory` signals that no more results can be created, returns `None`.
pub fn sieve_and_find<R, S, F>(
    rng: &mut R,
    sieve_factory: S,
    predicate: F,
    threadcount: usize,
) -> Result<Option<S::Item>, Error>
where
    R: CryptoRng + Clone + Send + Sync,
    S: Send + Sync + SieveFactory,
    S::Sieve: Send,
    S::Item: Send,
    F: Sync + Fn(&mut R, &S::Item) -> bool,
{
    let threadpool = rayon::ThreadPoolBuilder::new()
        .num_threads(threadcount)
        .build()
        .expect("If the platform can spawn threads, then this call will work.");

    let mut iter_rng = rng.clone();
    let iter = match SieveIterator::new(&mut iter_rng, sieve_factory)? {
        Some(iter) => iter,
        None => return Ok(None),
    };

    threadpool.install(|| {
        Ok(iter.par_bridge().find_any(|c| {
            let mut rng = rng.clone();
            predicate(&mut rng, c)
        }))
    })
}

/// A structure that chains the creation of sieves, returning the results from one until it is exhausted,
/// and then creating a new one.
#[derive(Debug)]
struct SieveIterator<'a, R: ?Sized, S: SieveFactory> {
    sieve_factory: S,
    sieve: S::Sieve,
    rng: &'a mut R,
}

impl<'a, R, S> SieveIterator<'a, R, S>
where
    R: CryptoRng + ?Sized,
    S: SieveFactory,
{
    /// Creates a new chained iterator producing results from sieves returned from `sieve_factory`.
    pub fn new(rng: &'a mut R, sieve_factory: S) -> Result<Option<Self>, Error> {
        let mut sieve_factory = sieve_factory;
        let sieve = match sieve_factory.make_sieve(rng, None)? {
            Some(sieve) => sieve,
            None => return Ok(None),
        };
        Ok(Some(Self {
            sieve_factory,
            rng,
            sieve,
        }))
    }
}

impl<R, S> Iterator for SieveIterator<'_, R, S>
where
    R: CryptoRng + ?Sized,
    S: SieveFactory,
{
    type Item = S::Item;

    fn next(&mut self) -> Option<Self::Item> {
        loop {
            if let Some(result) = self.sieve.next() {
                return Some(result);
            }

            self.sieve = self
                .sieve_factory
                .make_sieve(self.rng, Some(&self.sieve))
                .expect("the first attempt to make a sieve succeeded, so the next ones should too")?;
        }
    }
}

/// Returns a random prime of size `bit_length` using the provided RNG.
///
/// The returned prime will have its MSB set.
///
/// Uses `threadcount` cores to parallelize the prime search.
///
/// Panics if `bit_length` is less than the bit length of the smallest possible prime with the requested `flavor`.
///
/// Panics if the platform is unable to spawn threads.
pub fn random_prime<T, R>(rng: &mut R, flavor: Flavor, bit_length: u32, threadcount: usize) -> T
where
    T: Unsigned + RandomBits + RandomMod,
    R: CryptoRng + Send + Sync + Clone,
{
    let factory = SmallFactorsSieveFactory::new(flavor, bit_length, SetBits::Msb)
        .unwrap_or_else(|err| panic!("Error creating the sieve: {err}"));
    sieve_and_find(rng, factory, |_rng, candidate| is_prime(flavor, candidate), threadcount)
        .unwrap_or_else(|err| panic!("Error generating random candidates: {}", err))
        .expect("will produce a result eventually")
}

#[cfg(test)]
mod tests {
    use crypto_bigint::{BoxedUint, U128, nlimbs};
    use rand_core::{OsRng, TryRngCore};

    use super::{is_prime, random_prime};
    use crate::Flavor;

    #[test]
    fn parallel_prime_generation() {
        for bit_length in (28..=128).step_by(10) {
            let p: U128 = random_prime(&mut OsRng.unwrap_err(), Flavor::Any, bit_length, 4);
            assert!(p.bits_vartime() == bit_length);
            assert!(is_prime(Flavor::Any, &p));
        }
    }

    #[test]
    fn parallel_prime_generation_boxed() {
        for bit_length in (28..=128).step_by(10) {
            let p: BoxedUint = random_prime(&mut OsRng.unwrap_err(), Flavor::Any, bit_length, 2);
            assert!(p.bits_vartime() == bit_length);
            assert!(p.to_words().len() == nlimbs!(bit_length));
            assert!(is_prime(Flavor::Any, &p));
        }
    }

    #[test]
    fn parallel_safe_prime_generation() {
        for bit_length in (28..=128).step_by(10) {
            let p: U128 = random_prime(&mut OsRng.unwrap_err(), Flavor::Safe, bit_length, 8);
            assert!(p.bits_vartime() == bit_length);
            assert!(is_prime(Flavor::Safe, &p));
        }
    }

    #[test]
    fn parallel_safe_prime_generation_boxed() {
        for bit_length in (28..=128).step_by(10) {
            let p: BoxedUint = random_prime(&mut OsRng.unwrap_err(), Flavor::Safe, bit_length, 4);
            assert!(p.bits_vartime() == bit_length);
            assert!(p.to_words().len() == nlimbs!(bit_length));
            assert!(is_prime(Flavor::Safe, &p));
        }
    }
}
