//! An iterator for weeding out multiples of small primes,
//! before proceeding with slower tests.

use alloc::{vec, vec::Vec};
use core::marker::PhantomData;
use core::num::{NonZero, NonZeroU32};

use crypto_bigint::{Odd, RandomBits, RandomBitsError, Unsigned};
use rand_core::CryptoRng;

use super::precomputed::{LAST_SMALL_PRIME, RECIPROCALS, SMALL_PRIMES, SmallPrime};
use crate::{error::Error, presets::Flavor};

/// Decide how prime candidates are manipulated by setting certain bits before primality testing,
/// influencing the range of the prime.
#[derive(Debug, Clone, Copy)]
pub enum SetBits {
    /// Set the most significant bit, thus limiting the range to `[MAX/2 + 1, MAX]`.
    ///
    /// In other words, all candidates will have the same bit size.
    Msb,
    /// Set two most significant bits, limiting the range to `[MAX - MAX/4 + 1, MAX]`.
    ///
    /// This is useful in the RSA case because a product of two such numbers will have a guaranteed bit size.
    TwoMsb,
    /// No additional bits set; uses the full range `[1, MAX]`.
    None,
}

/// Returns a random odd integer up to the given bit length.
///
/// The `set_bits` parameter decides which extra bits are set, which decides the range of the number.
///
/// Returns an error variant if `bit_length` is greater than the maximum allowed for `T`
/// (applies to fixed-length types).
pub fn random_odd_integer<T, R>(rng: &mut R, bit_length: NonZeroU32, set_bits: SetBits) -> Result<Odd<T>, Error>
where
    T: Unsigned + RandomBits,
    R: CryptoRng + ?Sized,
{
    let bit_length = bit_length.get();

    let mut random = T::try_random_bits(rng, bit_length).map_err(|err| match err {
        RandomBitsError::RandCore(_) => unreachable!("`rng` impls `CryptoRng` and therefore is infallible"),
        RandomBitsError::BitsPrecisionMismatch { .. } => {
            unreachable!("we are not requesting a specific `bits_precision`")
        }
        RandomBitsError::BitLengthTooLarge {
            bit_length,
            bits_precision,
        } => Error::BitLengthTooLarge {
            bit_length,
            bits_precision,
        },
    })?;

    // Make it odd
    // `bit_length` is non-zero, so the 0-th bit exists.
    random.set_bit_vartime(0, true);

    // Will not overflow since `bit_length` is ensured to be within the size of the integer
    // (checked within the `T::try_random_bits()` call).
    // `bit_length - 1`-th bit exists since `bit_length` is non-zero.
    match set_bits {
        SetBits::None => {}
        SetBits::Msb => random.set_bit_vartime(bit_length - 1, true),
        SetBits::TwoMsb => {
            random.set_bit_vartime(bit_length - 1, true);
            // We could panic here, but since the primary purpose of `TwoMsb` is to ensure the bit length
            // of the product of two numbers, ignoring this for `bit_length = 1` leads to the desired result.
            if bit_length > 1 {
                random.set_bit_vartime(bit_length - 2, true);
            }
        }
    }

    Ok(Odd::new(random).expect("the number is odd by construction"))
}

// The type we use to calculate incremental residues.
// Should be >= `SmallPrime` in size.
type Residue = u32;

// The maximum increment that won't overflow the type we use to calculate residues of increments:
// we need `(max_prime - 1) + max_incr <= Type::MAX`.
const INCR_LIMIT: Residue = Residue::MAX - LAST_SMALL_PRIME as Residue + 1;

/// An iterator returning numbers with up to and including given bit length,
/// starting from a given number, that are not multiples of the first 2048 small primes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SmallFactorsSieve<T: Unsigned> {
    // Instead of dividing a big integer by small primes every time (which is slow),
    // we keep a "base" and a small increment separately,
    // so that we can only calculate the residues of the increment.
    base: T,
    incr: Residue,
    incr_limit: Residue,
    safe_primes: bool,
    residues: Vec<SmallPrime>,
    max_bit_length: u32,
    produces_nothing: bool,
    starts_from_exception: bool,
    last_round: bool,
}

