//! Internal module that provides the folded multiply.

/// 64*64 to 128 bit multiply
///
/// Returns the (low, high) 64 bits of the 128 bit result.
///
/// # From the C code:
/// Calculates 128-bit C = *A * *B.
///
/// When RAPIDHASH_FAST is defined:
/// Overwrites A contents with C's low 64 bits.
/// Overwrites B contents with C's high 64 bits.
///
/// When RAPIDHASH_PROTECTED is defined:
/// Xors and overwrites A contents with C's low 64 bits.
/// Xors and overwrites B contents with C's high 64 bits.
#[inline(always)]
#[must_use]
pub(crate) const fn rapid_mum<const PROTECTED: bool>(a: u64, b: u64) -> (u64, u64) {
    let r = (a as u128).wrapping_mul(b as u128);

    if !PROTECTED {
        (r as u64, (r >> 64) as u64)
    } else {
        (a ^ r as u64, b ^ (r >> 64) as u64)
    }
}

/// Folded 64-bit multiply. [rapid_mum] then XOR the results together.
#[inline(always)]
#[must_use]
pub(crate) const fn rapid_mix<const PROTECTED: bool>(a: u64, b: u64) -> u64 {
    let r = (a as u128).wrapping_mul(b as u128);

    if !PROTECTED {
        (r as u64) ^ (r >> 64) as u64
    } else {
        (a ^ r as u64) ^ (b ^ (r >> 64) as u64)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_rapid_mum() {
        let (a, b) = rapid_mum::<false>(0, 0);
        assert_eq!(a, 0);
        assert_eq!(b, 0);

        let (a, b) = rapid_mum::<false>(100, 100);
        assert_eq!(a, 10000);
        assert_eq!(b, 0);

        let (a, b) = rapid_mum::<false>(u64::MAX, 2);
        assert_eq!(a, u64::MAX - 1);
        assert_eq!(b, 1);
    }
}
