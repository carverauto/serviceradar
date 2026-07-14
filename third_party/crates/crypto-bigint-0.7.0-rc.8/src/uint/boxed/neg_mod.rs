//! [`BoxedUint`] modular negation operations.

use crate::{BoxedUint, Limb, NegMod, NonZero};
use subtle::ConditionallySelectable;

impl BoxedUint {
    /// Computes `-a mod p`.
    /// Assumes `self` is in `[0, p)`.
    pub fn neg_mod(&self, p: &NonZero<Self>) -> Self {
        debug_assert_eq!(self.bits_precision(), p.bits_precision());
        let is_zero = self.is_zero();
        let mut ret = p.borrowing_sub(self, Limb::ZERO).0;

        for i in 0..self.nlimbs() {
            // Set ret to 0 if the original value was 0, in which
            // case ret would be p.
            ret.limbs[i].conditional_assign(&Limb::ZERO, is_zero);
        }

        ret
    }

    /// Computes `-a mod p` for the special modulus
    /// `p = MAX+1-c` where `c` is small enough to fit in a single [`Limb`].
    pub fn neg_mod_special(&self, c: Limb) -> Self {
        Self::zero_with_precision(self.bits_precision()).sub_mod_special(self, c)
    }
}

impl NegMod for BoxedUint {
    type Output = Self;

    fn neg_mod(&self, p: &NonZero<Self>) -> Self {
        debug_assert!(self < p.as_ref());
        self.neg_mod(p)
    }
}

#[cfg(test)]
mod tests {
    use crate::BoxedUint;
    use hex_literal::hex;

    #[test]
    fn neg_mod_random() {
        let x = BoxedUint::from_be_slice(
            &hex!("8d16e171674b4e6d8529edba4593802bf30b8cb161dd30aa8e550d41380007c2"),
            256,
        )
        .unwrap();
        let p = BoxedUint::from_be_slice(
            &hex!("928334a4e4be0843ec225a4c9c61df34bdc7a81513e4b6f76f2bfa3148e2e1b5"),
            256,
        )
        .unwrap()
        .to_nz()
        .unwrap();

        let actual = x.neg_mod(&p);
        let expected = BoxedUint::from_be_slice(
            &hex!("056c53337d72b9d666f86c9256ce5f08cabc1b63b207864ce0d6ecf010e2d9f3"),
            256,
        )
        .unwrap();

        assert_eq!(expected, actual);
    }

    #[test]
    fn neg_mod_zero() {
        let x = BoxedUint::from_be_slice(
            &hex!("0000000000000000000000000000000000000000000000000000000000000000"),
            256,
        )
        .unwrap();
        let p = BoxedUint::from_be_slice(
            &hex!("928334a4e4be0843ec225a4c9c61df34bdc7a81513e4b6f76f2bfa3148e2e1b5"),
            256,
        )
        .unwrap()
        .to_nz()
        .unwrap();

        let actual = x.neg_mod(&p);
        let expected = BoxedUint::from_be_slice(
            &hex!("0000000000000000000000000000000000000000000000000000000000000000"),
            256,
        )
        .unwrap();

        assert_eq!(expected, actual);
    }
}
