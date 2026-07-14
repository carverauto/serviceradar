//! Negations of integers in Montgomery form with a modulus set at runtime.

use super::MontyForm;
use core::ops::Neg;

impl<const LIMBS: usize> MontyForm<LIMBS> {
    /// Negates the number.
    pub const fn neg(&self) -> Self {
        Self {
            montgomery_form: self
                .montgomery_form
                .neg_mod(self.params.modulus.as_nz_ref()),
            params: self.params,
        }
    }
}

impl<const LIMBS: usize> Neg for MontyForm<LIMBS> {
    type Output = Self;
    fn neg(self) -> Self {
        MontyForm::neg(&self)
    }
}

impl<const LIMBS: usize> Neg for &MontyForm<LIMBS> {
    type Output = MontyForm<LIMBS>;
    fn neg(self) -> MontyForm<LIMBS> {
        MontyForm::neg(self)
    }
}
