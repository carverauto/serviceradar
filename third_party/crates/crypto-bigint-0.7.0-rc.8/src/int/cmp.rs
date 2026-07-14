//! [`Int`] comparisons.
//!
//! By default, these are all constant-time.

use core::cmp::Ordering;

use subtle::{Choice, ConstantTimeEq, ConstantTimeGreater, ConstantTimeLess};

use crate::{ConstChoice, Int, Uint};

impl<const LIMBS: usize> Int<LIMBS> {
    /// Return `b` if `c` is truthy, otherwise return `a`.
    #[inline]
    pub(crate) const fn select(a: &Self, b: &Self, c: ConstChoice) -> Self {
        Self(Uint::select(&a.0, &b.0, c))
    }

    /// Swap `a` and `b` if `c` is truthy, otherwise, do nothing.
    #[inline]
    pub(crate) const fn conditional_swap(a: &mut Self, b: &mut Self, c: ConstChoice) {
        Uint::conditional_swap(&mut a.0, &mut b.0, c);
    }

    /// Returns the truthy value if `self`!=0 or the falsy value otherwise.
    #[inline]
    pub(crate) const fn is_nonzero(&self) -> ConstChoice {
        Uint::is_nonzero(&self.0)
    }

    /// Returns the truthy value if `self == rhs` or the falsy value otherwise.
    #[inline]
    pub(crate) const fn eq(lhs: &Self, rhs: &Self) -> ConstChoice {
        Uint::eq(&lhs.0, &rhs.0)
    }

    /// Returns the truthy value if `self < rhs` and the falsy value otherwise.
    #[inline]
    pub(crate) const fn lt(lhs: &Self, rhs: &Self) -> ConstChoice {
        Uint::lt(&lhs.invert_msb().0, &rhs.invert_msb().0)
    }

    /// Returns the truthy value if `self > rhs` and the falsy value otherwise.
    #[inline]
    pub(crate) const fn gt(lhs: &Self, rhs: &Self) -> ConstChoice {
        Uint::gt(&lhs.invert_msb().0, &rhs.invert_msb().0)
    }

    /// Returns the ordering between `self` and `rhs` as an i8.
    /// Values correspond to the Ordering enum:
    ///   -1 is Less
    ///   0 is Equal
    ///   1 is Greater
    #[inline]
    pub(crate) const fn cmp(lhs: &Self, rhs: &Self) -> i8 {
        Uint::cmp(&lhs.invert_msb().0, &rhs.invert_msb().0)
    }

    /// Returns the Ordering between `self` and `rhs` in variable time.
    pub const fn cmp_vartime(&self, rhs: &Self) -> Ordering {
        self.invert_msb().0.cmp_vartime(&rhs.invert_msb().0)
    }
}

impl<const LIMBS: usize> ConstantTimeEq for Int<LIMBS> {
    #[inline]
    fn ct_eq(&self, other: &Self) -> Choice {
        Int::eq(self, other).into()
    }
}

impl<const LIMBS: usize> ConstantTimeGreater for Int<LIMBS> {
    #[inline]
    fn ct_gt(&self, other: &Self) -> Choice {
        Int::gt(self, other).into()
    }
}

impl<const LIMBS: usize> ConstantTimeLess for Int<LIMBS> {
    #[inline]
    fn ct_lt(&self, other: &Self) -> Choice {
        Int::lt(self, other).into()
    }
}

impl<const LIMBS: usize> Eq for Int<LIMBS> {}

impl<const LIMBS: usize> Ord for Int<LIMBS> {
    fn cmp(&self, other: &Self) -> Ordering {
        let c = Self::cmp(self, other);
        match c {
            -1 => Ordering::Less,
            0 => Ordering::Equal,
            _ => Ordering::Greater,
        }
    }
}

impl<const LIMBS: usize> PartialOrd for Int<LIMBS> {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl<const LIMBS: usize> PartialEq for Int<LIMBS> {
    fn eq(&self, other: &Self) -> bool {
        self.ct_eq(other).into()
    }
}

#[cfg(test)]
mod tests {
    use subtle::{ConstantTimeGreater, ConstantTimeLess};

    use crate::I128;

    #[test]
    fn test_is_nonzero() {
        assert_eq!(I128::MAX.is_nonzero().to_u8(), 1u8);
        assert_eq!(I128::ONE.is_nonzero().to_u8(), 1u8);
        assert_eq!(I128::ZERO.is_nonzero().to_u8(), 0u8);
        assert_eq!(I128::MINUS_ONE.is_nonzero().to_u8(), 1u8);
        assert_eq!(I128::MAX.is_nonzero().to_u8(), 1u8);
    }

    #[test]
    fn test_eq() {
        assert_eq!(I128::ZERO, I128::ONE.wrapping_add(&I128::MINUS_ONE));
        assert_eq!(I128::ONE, I128::ZERO.wrapping_add(&I128::ONE));
        assert_ne!(I128::ONE, I128::ZERO);
    }

    #[test]
    #[allow(clippy::bool_assert_comparison)]
    fn test_gt() {
        // x > y
        assert!(I128::MAX > I128::ONE);
        assert!(I128::ONE > I128::ZERO);
        assert!(I128::ZERO > I128::MINUS_ONE);
        assert!(I128::MINUS_ONE > I128::MIN);
        assert!(I128::MAX > I128::MIN);

        // a !> a
        assert_ne!(true, I128::MAX > I128::MAX);
        assert_ne!(true, I128::ONE > I128::ONE);
        assert_ne!(true, I128::ZERO > I128::ZERO);
        assert_ne!(true, I128::MINUS_ONE > I128::MINUS_ONE);
        assert_ne!(true, I128::MIN > I128::MIN);
    }

    #[test]
    #[allow(clippy::bool_assert_comparison)]
    fn test_lt() {
        // x < y
        assert!(I128::ONE < I128::MAX);
        assert!(I128::ZERO < I128::ONE);
        assert!(I128::MINUS_ONE < I128::ZERO);
        assert!(I128::MIN < I128::MINUS_ONE);
        assert!(I128::MIN < I128::MAX);

        // a !< a
        assert_ne!(true, I128::MAX < I128::MAX);
        assert_ne!(true, I128::ONE < I128::ONE);
        assert_ne!(true, I128::ZERO < I128::ZERO);
        assert_ne!(true, I128::MINUS_ONE < I128::MINUS_ONE);
        assert_ne!(true, I128::MIN < I128::MIN);
    }

    #[test]
    fn ct_gt() {
        let a = I128::MIN;
        let b = I128::ZERO;
        let c = I128::MAX;

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
        let a = I128::ZERO;
        let b = I128::ONE;
        let c = I128::MAX;

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
}
