use core::num::NonZero;
use crypto_bigint::{Limb, NonZero as CTNonZero, Unsigned, Word};

/// Calculates the greatest common divisor of `n` and `m`.
/// By definition, `gcd(0, m) == m`.
/// `n` must be non-zero.
pub(crate) fn gcd_vartime<T>(n: &T, m: NonZero<Word>) -> Word
where
    T: Unsigned,
{
    let m = m.get();
    // This we can check since it doesn't affect the return type,
    // even though `n` will not be 0 either in the application.
    if n.is_zero().into() {
        return m;
    }

    // Normalize input: the resulting (a, b) are both small, a >= b, and b != 0.
    let (a, b): (Word, Word) = if n.bits() > Word::BITS {
        // `m` is non-zero, so we can unwrap.
        let r = n.rem_limb(CTNonZero::new(Limb::from(m)).expect("divisor should be non-zero here"));
        (m, r.0)
    } else {
        // In this branch `n` is `Word::BITS` bits or shorter,
        // so we can safely take the first limb.
        let n = n.as_ref()[0].0;
        if n > m { (n, m) } else { (m, n) }
    };

    // Now do standard binary GCD on the two u64s
    binary_gcd(a, b)
}

// Binary GCD lifted verbatim from [1], minus the base checks.
// The identities mentioned in the comments are the following:
// 1. `gcd(n, 0) = n`: everything divides 0 and n is the largest number that divides n.
// 2. `gcd(2n, 2m) = 2*gcd(n, m)`: 2 is a common divisor
// 3. `gcd(n, 2m) = gcd(n, m)` if m is odd: 2 is then not a common divisor.
// 4. `gcd(n, m) = gcd(n, m - n)` if n, m odd and n <= m
//
// As GCD is commutative `gcd(n, m) = gcd(m, n)` those identities still apply if the operands are swapped.
//
// [1]: https://en.wikipedia.org/wiki/Binary_GCD_algorithm
fn binary_gcd(mut n: Word, mut m: Word) -> Word {
    // Using identities 2 and 3:
    // gcd(2ⁱn, 2ʲm) = 2ᵏ gcd(n, m) with n, m odd and k = min(i, j)
    // 2ᵏ is the greatest power of two that divides both 2ⁱn and 2ʲm
    let i = n.trailing_zeros();
    n >>= i;
    let j = m.trailing_zeros();
    m >>= j;
    let k = core::cmp::min(i, j);

    loop {
        // Swap if necessary so n ≤ m
        if n > m {
            core::mem::swap(&mut n, &mut m);
        }

        // Identity 4: gcd(n, m) = gcd(n, m-n) as n ≤ m and n, m are both odd
        m -= n;
        // m is now even

        if m == 0 {
            // Identity 1: gcd(n, 0) = n
            // The shift by k is necessary to add back the 2ᵏ factor that was removed before the loop
            return n << k;
        }

        // Identity 3: gcd(n, 2ʲ m) = gcd(n, m) as n is odd
        m >>= m.trailing_zeros();
    }
}

#[cfg(test)]
mod tests {
    use core::num::NonZero;
    use crypto_bigint::{U128, Word};
    use num_bigint::BigUint;
    use num_integer::Integer;
    use proptest::prelude::*;

    use super::gcd_vartime;

    #[test]
    fn corner_cases() {
        assert_eq!(gcd_vartime(&U128::from(0u64), NonZero::new(5).unwrap()), 5);
        assert_eq!(gcd_vartime(&U128::from(1u64), NonZero::new(11 * 13 * 19).unwrap()), 1);
        assert_eq!(gcd_vartime(&U128::from(7u64 * 11 * 13), NonZero::new(1).unwrap()), 1);
        assert_eq!(
            gcd_vartime(&U128::from(7u64 * 11 * 13), NonZero::new(11 * 13 * 19).unwrap()),
            11 * 13
        );
    }

    prop_compose! {
        fn uint()(bytes in any::<[u8; 16]>()) -> U128 {
            U128::from_le_slice(&bytes) | U128::ONE
        }
    }

    proptest! {
        #[test]
        fn fuzzy(m in any::<Word>(), n in uint()) {
            if m == 0 {
                return Ok(());
            }

            let m_bi = BigUint::from(m);
            let n_bi = BigUint::from_bytes_be(n.to_be_bytes().as_ref());
            let gcd_ref: Word = n_bi.gcd(&m_bi).try_into().unwrap();

            let gcd_test = gcd_vartime(&n, NonZero::new(m).unwrap());
            assert_eq!(gcd_test, gcd_ref);
        }
    }
}
