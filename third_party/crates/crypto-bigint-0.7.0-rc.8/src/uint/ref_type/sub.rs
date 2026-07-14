use super::UintRef;
use crate::Limb;

impl UintRef {
    /// Perform an in-place borrowing subtraction of another [`UintRef`], returning the carried limb value.
    #[inline]
    pub const fn borrowing_sub_assign(&mut self, rhs: &Self, borrow: Limb) -> Limb {
        self.borrowing_sub_assign_slice(&rhs.0, borrow)
    }

    /// Perform an in-place borrowing subtraction of another limb slice, returning the borrowed limb value.
    #[inline]
    pub const fn borrowing_sub_assign_slice(&mut self, rhs: &[Limb], mut borrow: Limb) -> Limb {
        assert!(self.0.len() == rhs.len(), "length mismatch");
        let mut i = 0;
        while i < self.0.len() {
            (self.0[i], borrow) = self.0[i].borrowing_sub(rhs[i], borrow);
            i += 1;
        }
        borrow
    }
}
