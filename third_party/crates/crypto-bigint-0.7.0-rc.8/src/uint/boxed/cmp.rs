//! [`BoxedUint`] comparisons.
//!
//! By default these are all constant-time and use the `subtle` crate.

pub(super) use core::cmp::{Ordering, max};

use super::BoxedUint;
use crate::{ConstChoice, Limb, Uint};
use subtle::{
    Choice, ConditionallySelectable, ConstantTimeEq, ConstantTimeGreater, ConstantTimeLess,
};

impl BoxedUint {
    /// Returns the Ordering between `self` and `rhs` in variable time.
    pub fn cmp_vartime(&self, rhs: &Self) -> Ordering {
        debug_assert_eq!(self.limbs.len(), rhs.limbs.len());
        let mut i = self.limbs.len() - 1;
        loop {
            // TODO: investigate if directly comparing limbs is faster than performing a
            // subtraction between limbs
            let (val, borrow) = self.limbs[i].borrowing_sub(rhs.limbs[i], Limb::ZERO);
            if val.0 != 0 {
                return if borrow.0 != 0 {
                    Ordering::Less
                } else {
                    Ordering::Greater
                };
            }
            if i == 0 {
                return Ordering::Equal;
            }
            i -= 1;
        }
    }

    /// Determine in variable time whether the `self` is zero.
    pub(crate) fn is_zero_vartime(&self) -> bool {
        !self.limbs.iter().any(|l| l.0 != 0)
    }
}

impl ConstantTimeEq for BoxedUint {
    #[inline]
    fn ct_eq(&self, other: &Self) -> Choice {
        let limbs = max(self.nlimbs(), other.nlimbs());
        let mut ret = Choice::from(1u8);

        for i in 0..limbs {
            let a = self.limbs.get(i).unwrap_or(&Limb::ZERO);
            let b = other.limbs.get(i).unwrap_or(&Limb::ZERO);
            ret &= a.ct_eq(b);
        }

        ret
    }
}

impl ConstantTimeGreater for BoxedUint {
    #[inline]
    fn ct_gt(&self, other: &Self) -> Choice {
        let (_, borrow) = other.borrowing_sub(self, Limb::ZERO);
        ConstChoice::from_word_mask(borrow.0).into()
    }
}

impl ConstantTimeLess for BoxedUint {
    #[inline]
    fn ct_lt(&self, other: &Self) -> Choice {
        let (_, borrow) = self.borrowing_sub(other, Limb::ZERO);
        ConstChoice::from_word_mask(borrow.0).into()
    }
}

impl Eq for BoxedUint {}
impl PartialEq for BoxedUint {
    fn eq(&self, other: &Self) -> bool {
        self.ct_eq(other).into()
    }
}

impl<const LIMBS: usize> PartialEq<Uint<LIMBS>> for BoxedUint {
    fn eq(&self, other: &Uint<LIMBS>) -> bool {
        self.eq(&Self::from(other))
    }
}

impl Ord for BoxedUint {
    fn cmp(&self, other: &Self) -> Ordering {
        let mut ret = Ordering::Equal;
        ret.conditional_assign(&Ordering::Greater, self.ct_gt(other));
        ret.conditional_assign(&Ordering::Less, self.ct_lt(other));

        #[cfg(debug_assertions)]
        if ret == Ordering::Equal {
            debug_assert_eq!(self, other);
        }

        ret
    }
}

impl PartialOrd for BoxedUint {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl<const LIMBS: usize> PartialOrd<Uint<LIMBS>> for BoxedUint {
    fn partial_cmp(&self, other: &Uint<LIMBS>) -> Option<Ordering> {
        self.partial_cmp(&Self::from(other))
    }
}

#[cfg(test)]
mod tests {
    use super::BoxedUint;
    use core::cmp::Ordering;
    use subtle::{ConstantTimeEq, ConstantTimeGreater, ConstantTimeLess};

    #[test]
    fn ct_eq() {
        let a = BoxedUint::zero();
        let b = BoxedUint::one();

        assert!(bool::from(a.ct_eq(&a)));
        assert!(!bool::from(a.ct_eq(&b)));
        assert!(!bool::from(b.ct_eq(&a)));
        assert!(bool::from(b.ct_eq(&b)));
    }

    #[test]
    fn ct_gt() {
        let a = BoxedUint::zero();
        let b = BoxedUint::one();
        let c = BoxedUint::max(64);

        assert!(bool::from(b.ct_gt(&a)));
        assert!(bool::from(c.ct_gt(&a)));
        assert!(bool::from(c.ct_gt(&b)));

        assert!(!bool::from(a.ct_gt(&a)));
        assert!(!bool::from(b.ct_gt(&b)));
        assert!(!bool::from(c.ct_gt(&c)));

        assert!(!bool::from(a.ct_gt(&b)));
        assert!(!bool::from(a.ct_gt(&c)));
        assert!(!bool::from(b.ct_gt(&c)));
    }

    #[test]
    fn ct_lt() {
        let a = BoxedUint::zero();
        let b = BoxedUint::one();
        let c = BoxedUint::max(64);

        assert!(bool::from(a.ct_lt(&b)));
        assert!(bool::from(a.ct_lt(&c)));
        assert!(bool::from(b.ct_lt(&c)));

        assert!(!bool::from(a.ct_lt(&a)));
        assert!(!bool::from(b.ct_lt(&b)));
        assert!(!bool::from(c.ct_lt(&c)));

        assert!(!bool::from(b.ct_lt(&a)));
        assert!(!bool::from(c.ct_lt(&a)));
        assert!(!bool::from(c.ct_lt(&b)));
    }

    #[test]
    fn cmp() {
        let a = BoxedUint::zero();
        let b = BoxedUint::one();
        let c = BoxedUint::max(64);

        assert_eq!(a.cmp(&b), Ordering::Less);
        assert_eq!(a.cmp(&c), Ordering::Less);
        assert_eq!(b.cmp(&c), Ordering::Less);

        assert_eq!(a.cmp(&a), Ordering::Equal);
        assert_eq!(b.cmp(&b), Ordering::Equal);
        assert_eq!(c.cmp(&c), Ordering::Equal);

        assert_eq!(b.cmp(&a), Ordering::Greater);
        assert_eq!(c.cmp(&a), Ordering::Greater);
        assert_eq!(c.cmp(&b), Ordering::Greater);
    }
}
