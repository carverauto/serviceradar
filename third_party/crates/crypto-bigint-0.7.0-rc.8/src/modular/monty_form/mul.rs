//! Multiplications between integers in Montgomery form with a modulus set at runtime.

use super::MontyForm;
use crate::{
    MontyMultiplier, Square, SquareAssign,
    modular::{
        MontyParams,
        mul::{mul_montgomery_form, square_montgomery_form},
    },
};
use core::ops::{Mul, MulAssign};

impl<const LIMBS: usize> MontyForm<LIMBS> {
    /// Multiplies by `rhs`.
    pub const fn mul(&self, rhs: &Self) -> Self {
        Self {
            montgomery_form: mul_montgomery_form(
                &self.montgomery_form,
                &rhs.montgomery_form,
                &self.params.modulus,
                self.params.mod_neg_inv(),
            ),
            params: self.params,
        }
    }

    /// Computes the (reduced) square.
    pub const fn square(&self) -> Self {
        Self {
            montgomery_form: square_montgomery_form(
                &self.montgomery_form,
                &self.params.modulus,
                self.params.mod_neg_inv(),
            ),
            params: self.params,
        }
    }
}

impl<const LIMBS: usize> Mul<&MontyForm<LIMBS>> for &MontyForm<LIMBS> {
    type Output = MontyForm<LIMBS>;
    fn mul(self, rhs: &MontyForm<LIMBS>) -> MontyForm<LIMBS> {
        debug_assert_eq!(self.params, rhs.params);
        self.mul(rhs)
    }
}

impl<const LIMBS: usize> Mul<MontyForm<LIMBS>> for &MontyForm<LIMBS> {
    type Output = MontyForm<LIMBS>;
    #[allow(clippy::op_ref)]
    fn mul(self, rhs: MontyForm<LIMBS>) -> MontyForm<LIMBS> {
        self * &rhs
    }
}

impl<const LIMBS: usize> Mul<&MontyForm<LIMBS>> for MontyForm<LIMBS> {
    type Output = MontyForm<LIMBS>;
    #[allow(clippy::op_ref)]
    fn mul(self, rhs: &MontyForm<LIMBS>) -> MontyForm<LIMBS> {
        &self * rhs
    }
}

impl<const LIMBS: usize> Mul<MontyForm<LIMBS>> for MontyForm<LIMBS> {
    type Output = MontyForm<LIMBS>;
    fn mul(self, rhs: MontyForm<LIMBS>) -> MontyForm<LIMBS> {
        &self * &rhs
    }
}

impl<const LIMBS: usize> MulAssign<&MontyForm<LIMBS>> for MontyForm<LIMBS> {
    fn mul_assign(&mut self, rhs: &MontyForm<LIMBS>) {
        *self = *self * rhs;
    }
}

impl<const LIMBS: usize> MulAssign<MontyForm<LIMBS>> for MontyForm<LIMBS> {
    fn mul_assign(&mut self, rhs: MontyForm<LIMBS>) {
        *self *= &rhs;
    }
}

impl<const LIMBS: usize> Square for MontyForm<LIMBS> {
    fn square(&self) -> Self {
        MontyForm::square(self)
    }
}

impl<const LIMBS: usize> SquareAssign for MontyForm<LIMBS> {
    fn square_assign(&mut self) {
        *self = self.square()
    }
}

#[derive(Debug, Clone, Copy)]
pub struct DynMontyMultiplier<'a, const LIMBS: usize>(&'a MontyParams<LIMBS>);

impl<'a, const LIMBS: usize> From<&'a MontyParams<LIMBS>> for DynMontyMultiplier<'a, LIMBS> {
    fn from(source: &'a MontyParams<LIMBS>) -> Self {
        Self(source)
    }
}

impl<'a, const LIMBS: usize> MontyMultiplier<'a> for DynMontyMultiplier<'a, LIMBS> {
    type Monty = MontyForm<LIMBS>;

    /// Performs a Montgomery multiplication, assigning a fully reduced result to `lhs`.
    fn mul_assign(&mut self, lhs: &mut Self::Monty, rhs: &Self::Monty) {
        let product = mul_montgomery_form(
            &lhs.montgomery_form,
            &rhs.montgomery_form,
            &self.0.modulus,
            self.0.mod_neg_inv(),
        );
        lhs.montgomery_form = product;
    }

    /// Performs a Montgomery squaring, assigning a fully reduced result to `lhs`.
    fn square_assign(&mut self, lhs: &mut Self::Monty) {
        let product =
            square_montgomery_form(&lhs.montgomery_form, &self.0.modulus, self.0.mod_neg_inv());
        lhs.montgomery_form = product;
    }
}
