//! [`BoxedUint`] negation operations.

use crate::{BoxedUint, Limb, WideWord, Word, WrappingNeg};
use subtle::{Choice, ConditionallySelectable};

impl BoxedUint {
    /// Perform wrapping negation.
    pub fn wrapping_neg(&self) -> Self {
        let mut ret = vec![Limb::ZERO; self.nlimbs()];
        let mut carry = 1;

        for i in 0..self.nlimbs() {
            let r = (!self.limbs[i].0 as WideWord) + carry;
            ret[i] = Limb(r as Word);
            carry = r >> Limb::BITS;
        }

        ret.into()
    }

    /// Perform in-place wrapping subtraction, returning the truthy value as the second element of
    /// the tuple if an underflow has occurred.
    pub(crate) fn conditional_wrapping_neg_assign(&mut self, choice: Choice) {
        let mut carry = 1;

        for i in 0..self.nlimbs() {
            let r = (!self.limbs[i].0 as WideWord) + carry;
            self.limbs[i].conditional_assign(&Limb(r as Word), choice);
            carry = r >> Limb::BITS;
        }
    }
}

impl WrappingNeg for BoxedUint {
    fn wrapping_neg(&self) -> Self {
        self.wrapping_neg()
    }
}

#[cfg(test)]
mod tests {
    use crate::BoxedUint;

    #[test]
    fn wrapping_neg() {
        assert_eq!(BoxedUint::zero().wrapping_neg(), BoxedUint::zero());
        assert_eq!(BoxedUint::max(64).wrapping_neg(), BoxedUint::one());
        // assert_eq!(
        //     BoxedUint::from(13u64).wrapping_neg(),
        //     BoxedUint::from(13u64).not().saturating_add(&BoxedUint::one())
        // );
        // assert_eq!(
        //     BoxedUint::from(42u64).wrapping_neg(),
        //     BoxedUint::from(42u64).saturating_sub(&BoxedUint::one()).not()
        // );
    }
}
