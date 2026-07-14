//! Compute `x / 2^k mod q` for some prime `q`.
use crate::const_choice::u32_min;
use crate::{ConstChoice, Limb, Odd, OddUint, Uint};

impl<const LIMBS: usize> Uint<LIMBS> {
    /// Compute `self / 2^k mod q`.
    ///
    /// Requires that `k_bound ≥ k`.
    ///
    /// Executes in variable time w.r.t. `k_bound` only; executes in constant time w.r.t. `k`.
    #[inline]
    pub(super) const fn bounded_div2k_mod_q(
        self,
        k: u32,
        k_upper_bound: u32,
        q: &Odd<Self>,
    ) -> Self {
        let one_half_mod_q = OddUint::half_mod(q).0;

        // Invariant: x = self / 2^e mod q.
        let (mut x, mut e) = (self, 0);

        let max_iters_per_round = Limb::BITS - 1;
        let rounds = k_upper_bound.div_ceil(max_iters_per_round);

        let mut r = 0;
        while r < rounds {
            let f_upper_bound =
                u32_min(k_upper_bound - r * max_iters_per_round, max_iters_per_round);
            let f = u32_min(k - e, f_upper_bound);

            // Find `s` s.t. qs + x = 0 mod 2^f
            let (_, s) = x.limbs[0].bounded_div2k_mod_q(f, f_upper_bound, one_half_mod_q.limbs[0]);

            // Set x <- (x + qs) / 2^f
            x = q.mul_add_div2k(s, &x, f);
            e += f;

            r += 1;
        }

        x
    }

    /// Computes `(self * b) + addend + carry`, returning the result along with the new carry.
    #[inline]
    const fn carrying_mul_add_limb(
        mut self,
        b: Limb,
        addend: &Self,
        mut carry: Limb,
    ) -> (Self, Limb) {
        let mut i = 0;
        while i < LIMBS {
            (self.limbs[i], carry) = self.limbs[i].carrying_mul_add(b, addend.limbs[i], carry);
            i += 1;
        }
        (self, carry)
    }
}

impl Limb {
    /// Compute `self / 2^t mod q`, returning the result, as well as the minimal factor `f` such
    /// that `2^t` divides `self + q·f`.
    ///
    /// Here, `q := 2·one_half_mod_q + 1` is assumed odd and `t := min(k, k_upper_bound)`.
    ///
    /// Executes in variable time w.r.t. `k_upper_bound` only; executes in constant time w.r.t `k`.
    const fn bounded_div2k_mod_q(
        mut self,
        k: u32,
        k_upper_bound: u32,
        one_half_mod_q: Self,
    ) -> (Self, Self) {
        let mut factor = Limb::ZERO;
        let mut i = 0;
        while i < k_upper_bound {
            let execute = ConstChoice::from_u32_lt(i, k);

            let (shifted, carry) = self.shr1();
            self = Self::select(self, shifted, execute);

            let overflow = ConstChoice::from_word_msb(carry.0);
            let add_back_q = overflow.and(execute);
            self = self.wrapping_add(Self::select(Self::ZERO, one_half_mod_q, add_back_q));
            factor = factor.bitxor(Self::select(Self::ZERO, Self::ONE.shl(i), add_back_q));
            i += 1;
        }

        (self, factor)
    }
}

impl<const LIMBS: usize> OddUint<LIMBS> {
    /// Compute `1/2 mod q`.
    const fn half_mod(q: &Self) -> Self {
        //        1  / 2      mod q
        // = (q + 1) / 2      mod q
        // = (q - 1) / 2  + 1 mod q
        // = floor(q / 2) + 1 mod q, since q is odd.
        Odd(q.as_ref().shr1().wrapping_add(&Uint::ONE))
    }

    /// Compute `((self * b) + addend) / 2^k`
    const fn mul_add_div2k(&self, b: Limb, addend: &Uint<LIMBS>, k: u32) -> Uint<LIMBS> {
        // Compute `self * b + addend`
        let (lo, mut hi) = self.as_ref().carrying_mul_add_limb(b, addend, Limb::ZERO);

        // Divide by 2^k
        hi = hi.shl((Limb::BITS - k) % Limb::BITS);
        let (mut res, _) = lo.shr_limb(k);
        res.limbs[LIMBS - 1] = res.limbs[LIMBS - 1].bitxor(hi);
        res
    }
}

#[cfg(test)]
mod tests {
    use crate::{Limb, U128, Uint};