impl<T> SmallFactorsSieve<T>
where
    T: Unsigned,
{
    /// Creates a new sieve, iterating from `start` and until the last number with `max_bit_length`
    /// bits, producing numbers that are not non-trivial multiples of a list of small primes in the
    /// range `[2, start)` (`safe_primes = false`) or `[2, start/2)` (`safe_primes = true`).
    ///
    /// Note that `start` is adjusted to `2`, or the next `1 mod 2` number (`safe_primes = false`);
    /// and `5`, or `3 mod 4` number (`safe_primes = true`).
    ///
    /// Panics if `max_bit_length` greater than the precision of `start`.
    ///
    /// If `safe_primes` is `true`, both the returned `n` and `n/2` are sieved.
    pub fn new(start: T, max_bit_length: NonZeroU32, safe_primes: bool) -> Result<Self, Error> {
        let max_bit_length = max_bit_length.get();

        if max_bit_length > start.bits_precision() {
            return Err(Error::BitLengthTooLarge {
                bit_length: max_bit_length,
                bits_precision: start.bits_precision(),
            });
        }

        // If we are targeting safe primes, iterate over the corresponding
        // possible Germain primes (`n/2`), reducing the task to that with `safe_primes = false`.
        let (max_bit_length, mut start) = if safe_primes {
            (max_bit_length - 1, start.wrapping_shr_vartime(1))
        } else {
            (max_bit_length, start)
        };

        // This is easier than making all the methods generic enough to handle these corner cases.
        let produces_nothing = max_bit_length < start.bits_vartime() || max_bit_length < 2;

        // Add the exception to the produced candidates - the only one that doesn't fit
        // the general pattern of incrementing the base by 2.
        let mut starts_from_exception = false;
        if start <= T::from(2u32) {
            starts_from_exception = true;
            start = T::from(3u32);
        } else {
            // Adjust the start so that we hit odd numbers when incrementing it by 2.
            start |= T::one();
        }

        // Only calculate residues by primes up to and not including `start`, because when we only
        // have the resiude, we cannot distinguish between a prime itself and a multiple of that
        // prime.
        let residues_len = if T::from(LAST_SMALL_PRIME) <= start {
            SMALL_PRIMES.len()
        } else {
            // `start` is smaller than the last prime in the list so casting `start` to a `u16` is
            // safe. We need to find out how many residues we can use.
            let start_small = start.as_ref()[0].0 as SmallPrime;
            SMALL_PRIMES.partition_point(|x| *x < start_small)
        };

        Ok(Self {
            base: start,
            incr: 0, // This will ensure that `update_residues()` is called right away.
            incr_limit: 0,
            safe_primes,
            residues: vec![0; residues_len],
            max_bit_length,
            produces_nothing,
            starts_from_exception,
            last_round: false,
        })
    }

    fn update_residues(&mut self) -> bool {
        if self.incr_limit != 0 && self.incr <= self.incr_limit {
            return true;
        }

        if self.last_round {
            return false;
        }

        // Set the new base.
        // Should not overflow since `incr` is never greater than `incr_limit`,
        // and the latter is chosen such that it doesn't overflow when added to `base`
        // (see the rest of this method).
        self.base = self
            .base
            .checked_add(&self.incr.into())
            .expect("Does not overflow by construction");

        self.incr = 0;

        // Re-calculate residues. This is taking up most of the sieving time.
        for (i, rec) in RECIPROCALS.iter().enumerate().take(self.residues.len()) {
            let rem = self.base.rem_limb_with_reciprocal(rec);
            self.residues[i] = rem.0 as SmallPrime;
        }

        // Find the increment limit.
        let max_value = match T::one_like(&self.base)
            .overflowing_shl_vartime(self.max_bit_length)
            .into()
        {
            Some(val) => val,
            None => T::one_like(&self.base),
        };
        let incr_limit = max_value.wrapping_sub(&self.base);
        self.incr_limit = if incr_limit > T::from(INCR_LIMIT) {
            INCR_LIMIT
        } else {
            // We are close to `2^max_bit_length - 1`.
            // Mark this round as the last.
            self.last_round = true;
            // Can unwrap here since we just checked above that `incr_limit <= INCR_LIMIT`,
            // and `INCR_LIMIT` fits into `Residue`.
            let incr_limit_small: Residue = incr_limit.as_ref()[0]
                .0
                .try_into()
                .expect("the increment limit should fit within `Residue`");
            incr_limit_small
        };

        true
    }

    // Returns `true` if the current `base + incr` is divisible by any of the small primes.
    fn current_is_composite(&self) -> bool {
        self.residues.iter().enumerate().any(|(i, m)| {
            let d = SMALL_PRIMES[i] as Residue;
            let r = (*m as Residue + self.incr) % d;

            // A trick from "Safe Prime Generation with a Combined Sieve" by Michael J. Wiener
            // (https://eprint.iacr.org/2003/186).
            // Remember that the check above was for the `(n - 1)/2`;
            // If `(n - 1)/2 mod d == (d - 1)/2`, it means that `n mod d == 0`.
            // In other words, we are checking the remainder of `n mod d`
            // for virtually no additional cost.
            r == 0 || (self.safe_primes && r == (d - 1) >> 1)
        })
    }

    // Returns the restored `base + incr` if it is not composite (wrt the small primes),
    // and bumps the increment unconditionally.
    fn maybe_next(&mut self) -> Option<T> {
        let result = if self.current_is_composite() {
            None
        } else {
            match self.base.checked_add(&self.incr.into()).into_option() {
                Some(mut num) => {
                    if self.safe_primes {
                        // Divide by 2 and ensure it's odd with an OR.
                        num = num.wrapping_shl_vartime(1) | T::one_like(&self.base);
                    }
                    Some(num)
                }
                None => None,
            }
        };

        self.incr += 2;
        result
    }

    fn next(&mut self) -> Option<T> {
        // Corner cases handled here
        if self.produces_nothing {
            return None;
        }

        if self.starts_from_exception {
            self.starts_from_exception = false;
            return Some(T::from(if self.safe_primes { 5u32 } else { 2u32 }));
        }

        // Main loop

        while self.update_residues() {
            match self.maybe_next() {
                Some(x) => return Some(x),
                None => continue,
            };
        }
        None
    }
}

