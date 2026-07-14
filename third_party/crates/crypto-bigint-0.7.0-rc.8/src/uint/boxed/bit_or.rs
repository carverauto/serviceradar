//! [`BoxedUint`] bitwise OR operations.

use crate::{BoxedUint, Wrapping};
use core::ops::{BitOr, BitOrAssign};
use subtle::{Choice, CtOption};

impl BoxedUint {
    /// Computes bitwise `a & b`.
    #[inline(always)]
    pub fn bitor(&self, rhs: &Self) -> Self {
        Self::map_limbs(self, rhs, |a, b| a.bitor(b))
    }

    /// Perform wrapping bitwise `OR`.
    ///
    /// There's no way wrapping could ever happen.
    /// This function exists so that all operations are accounted for in the wrapping operations
    pub fn wrapping_or(&self, rhs: &Self) -> Self {
        self.bitor(rhs)
    }

    /// Perform checked bitwise `OR`, returning a [`CtOption`] which `is_some` always
    pub fn checked_or(&self, rhs: &Self) -> CtOption<Self> {
        let result = self.bitor(rhs);
        CtOption::new(result, Choice::from(1))
    }
}

impl BitOr for BoxedUint {
    type Output = Self;

    fn bitor(self, rhs: Self) -> BoxedUint {
        self.bitor(&rhs)
    }
}

impl BitOr<&BoxedUint> for BoxedUint {
    type Output = BoxedUint;

    #[allow(clippy::needless_borrow)]
    fn bitor(self, rhs: &BoxedUint) -> BoxedUint {
        (&self).bitor(rhs)
    }
}

impl BitOr<BoxedUint> for &BoxedUint {
    type Output = BoxedUint;

    fn bitor(self, rhs: BoxedUint) -> BoxedUint {
        self.bitor(&rhs)
    }
}

impl BitOr<&BoxedUint> for &BoxedUint {
    type Output = BoxedUint;

    fn bitor(self, rhs: &BoxedUint) -> BoxedUint {
        self.bitor(rhs)
    }
}

impl BitOrAssign for BoxedUint {
    fn bitor_assign(&mut self, other: Self) {
        Self::bitor_assign(self, &other)
    }
}

impl BitOrAssign<&BoxedUint> for BoxedUint {
    fn bitor_assign(&mut self, other: &Self) {
        for (a, b) in self.limbs.iter_mut().zip(other.limbs.iter()) {
            *a |= *b;
        }
    }
}

impl BitOr for Wrapping<BoxedUint> {
    type Output = Self;

    fn bitor(self, rhs: Self) -> Wrapping<BoxedUint> {
        Wrapping(self.0.bitor(&rhs.0))
    }
}

impl BitOr<&Wrapping<BoxedUint>> for Wrapping<BoxedUint> {
    type Output = Wrapping<BoxedUint>;

    fn bitor(self, rhs: &Wrapping<BoxedUint>) -> Wrapping<BoxedUint> {
        Wrapping(self.0.bitor(&rhs.0))
    }
}

impl BitOr<Wrapping<BoxedUint>> for &Wrapping<BoxedUint> {
    type Output = Wrapping<BoxedUint>;

    fn bitor(self, rhs: Wrapping<BoxedUint>) -> Wrapping<BoxedUint> {
        Wrapping(BoxedUint::bitor(&self.0, &rhs.0))
    }
}

impl BitOr<&Wrapping<BoxedUint>> for &Wrapping<BoxedUint> {
    type Output = Wrapping<BoxedUint>;

    fn bitor(self, rhs: &Wrapping<BoxedUint>) -> Wrapping<BoxedUint> {
        Wrapping(BoxedUint::bitor(&self.0, &rhs.0))
    }
}

impl BitOrAssign for Wrapping<BoxedUint> {
    fn bitor_assign(&mut self, other: Self) {
        self.0.bitor_assign(&other.0)
    }
}

impl BitOrAssign<&Wrapping<BoxedUint>> for Wrapping<BoxedUint> {
    fn bitor_assign(&mut self, other: &Self) {
        self.0.bitor_assign(&other.0)
    }
}
