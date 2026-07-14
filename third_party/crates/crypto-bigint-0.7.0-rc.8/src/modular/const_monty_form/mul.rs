//! Multiplications between integers in Montgomery form with a constant modulus.

use core::{
    marker::PhantomData,
    ops::{Mul, MulAssign},
};

use crate::{
    modular::mul::{mul_montgomery_form, square_montgomery_form},
    traits::Square,
};

use super::{ConstMontyForm, ConstMontyParams};

impl<MOD: ConstMontyParams<LIMBS>, const LIMBS: usize> ConstMontyForm<MOD, LIMBS> {
    /// Multiplies by `rhs`.
    pub const fn mul(&self, rhs: &Self) -> Self {
        Self {
            montgomery_form: mul_montgomery_form(
                &self.montgomery_form,
                &rhs.montgomery_form,
                &MOD::PARAMS.modulus,
                MOD::PARAMS.mod_neg_inv(),
            ),
            phantom: PhantomData,
        }
    }

    /// Computes the (reduced) square.
    pub const fn square(&self) -> Self {
        Self {
            montgomery_form: square_montgomery_form(
                &self.montgomery_form,
                &MOD::PARAMS.modulus,
                MOD::PARAMS.mod_neg_inv(),
            ),
            phantom: PhantomData,
        }
    }
}

impl<MOD: ConstMontyParams<LIMBS>, const LIMBS: usize> Mul<&ConstMontyForm<MOD, LIMBS>>
    for &ConstMontyForm<MOD, LIMBS>
{
    type Output = ConstMontyForm<MOD, LIMBS>;
    fn mul(self, rhs: &ConstMontyForm<MOD, LIMBS>) -> ConstMontyForm<MOD, LIMBS> {
        self.mul(rhs)
    }
}

impl<MOD: ConstMontyParams<LIMBS>, const LIMBS: usize> Mul<ConstMontyForm<MOD, LIMBS>>
    for &ConstMontyForm<MOD, LIMBS>
{
    type Output = ConstMontyForm<MOD, LIMBS>;
    #[allow(clippy::op_ref)]
    fn mul(self, rhs: ConstMontyForm<MOD, LIMBS>) -> ConstMontyForm<MOD, LIMBS> {
        self * &rhs
    }
}

impl<MOD: ConstMontyParams<LIMBS>, const LIMBS: usize> Mul<&ConstMontyForm<MOD, LIMBS>>
    for ConstMontyForm<MOD, LIMBS>
{
    type Output = ConstMontyForm<MOD, LIMBS>;
    #[allow(clippy::op_ref)]
    fn mul(self, rhs: &ConstMontyForm<MOD, LIMBS>) -> ConstMontyForm<MOD, LIMBS> {
        &self * rhs
    }
}

impl<MOD: ConstMontyParams<LIMBS>, const LIMBS: usize> Mul<ConstMontyForm<MOD, LIMBS>>
    for ConstMontyForm<MOD, LIMBS>
{
    type Output = ConstMontyForm<MOD, LIMBS>;
    fn mul(self, rhs: ConstMontyForm<MOD, LIMBS>) -> ConstMontyForm<MOD, LIMBS> {
        &self * &rhs
    }
}

impl<MOD: ConstMontyParams<LIMBS>, const LIMBS: usize> MulAssign<&Self>
    for ConstMontyForm<MOD, LIMBS>
{
    fn mul_assign(&mut self, rhs: &ConstMontyForm<MOD, LIMBS>) {
        *self = *self * rhs;
    }
}

impl<MOD: ConstMontyParams<LIMBS>, const LIMBS: usize> MulAssign<Self>
    for ConstMontyForm<MOD, LIMBS>
{
    fn mul_assign(&mut self, rhs: Self) {
        *self *= &rhs;
    }
}

impl<MOD: ConstMontyParams<LIMBS>, const LIMBS: usize> Square for ConstMontyForm<MOD, LIMBS> {
    fn square(&self) -> Self {
        ConstMontyForm::square(self)
    }
}