impl<T> Iterator for SmallFactorsSieve<T>
where
    T: Unsigned,
{
    type Item = T;

    fn next(&mut self) -> Option<Self::Item> {
        Self::next(self)
    }
}

/// A type producing sieves for random prime generation.
pub trait SieveFactory {
    /// The type of items returning by the sieves.
    type Item;

    /// The resulting sieve.
    type Sieve: Iterator<Item = Self::Item>;

    /// Makes a sieve given an RNG and the previous exhausted sieve (if any).
    ///
    /// Returning `None` signals that the prime generation should stop.
    fn make_sieve<R>(
        &mut self,
        rng: &mut R,
        previous_sieve: Option<&Self::Sieve>,
    ) -> Result<Option<Self::Sieve>, Error>
    where
        R: CryptoRng + ?Sized;
}

/// A sieve returning numbers that are not multiples of a set of small factors.
#[derive(Debug, Clone, Copy)]
pub struct SmallFactorsSieveFactory<T> {
    max_bit_length: NonZeroU32,
    safe_primes: bool,
    set_bits: SetBits,
    phantom: PhantomData<T>,
}

impl<T> SmallFactorsSieveFactory<T>
where
    T: Unsigned + RandomBits,
{
    /// Creates a factory that produces sieves returning numbers of at most `max_bit_length` bits
    /// that are not divisible by a number of small factors.
    ///
    /// Some bits may be guaranteed to set depending on the requested `set_bits`.
    ///
    /// Depending on the requested `flavor`, additional filters may be applied.
    pub fn new(flavor: Flavor, max_bit_length: u32, set_bits: SetBits) -> Result<Self, Error> {
        match flavor {
            Flavor::Any => {
                if max_bit_length < 2 {
                    return Err(Error::BitLengthTooSmall {
                        bit_length: max_bit_length,
                        flavor,
                    });
                }
            }
            Flavor::Safe => {
                if max_bit_length < 3 {
                    return Err(Error::BitLengthTooSmall {
                        bit_length: max_bit_length,
                        flavor,
                    });
                }
            }
        }
        let max_bit_length = NonZero::new(max_bit_length).expect("`bit_length` should be non-zero");
        Ok(Self {
            max_bit_length,
            safe_primes: match flavor {
                Flavor::Any => false,
                Flavor::Safe => true,
            },
            set_bits,
            phantom: PhantomData,
        })
    }
}

impl<T> SieveFactory for SmallFactorsSieveFactory<T>
where
    T: Unsigned + RandomBits,
{
    type Item = T;
    type Sieve = SmallFactorsSieve<T>;
    fn make_sieve<R>(
        &mut self,
        rng: &mut R,
        _previous_sieve: Option<&Self::Sieve>,
    ) -> Result<Option<Self::Sieve>, Error>
    where
        R: CryptoRng + ?Sized,
    {
        let start = random_odd_integer::<T, _>(rng, self.max_bit_length, self.set_bits)?;
        Ok(Some(SmallFactorsSieve::new(
            start.get(),
            self.max_bit_length,
            self.safe_primes,
        )?))
    }
}

#[cfg(test)]
mod tests {

    use alloc::format;
    use alloc::vec::Vec;
    use core::num::NonZero;

    use crypto_bigint::{U64, U256};
    use num_prime::nt_funcs::factorize64;
    use rand_chacha::ChaCha8Rng;
    use rand_core::{OsRng, SeedableRng, TryRngCore};