    #[test]
    fn test_uint_bounded_div2k_mod_q() {
        let q = U128::from(3u64).to_odd().unwrap();

        // Do nothing
        let res = U128::ONE.shl_vartime(64).bounded_div2k_mod_q(0, 0, &q);
        assert_eq!(res, U128::ONE.shl_vartime(64));

        // Simply shift out 5 factors
        let res = U128::ONE.shl_vartime(64).bounded_div2k_mod_q(5, 5, &q);
        assert_eq!(res, U128::ONE.shl_vartime(59));

        // Add in one factor of q
        let res = U128::ONE.bounded_div2k_mod_q(1, 1, &q);
        assert_eq!(res, U128::from(2u64));

        // Add in many factors of q
        let res = U128::from(8u64).bounded_div2k_mod_q(17, 17, &q);
        assert_eq!(res, U128::ONE);

        // Larger q
        let q = U128::from(2864434311u64).to_odd().unwrap();
        let res = U128::from(8u64).bounded_div2k_mod_q(17, 17, &q);
        assert_eq!(res, U128::from(303681787u64));

        // Shift greater than Limb::BITS
        let q = U128::from_be_hex("0000AAAABBBB33330000AAAABBBB3333")
            .to_odd()
            .unwrap();
        let res = U128::MAX.bounded_div2k_mod_q(71, 71, &q);
        assert_eq!(res, U128::from_be_hex("00002D6F169DBBF300002D6F169DBBF3"));

        // Have k_bound restrict the number of shifts to 0
        let res = U128::MAX.bounded_div2k_mod_q(71, 0, &q);
        assert_eq!(res, U128::MAX);

        // Have k_bound < k
        let res = U128::MAX.bounded_div2k_mod_q(71, 30, &q);
        assert_eq!(res, U128::from_be_hex("000071EEB6013E76000071EEB6013E76"));

        // Have k_bound >> k
        let res = U128::MAX.bounded_div2k_mod_q(30, 127, &q);
        assert_eq!(res, U128::from_be_hex("000071EEB6013E76000071EEB6013E76"));
    }

    #[test]
    fn test_limb_bounded_div2k_mod_q() {
        let x = Limb::MAX.wrapping_sub(Limb::from(15u32));
        let q = Limb::from(55u32);
        let half_mod_q = q.shr1().0.wrapping_add(Limb::ONE);

        // Do nothing
        let (res, factor) = x.bounded_div2k_mod_q(0, 3, half_mod_q);
        assert_eq!(res, x);
        assert_eq!(factor, Limb::ZERO);

        // Divide by 2^4 without requiring the addition of q
        let (res, factor) = x.bounded_div2k_mod_q(4, 4, half_mod_q);
        assert_eq!(res, x.shr(4));
        assert_eq!(factor, Limb::ZERO);

        // Divide by 2^5, requiring a single addition of q * 2^4
        let (res, factor) = x.bounded_div2k_mod_q(5, 5, half_mod_q);
        assert_eq!(res, x.shr(5).wrapping_add(half_mod_q));
        assert_eq!(factor, Limb::ONE.shl(4));

        // Execute at most k_bound iterations
        let (res, factor) = x.bounded_div2k_mod_q(5, 4, half_mod_q);
        assert_eq!(res, x.shr(4));
        assert_eq!(factor, Limb::ZERO);
    }

    #[test]
    fn test_carrying_mul_add_limb() {
        // Do nothing
        let x = U128::from_be_hex("ABCDEF98765432100123456789FEDCBA");
        let q = U128::MAX;
        let f = Limb::ZERO;
        let (res, carry) = q.carrying_mul_add_limb(f, &x, Limb::ZERO);
        assert_eq!(res, x);
        assert_eq!(carry, Limb::ZERO);

        // f = 1
        let x = U128::from_be_hex("ABCDEF98765432100123456789FEDCBA");
        let q = U128::MAX;
        let f = Limb::ONE;
        let (res, carry) = q.carrying_mul_add_limb(f, &x, Limb::ZERO);
        assert_eq!(res, x.wrapping_add(&q));
        assert_eq!(carry, Limb::ONE);

        // f = max
        let x = U128::from_be_hex("ABCDEF98765432100123456789FEDCBA");
        let q = U128::MAX;
        let f = Limb::MAX;
        let (res, mac_carry) = q.carrying_mul_add_limb(f, &x, Limb::ZERO);

        let (qf_lo, qf_hi) = q.widening_mul(&Uint::new([f; 1]));
        let (lo, carry) = qf_lo.carrying_add(&x, Limb::ZERO);
        let (hi, carry) = qf_hi.carrying_add(&Uint::ZERO, carry);
        assert_eq!(res, lo);
        assert_eq!(mac_carry, hi.limbs[0]);
        assert_eq!(carry, Limb::ZERO)
    }
}
