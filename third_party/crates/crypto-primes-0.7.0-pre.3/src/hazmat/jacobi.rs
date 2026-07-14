//! Jacobi symbol calculation.

pub(crate) use crypto_bigint::JacobiSymbol;

use crypto_bigint::{Limb, NonZero as CTNonZero, Odd, Unsigned, Word};

/// Transforms `(a/p)` -> `(r/p)` for odd `p`, where the resulting `r` is odd, and `a = r * 2^s`.
/// Takes a Jacobi symbol value, and returns `r` and the new Jacobi symbol,
/// negated if the transformation changes parity.
///
/// Note that the returned `r` is odd.
fn apply_reduce_numerator(j: JacobiSymbol, a: Word, p: Word) -> (JacobiSymbol, Word) {
    let p_mod_8 = p & 7;
    let s = a.trailing_zeros();
    let j = if (s & 1) == 1 && (p_mod_8 == 3 || p_mod_8 == 5) {
        -j
    } else {
        j
    };
    (j, a >> s)
}

fn reduce_numerator_long<T>(j: JacobiSymbol, a: Word, p: &T) -> (JacobiSymbol, Word)
where
    T: Unsigned,
{
    apply_reduce_numerator(j, a, p.as_ref()[0].0)
}

fn reduce_numerator_short(j: JacobiSymbol, a: Word, p: Word) -> (JacobiSymbol, Word) {
    apply_reduce_numerator(j, a, p)
}

/// Transforms `(a/p)` -> `(p/a)` for odd and coprime `a` and `p`.
/// Takes a Jacobi symbol value, and returns the swapped pair and the new Jacobi symbol,
/// negated if the transformation changes parity.
fn apply_swap(j: JacobiSymbol, a: Word, p: Word) -> JacobiSymbol {
    if a & 3 == 1 || p & 3 == 1 { j } else { -j }
}

fn swap_long<T: Unsigned>(j: JacobiSymbol, a: Word, p: &Odd<T>) -> (JacobiSymbol, &Odd<T>, Word) {
    let j = apply_swap(j, a, p.as_ref().as_ref()[0].0);
    (j, p, a)
}

fn swap_short(j: JacobiSymbol, a: Word, p: Word) -> (JacobiSymbol, Word, Word) {
    let j = apply_swap(j, a, p);
    (j, p, a)
}

/// Returns the Jacobi symbol `(a/p)` given an odd `p`.
pub(crate) fn jacobi_symbol_vartime<T>(abs_a: Word, a_is_negative: bool, p_long: &Odd<T>) -> JacobiSymbol
where
    T: Unsigned,
{
    let result = JacobiSymbol::One; // Keep track of all the sign flips here.

    // Deal with a negative `a` first:
    // (-a/n) = (-1/n) * (a/n)
    //        = (-1)^((n-1)/2) * (a/n)
    //        = (-1 if n = 3 mod 4 else 1) * (a/n)
    let result = if a_is_negative && p_long.as_ref().as_ref()[0].0 & 3 == 3 {
        -result
    } else {
        result
    };

    // A degenerate case.
    if abs_a == 1 || p_long.as_ref() == &T::one_like(p_long) {
        return result;
    }

    let a_limb = Limb::from(abs_a);

    // Normalize input: at the end we want `a < p`, `p` odd, and both fitting into a `Word`.
    let (result, a, p): (JacobiSymbol, Word, Word) = if p_long.bits_vartime() <= Limb::BITS {
        let a = a_limb.0;
        let p = p_long.as_ref().as_ref()[0].0;
        (result, a % p, p)
    } else {
        let (result, a) = reduce_numerator_long(result, a_limb.0, p_long.as_ref());
        if a == 1 {
            return result;
        }
        let (result, a_long, p) = swap_long(result, a, p_long);
        // Can unwrap here, since `p` is swapped with `a`,
        // and `a` would be odd after `reduce_numerator()`.
        let a = a_long.rem_limb(CTNonZero::new(Limb::from(p)).expect("divisor should be non-zero here"));
        (result, a.0, p)
    };

    let mut result = result;
    let mut a = a;
    let mut p = p;

    loop {
        if a == 0 {
            return JacobiSymbol::Zero;
        }

        // At this point `p` is odd (either coming from outside of the `loop`,
        // or from the previous iteration, where a previously reduced `a`
        // was swapped into its place), so we can call this.
        (result, a) = reduce_numerator_short(result, a, p);

        if a == 1 {
            return result;
        }

        // At this point both `a` and `p` are odd: `p` was odd before,
        // and `a` is odd after `reduce_numerator()`.
        // Note that technically `swap()` only returns a valid `result` if `a` and `p` are coprime.
        // But if they are not, we will return `Zero` eventually,
        // which is not affected by any sign changes.
        (result, a, p) = swap_short(result, a, p);

        a %= p;
    }
}