    use super::{SetBits, SmallFactorsSieve, SmallFactorsSieveFactory, random_odd_integer};
    use crate::{Error, Flavor, hazmat::precomputed::SMALL_PRIMES};

    #[test]
    fn random() {
        let max_prime = SMALL_PRIMES[SMALL_PRIMES.len() - 1];

        let mut rng = ChaCha8Rng::from_seed(*b"01234567890123456789012345678901");
        let start = random_odd_integer::<U64, _>(&mut rng, NonZero::new(32).unwrap(), SetBits::Msb)
            .unwrap()
            .get();
        for num in SmallFactorsSieve::new(start, NonZero::new(32).unwrap(), false)
            .unwrap()
            .take(100)
        {
            let num_u64 = u64::from(num);
            assert!(num_u64.leading_zeros() == 32);

            let factors_and_powers = factorize64(num_u64);
            let factors = factors_and_powers.into_keys().collect::<Vec<_>>();

            assert!(factors[0] > max_prime as u64);
        }
    }
    #[test]
    fn random_boxed() {
        let max_prime = SMALL_PRIMES[SMALL_PRIMES.len() - 1];

        let mut rng = ChaCha8Rng::from_seed(*b"01234567890123456789012345678901");
        let start =
            random_odd_integer::<crypto_bigint::BoxedUint, _>(&mut rng, NonZero::new(32).unwrap(), SetBits::Msb)
                .unwrap()
                .get();

        for num in SmallFactorsSieve::new(start, NonZero::new(32).unwrap(), false)
            .unwrap()
            .take(100)
        {
            // For 32-bit targets
            #[allow(clippy::useless_conversion)]
            let num_u64: u64 = num.as_words()[0].into();
            assert!(num_u64.leading_zeros() == 32);

            let factors_and_powers = factorize64(num_u64);
            let factors = factors_and_powers.into_keys().collect::<Vec<_>>();

            assert!(factors[0] > max_prime as u64);
        }
    }

    fn check_sieve(start: u32, bit_length: u32, safe_prime: bool, reference: &[u32]) {
        let test = SmallFactorsSieve::new(U64::from(start), NonZero::new(bit_length).unwrap(), safe_prime)
            .unwrap()
            .collect::<Vec<_>>();
        assert_eq!(test.len(), reference.len());
        for (x, y) in test.iter().zip(reference.iter()) {
            assert_eq!(x, &U64::from(*y));
        }
    }

    #[test]
    fn empty_sequence() {
        check_sieve(1, 1, false, &[]); // no primes of 1 bits
        check_sieve(1, 2, true, &[]); // no safe primes of 2 bits
        check_sieve(64, 6, true, &[]); // 64 is 7 bits long
    }

    #[test]
    fn small_range() {
        check_sieve(1, 2, false, &[2, 3]);
        check_sieve(2, 2, false, &[2, 3]);
        check_sieve(3, 2, false, &[3]);

        check_sieve(1, 3, false, &[2, 3, 5, 7]);
        check_sieve(3, 3, false, &[3, 5, 7]);
        check_sieve(5, 3, false, &[5, 7]);
        check_sieve(7, 3, false, &[7]);

        check_sieve(1, 4, false, &[2, 3, 5, 7, 9, 11, 13, 15]);
        check_sieve(3, 4, false, &[3, 5, 7, 9, 11, 13, 15]);
        check_sieve(5, 4, false, &[5, 7, 11, 13]);
        check_sieve(7, 4, false, &[7, 11, 13]);
        check_sieve(9, 4, false, &[11, 13]);
        check_sieve(13, 4, false, &[13]);
        check_sieve(15, 4, false, &[]);

        check_sieve(1, 3, true, &[5, 7]);
        check_sieve(3, 3, true, &[5, 7]);
        check_sieve(5, 3, true, &[5, 7]);
        check_sieve(7, 3, true, &[7]);

        // In the following three cases, the "half-start" would be set to 3,
        // and since every small divisor equal or greater than the start is not tested
        // (because we can't distinguish between the remainder being 0
        // and the number being actually equal to the divisor),
        // no divisors will actually be tested at all, so 15 (a composite)
        // is included in the output.
        check_sieve(1, 4, true, &[5, 7, 11, 15]);
        check_sieve(5, 4, true, &[5, 7, 11, 15]);
        check_sieve(7, 4, true, &[7, 11, 15]);

        check_sieve(9, 4, true, &[11]);
        check_sieve(13, 4, true, &[]);
    }

