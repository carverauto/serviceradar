//! Constant-time helpers.
// TODO(tarcieri): replace this with `crypto-bigint`?

use subtle::{Choice, ConditionallySelectable, ConstantTimeEq};

/// Count the number of leading zeros in constant-time.
#[inline]
pub(crate) fn leading_zeros(n: &[u8]) -> u32 {
    n[0].leading_zeros()
}

/// Constant-time bitwise right shift.
#[inline]
pub(crate) fn rshift(n: &mut [u8], shift: u32) {
    debug_assert!(shift < 8);
    let mask = (1 << shift) - 1;
    let mut carry = 0;

    for byte in n.iter_mut() {
        let new_carry = (*byte & mask) << (8 - shift);
        *byte = (*byte >> shift) | carry;
        carry = new_carry;
    }
}

/// Constant-time test that a given byte slice contains only zeroes.
#[inline]
pub(crate) fn is_zero(n: &[u8]) -> Choice {
    let mut ret = Choice::from(1);

    for byte in n {
        ret.conditional_assign(&Choice::from(0), byte.ct_ne(&0));
    }

    ret
}

/// Constant-time less than.
///
/// Inputs are interpreted as big endian integers.
#[inline]
pub(crate) fn lt(a: &[u8], b: &[u8]) -> Choice {
    debug_assert_eq!(a.len(), b.len());

    let mut borrow = 0;

    // Perform subtraction with borrow a byte-at-a-time, interpreting a
    // no-borrow condition as the less-than case
    for (&a, &b) in a.iter().zip(b.iter()).rev() {
        let c = (b as u16).wrapping_add(borrow >> (u8::BITS - 1));
        borrow = (a as u16).wrapping_sub(c) >> u8::BITS as u8;
    }

    !borrow.ct_eq(&0)
}

#[cfg(test)]
mod tests {
    const A: [u8; 4] = [0, 0, 0, 0];
    const B: [u8; 4] = [0, 0, 0, 1];
    const C: [u8; 4] = [0xFF, 0, 0, 0];
    const D: [u8; 4] = [0xFF, 0, 0, 1];
    const E: [u8; 4] = [0xFF, 0xFF, 0xFF, 0xFE];
    const F: [u8; 4] = [0xFF, 0xFF, 0xFF, 0xFF];

    #[test]
    fn ct_is_zero() {
        use super::is_zero;
        assert_eq!(is_zero(&A).unwrap_u8(), 1);
        assert_eq!(is_zero(&B).unwrap_u8(), 0);
    }

    #[test]
    fn ct_lt() {
        use super::lt;

        assert_eq!(lt(&A, &A).unwrap_u8(), 0);
        assert_eq!(lt(&B, &B).unwrap_u8(), 0);
        assert_eq!(lt(&C, &C).unwrap_u8(), 0);
        assert_eq!(lt(&D, &D).unwrap_u8(), 0);
        assert_eq!(lt(&E, &E).unwrap_u8(), 0);
        assert_eq!(lt(&F, &F).unwrap_u8(), 0);

        assert_eq!(lt(&A, &B).unwrap_u8(), 1);
        assert_eq!(lt(&A, &C).unwrap_u8(), 1);
        assert_eq!(lt(&B, &A).unwrap_u8(), 0);
        assert_eq!(lt(&C, &A).unwrap_u8(), 0);

        assert_eq!(lt(&B, &C).unwrap_u8(), 1);
        assert_eq!(lt(&B, &D).unwrap_u8(), 1);
        assert_eq!(lt(&C, &B).unwrap_u8(), 0);
        assert_eq!(lt(&D, &B).unwrap_u8(), 0);

        assert_eq!(lt(&C, &D).unwrap_u8(), 1);
        assert_eq!(lt(&C, &E).unwrap_u8(), 1);
        assert_eq!(lt(&D, &C).unwrap_u8(), 0);
        assert_eq!(lt(&E, &C).unwrap_u8(), 0);

        assert_eq!(lt(&E, &F).unwrap_u8(), 1);
        assert_eq!(lt(&F, &E).unwrap_u8(), 0);
    }
}