#[cfg(test)]
mod tests {

    use alloc::format;

    use crypto_bigint::{Odd, U128, Word};
    use num_bigint::{BigInt, Sign};
    use num_modular::ModularSymbols;
    use proptest::prelude::*;

    use super::{JacobiSymbol, jacobi_symbol_vartime};

    #[test]
    fn jacobi_symbol_derived_traits() {
        assert_eq!(format!("{:?}", JacobiSymbol::One), "One");
        assert_eq!(JacobiSymbol::One, JacobiSymbol::One);
        assert!(JacobiSymbol::One != JacobiSymbol::MinusOne);
        assert_eq!(JacobiSymbol::One.clone(), JacobiSymbol::One);
    }

    #[test]
    fn jacobi_symbol_neg_zero() {
        // This does not happen during normal operation, since we return zero as soon as we get it.
        // So just covering it for the completness' sake.
        assert_eq!(-JacobiSymbol::Zero, JacobiSymbol::Zero);
    }

    // Reference from `num-modular` - supports long `p`, but only positive `a`.
    fn jacobi_symbol_ref(a: Word, a_is_negative: bool, p: &U128) -> JacobiSymbol {
        let mut a_bi = BigInt::from(a);
        if a_is_negative {
            a_bi = -a_bi;
        }
        let p_bi = BigInt::from_bytes_be(Sign::Plus, p.to_be_bytes().as_ref());
        let j = a_bi.jacobi(&p_bi);
        if j == 1 {
            JacobiSymbol::One
        } else if j == -1 {
            JacobiSymbol::MinusOne
        } else {
            JacobiSymbol::Zero
        }
    }

    #[test]
    fn small_values() {
        // Test small values, using a reference implementation.
        for a in 0..31 {
            for a_is_negative in [true, false] {
                for p in (1u32..31).step_by(2) {
                    let p_long = Odd::new(U128::from(p)).unwrap();
                    let j_ref = jacobi_symbol_ref(a, a_is_negative, &p_long);
                    let j = jacobi_symbol_vartime(a, a_is_negative, &p_long);
                    assert_eq!(j, j_ref);
                }
            }
        }
    }

    #[test]
    fn big_values() {
        // a = x, p = x * y, where x and y are big primes. Should give 0.
        let a = 2147483647; // 2^31 - 1, a prime
        let p = Odd::new(U128::from_be_hex("000000007ffffffeffffffe28000003b")).unwrap(); // (2^31 - 1) * (2^64 - 59)
        assert_eq!(jacobi_symbol_vartime(a, false, &p), JacobiSymbol::Zero);
        assert_eq!(jacobi_symbol_ref(a, false, &p), JacobiSymbol::Zero);

        // a = x^2 mod p, should give 1.
        let a = 659456; // Obtained from x = 2^70
        let p = Odd::new(U128::from_be_hex("ffffffffffffffffffffffffffffff5f")).unwrap(); // 2^128 - 161 - not a prime
        assert_eq!(jacobi_symbol_vartime(a, false, &p), JacobiSymbol::One);
        assert_eq!(jacobi_symbol_ref(a, false, &p), JacobiSymbol::One);

        // -2^31
        let a = 2147483648;
        let a_is_negative = true;
        let p = Odd::new(U128::from_be_hex("000000007ffffffeffffffe28000003b")).unwrap(); // (2^31 - 1) * (2^64 - 59)
        assert_eq!(jacobi_symbol_vartime(a, a_is_negative, &p), JacobiSymbol::One);
        assert_eq!(jacobi_symbol_ref(a, a_is_negative, &p), JacobiSymbol::One);
    }

    prop_compose! {
        fn odd_uint()(bytes in any::<[u8; 16]>()) -> Odd<U128> {
            Odd::new(U128::from_le_slice(&bytes) | U128::ONE).unwrap()
        }
    }

    proptest! {
        #[test]
        fn fuzzy(abs_a in any::<Word>(), a_is_negative in any::<bool>(), p in odd_uint()) {
            let j_ref = jacobi_symbol_ref(abs_a, a_is_negative, &p);
            let j = jacobi_symbol_vartime(abs_a, a_is_negative, &p);
            assert_eq!(j, j_ref);
        }
    }
}