    #[test]
    fn sieve_too_many_bits() {
        assert_eq!(
            SmallFactorsSieve::new(U64::ONE, NonZero::new(65).unwrap(), false).unwrap_err(),
            Error::BitLengthTooLarge {
                bit_length: 65,
                bits_precision: 64
            }
        );
    }

    #[test]
    fn random_below_max_length() {
        for _ in 0..10 {
            let r = random_odd_integer::<U64, _>(&mut OsRng.unwrap_mut(), NonZero::new(50).unwrap(), SetBits::Msb)
                .unwrap()
                .get();
            assert_eq!(r.bits(), 50);
        }
    }

    #[test]
    fn random_odd_uint_too_many_bits() {
        assert!(
            random_odd_integer::<U64, _>(&mut OsRng.unwrap_mut(), NonZero::new(65).unwrap(), SetBits::Msb).is_err()
        );
    }

    #[test]
    fn sieve_derived_traits() {
        let s = SmallFactorsSieve::new(U64::ONE, NonZero::new(10).unwrap(), false).unwrap();
        // Debug
        assert!(format!("{s:?}").starts_with("SmallFactorsSieve"));
        // Clone
        assert_eq!(s.clone(), s);

        // PartialEq
        let s2 = SmallFactorsSieve::new(U64::ONE, NonZero::new(10).unwrap(), false).unwrap();
        assert_eq!(s, s2);
        let s3 = SmallFactorsSieve::new(U64::ONE, NonZero::new(12).unwrap(), false).unwrap();
        assert_ne!(s, s3);
    }

    #[test]
    fn sieve_with_max_start() {
        let start = U64::MAX;
        let mut sieve = SmallFactorsSieve::new(start, NonZero::new(U64::BITS).unwrap(), false).unwrap();
        assert!(sieve.next().is_none());
    }

    #[test]
    fn too_few_bits_regular_primes() {
        assert_eq!(
            SmallFactorsSieveFactory::<U64>::new(Flavor::Any, 1, SetBits::Msb).unwrap_err(),
            Error::BitLengthTooSmall {
                bit_length: 1,
                flavor: Flavor::Any
            }
        );
    }

    #[test]
    fn too_few_bits_safe_primes() {
        assert_eq!(
            SmallFactorsSieveFactory::<U64>::new(Flavor::Safe, 2, SetBits::Msb).unwrap_err(),
            Error::BitLengthTooSmall {
                bit_length: 2,
                flavor: Flavor::Safe
            }
        );
    }

    #[test]
    fn set_bits() {
        for _ in 0..10 {
            let x =
                random_odd_integer::<U64, _>(&mut OsRng.unwrap_mut(), NonZero::new(64).unwrap(), SetBits::Msb).unwrap();
            assert!(bool::from(x.bit(63)));
        }

        for _ in 0..10 {
            let x = random_odd_integer::<U64, _>(&mut OsRng.unwrap_mut(), NonZero::new(64).unwrap(), SetBits::TwoMsb)
                .unwrap();
            assert!(bool::from(x.bit(63)));
            assert!(bool::from(x.bit(62)));
        }

        // 1 in 2^30 chance of spurious failure... good enough?
        assert!(
            (0..30)
                .map(|_| {
                    random_odd_integer::<U64, _>(&mut OsRng.unwrap_mut(), NonZero::new(64).unwrap(), SetBits::None)
                        .unwrap()
                })
                .any(|x| !bool::from(x.bit(63)))
        );
    }

    #[test]
    fn set_two_msb_small_bit_length() {
        // Check that when technically there isn't a second most significant bit,
        // `random_odd_integer()` still returns a number.
        let x = random_odd_integer::<U64, _>(&mut OsRng.unwrap_mut(), NonZero::new(1).unwrap(), SetBits::TwoMsb)
            .unwrap()
            .get();
        assert_eq!(x, U64::ONE);
    }

    #[test]
    fn platform_independence() {
        let mut rng = ChaCha8Rng::from_seed([7u8; 32]);

        let x = random_odd_integer::<U256, _>(&mut rng, NonZero::new(200).unwrap(), SetBits::TwoMsb)
            .unwrap()
            .get();
        assert_eq!(
            x,
            U256::from_be_hex("00000000000000E94A74F9D90C0982D7D4F5378BDA8143E6391EBC3F59CBD0E5")
        );

        let x = random_odd_integer::<U256, _>(&mut rng, NonZero::new(220).unwrap(), SetBits::TwoMsb)
            .unwrap()
            .get();
        assert_eq!(
            x,
            U256::from_be_hex("000000000E28CE6059E357411C67F6539AEF56F2B4653F0583D6A2195A9897BB")
        );
    }
}
