/// Constructing a compact representation of a [`Uint`]
use crate::{Limb, Uint};

impl<const LIMBS: usize> Uint<LIMBS> {
    /// Construct a [Uint] containing the bits in `self` in the range `[idx, idx + length)`.
    ///
    /// Assumes `length ≤ Uint::<SECTION_LIMBS>::BITS` and `idx + length ≤ Self::BITS`.
    ///
    /// Executes in time variable in `length` only.
    #[inline(always)]
    pub(super) const fn section_vartime_length<const SECTION_LIMBS: usize>(
        &self,
        idx: u32,
        length: u32,
    ) -> Uint<SECTION_LIMBS> {
        debug_assert!(length <= Uint::<SECTION_LIMBS>::BITS);
        debug_assert!(idx + length <= Self::BITS);

        let mask = Uint::ONE.shl_vartime(length).wrapping_sub(&Uint::ONE);
        if LIMBS > SECTION_LIMBS {
            let (shr_limbs, shr_bits) = (idx / Limb::BITS, idx % Limb::BITS);
            // shift into the lower SECTION_LIMBS+1 limbs
            let buf = self.wrapping_shr_by_limbs(shr_limbs);
            // shift the lower SECTION_LIMBS limbs by the remaining bits and carry the high bits
            let (mut lo, hi) = (
                buf.resize::<SECTION_LIMBS>().shr_limb(shr_bits).0,
                buf.limbs[SECTION_LIMBS],
            );
            lo.limbs[SECTION_LIMBS - 1] = lo.limbs[SECTION_LIMBS - 1].bitor(hi.shr(shr_bits));
            lo.bitand(&mask)
        } else {
            self.shr(idx).resize::<SECTION_LIMBS>().bitand(&mask)
        }
    }

    /// Construct a [Uint] containing the bits in `self` in the range `[idx, idx + length)`.
    ///
    /// Assumes `length ≤ Uint::<SECTION_LIMBS>::BITS` and `idx + length ≤ Self::BITS`.
    ///
    /// Executes in time variable in `idx` and `length`.
    #[inline(always)]
    pub(super) const fn section_vartime<const SECTION_LIMBS: usize>(
        &self,
        idx: u32,
        length: u32,
    ) -> Uint<SECTION_LIMBS> {
        debug_assert!(length <= Uint::<SECTION_LIMBS>::BITS);
        debug_assert!(idx + length <= Self::BITS);

        let mask = Uint::ONE.shl_vartime(length).wrapping_sub(&Uint::ONE);
        self.shr_vartime(idx)
            .resize::<SECTION_LIMBS>()
            .bitand(&mask)
    }

    /// Compact `self` to a form containing the concatenation of its bit ranges `[0, K)`
    /// and `[n-K, n)`.
    ///
    /// Assumes `K ≤ Uint::<SUMMARY_LIMBS>::BITS`, `n ≤ Self::BITS` and `n ≥ 2K`.
    #[inline(always)]
    pub(super) const fn compact<const K: u32, const SUMMARY_LIMBS: usize>(
        &self,
        n: u32,
    ) -> Uint<SUMMARY_LIMBS> {
        debug_assert!(K <= Uint::<SUMMARY_LIMBS>::BITS);
        debug_assert!(n <= Self::BITS);
        debug_assert!(n >= 2 * K);

        // safe to vartime; this function is vartime in length only, which is a public constant
        let hi = self.section_vartime_length(n - K, K);
        // safe to vartime; this function is vartime in idx and length only, which are both public
        // constants
        let lo = self.section_vartime(0, K);
        // safe to vartime; shl_vartime is variable in the value of shift only. Since this shift
        // is a public constant, the constant time property of this algorithm is not impacted.
        hi.shl_vartime(K).bitxor(&lo)
    }

    /// Vartime equivalent of [`Self::compact`].
    #[inline(always)]
    pub(crate) const fn compact_vartime<const K: u32, const SUMMARY_LIMBS: usize>(
        &self,
        n: u32,
    ) -> Uint<SUMMARY_LIMBS> {
        debug_assert!(K <= Uint::<SUMMARY_LIMBS>::BITS);
        debug_assert!(n <= Self::BITS);
        debug_assert!(n >= 2 * K);

        // safe to vartime; this function is vartime in length only, which is a public constant
        let hi = self.section_vartime(n - K, K);
        // safe to vartime; this function is vartime in idx and length only, which are both public
        // constants
        let lo = self.section_vartime(0, K);
        // safe to vartime; shl_vartime is variable in the value of shift only. Since this shift
        // is a public constant, the constant time property of this algorithm is not impacted.
        hi.shl_vartime(K).bitxor(&lo)
    }
}

#[cfg(test)]
mod tests {
    use crate::{U128, U256};

    #[test]
    fn test_compact() {
        let val =
            U256::from_be_hex("CFCF1535CEBE19BBF289933AB8645189397450A32BFEC57579FB7EB14E27D101");
        let target = U128::from_be_hex("BBF289933AB8645179FB7EB14E27D101");

        let compact = val.compact::<64, { U128::LIMBS }>(200);
        assert_eq!(compact, target);
    }

    #[test]
    fn test_compact_vartime() {
        let val =
            U256::from_be_hex("1971BC6285D8CBA9640AA3B3B9C01EF4186D1EBE9A17393A9E43586E0EBAED5B");
        let target = U128::from_be_hex("A9640AA3B3B9C01E9E43586E0EBAED5B");

        let compact = val.compact_vartime::<64, { U128::LIMBS }>(200);
        assert_eq!(compact, target);
    }
}
