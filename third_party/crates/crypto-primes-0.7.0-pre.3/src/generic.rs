use rand_core::CryptoRng;

use crate::{Error, hazmat::SieveFactory};

/// Sieves through the results of `sieve_factory` and returns the first item for which `predicate` is `true`.
///
/// If `sieve_factory` signals that no more results can be created, returns `None`.
pub fn sieve_and_find<R, S>(
    rng: &mut R,
    sieve_factory: S,
    predicate: impl Fn(&mut R, &S::Item) -> bool,
) -> Result<Option<S::Item>, Error>
where
    S: SieveFactory,
    R: CryptoRng + ?Sized,
{
    // We could use `SieveIterator` here, but it requires cloning the `rng`.
    // Unlike the parallel version, it is avoidable here.

    let mut sieve_factory = sieve_factory;
    let mut sieve = match sieve_factory.make_sieve(rng, None)? {
        Some(sieve) => sieve,
        None => return Ok(None),
    };

    loop {
        if let Some(value) = sieve.find(|num| predicate(rng, num)) {
            return Ok(Some(value));
        }
        if let Some(new_sieve) = sieve_factory.make_sieve(rng, Some(&sieve))? {
            sieve = new_sieve;
        } else {
            return Ok(None);
        }
    }
}

#[cfg(test)]
mod tests {
    use rand_core::{CryptoRng, OsRng, TryRngCore};

    use super::sieve_and_find;
    use crate::{Error, hazmat::SieveFactory};

    #[test]
    fn test_exhaustable_sieve_factory() {
        // Test the logic handling the case of the sieve factory not being able to produce new sieves.
        struct TestSieveFactory {
            count: usize,
        }

        impl SieveFactory for TestSieveFactory {
            type Item = usize;
            type Sieve = core::ops::Range<usize>;

            fn make_sieve<R: CryptoRng + ?Sized>(
                &mut self,
                _rng: &mut R,
                previous_sieve: Option<&Self::Sieve>,
            ) -> Result<Option<Self::Sieve>, Error> {
                self.count += 1;
                if previous_sieve.is_none() {
                    Ok(Some(self.count * 10..(self.count * 10 + 2)))
                } else {
                    Ok(None)
                }
            }
        }

        let factory = TestSieveFactory { count: 0 };
        let result = sieve_and_find(&mut OsRng.unwrap_mut(), factory, |_rng, num| *num == 11);
        assert!(result.unwrap().is_some());

        let factory = TestSieveFactory { count: 0 };
        let result = sieve_and_find(&mut OsRng.unwrap_mut(), factory, |_rng, num| *num == 20);
        assert!(result.unwrap().is_none());
    }
}
