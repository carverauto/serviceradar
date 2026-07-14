//! [`BoxedUint`] modular subtraction operations.

use crate::{BoxedUint, Limb, NonZero, SubMod, Zero};

impl BoxedUint {
    /// Computes `self - rhs mod p`.
    ///
    /// Assumes `self - rhs` as unbounded signed integer is in `[-p, p)`.
    pub fn sub_mod(&self, rhs: &Self, p: &NonZero<Self>) -> Self {
        debug_assert_eq!(self.bits_precision(), p.bits_precision());
        debug_assert_eq!(rhs.bits_precision(), p.bits_precision());
        debug_assert!(self < p.as_ref());
        debug_assert!(rhs < p.as_ref());

        let (mut out, borrow) = self.borrowing_sub(rhs, Limb::ZERO);

        // If underflow occurred on the final limb, borrow = 0xfff...fff, otherwise
        // borrow = 0x000...000. Thus, we use it as a mask to conditionally add the modulus.
        out.conditional_carrying_add_assign(p, !borrow.is_zero());
        out
    }

    /// Returns `(self..., carry) - (rhs...) mod (p...)`, where `carry <= 1`.
    /// Assumes `-(p...) <= (self..., carry) - (rhs...) < (p...)`.
    #[inline(always)]
    pub(crate) fn sub_assign_mod_with_carry(&mut self, carry: Limb, rhs: &Self, p: &Self) {
        debug_assert!(carry.0 <= 1);

        let borrow = self.borrowing_sub_assign(rhs, Limb::ZERO);

        // The new `borrow = Word::MAX` iff `carry == 0` and `borrow == Word::MAX`.
        let mask = carry.wrapping_neg().not().bitand(borrow);

        // If underflow occurred on the final limb, borrow = 0xfff...fff, otherwise
        // borrow = 0x000...000. Thus, we use it as a mask to conditionally add the modulus.
        self.conditional_carrying_add_assign(p, !mask.is_zero());
    }

    /// Computes `self - rhs mod p` for the special modulus
    /// `p = MAX+1-c` where `c` is small enough to fit in a single [`Limb`].
    ///
    /// Assumes `self - rhs` as unbounded signed integer is in `[-p, p)`.
    pub fn sub_mod_special(&self, rhs: &Self, c: Limb) -> Self {
        let (out, borrow) = self.borrowing_sub(rhs, Limb::ZERO);

        // If underflow occurred, then we need to subtract `c` to account for
        // the underflow. This cannot underflow due to the assumption
        // `self - rhs >= -p`.
        let l = borrow.0 & c.0;
        out.wrapping_sub(&Self::from(l))
    }
}

impl SubMod for BoxedUint {
    type Output = Self;

    fn sub_mod(&self, rhs: &Self, p: &NonZero<Self>) -> Self {
        self.sub_mod(rhs, p)
    }
}

#[cfg(test)]
mod tests {
    use super::BoxedUint;
    use hex_literal::hex;

    #[test]
    fn sub_mod_nist_p256() {
        let a = BoxedUint::from_be_slice(
            &hex!("1a2472fde50286541d97ca6a3592dd75beb9c9646e40c511b82496cfc3926956"),
            256,
        )
        .unwrap();
        let b = BoxedUint::from_be_slice(
            &hex!("d5777c45019673125ad240f83094d4252d829516fac8601ed01979ec1ec1a251"),
            256,
        )
        .unwrap();
        let n = BoxedUint::from_be_slice(
            &hex!("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551"),
            256,
        )
        .unwrap()
        .to_nz()
        .unwrap();

        let actual = a.sub_mod(&b, &n);
        let expected = BoxedUint::from_be_slice(
            &hex!("44acf6b7e36c1342c2c5897204fe09504e1e2efb1a900377dbc4e7a6a133ec56"),
            256,
        )
        .unwrap();

        assert_eq!(expected, actual);
    }
}
