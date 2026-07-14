//! Additions between integers in Montgomery form with a constant modulus.

use super::{ConstMontyForm, ConstMontyParams};
use crate::modular::add::{add_montgomery_form, double_montgomery_form};
use core::ops::{Add, AddAssign};

impl<MOD: ConstMontyParams<LIMBS>, const LIMBS: usize> ConstMontyForm<MOD, LIMBS> {
    /// Adds `rhs`.
    pub const fn add(&self, rhs: &ConstMontyForm<MOD, LIMBS>) -> Self {
        Self {
            montgomery_form: add_montgomery_form(
                &self.montgomery_form,
                &rhs.montgomery_form,
                &MOD::PARAMS.modulus,
            ),
            phantom: core::marker::PhantomData,
        }
    }

    /// Double `self`.
    pub const fn double(&self) -> Self {
        Self {
            montgomery_form: double_montgomery_form(&self.montgomery_form, &MOD::PARAMS.modulus),
            phantom: core::marker::PhantomData,
        }
    }
}

impl<MOD: ConstMontyParams<LIMBS>, const LIMBS: usize> Add<&ConstMontyForm<MOD, LIMBS>>
    for &ConstMontyForm<MOD, LIMBS>
{
    type Output = ConstMontyForm<MOD, LIMBS>;
    fn add(self, rhs: &ConstMontyForm<MOD, LIMBS>) -> ConstMontyForm<MOD, LIMBS> {
        self.add(rhs)
    }
}

impl<MOD: ConstMontyParams<LIMBS>, const LIMBS: usize> Add<ConstMontyForm<MOD, LIMBS>>
    for &ConstMontyForm<MOD, LIMBS>
{
    type Output = ConstMontyForm<MOD, LIMBS>;
    #[allow(clippy::op_ref)]
    fn add(self, rhs: ConstMontyForm<MOD, LIMBS>) -> ConstMontyForm<MOD, LIMBS> {
        self + &rhs
    }
}

impl<MOD: ConstMontyParams<LIMBS>, const LIMBS: usize> Add<&ConstMontyForm<MOD, LIMBS>>
    for ConstMontyForm<MOD, LIMBS>
{
    type Output = ConstMontyForm<MOD, LIMBS>;
    #[allow(clippy::op_ref)]
    fn add(self, rhs: &ConstMontyForm<MOD, LIMBS>) -> ConstMontyForm<MOD, LIMBS> {
        &self + rhs
    }
}

impl<MOD: ConstMontyParams<LIMBS>, const LIMBS: usize> Add<ConstMontyForm<MOD, LIMBS>>
    for ConstMontyForm<MOD, LIMBS>
{
    type Output = ConstMontyForm<MOD, LIMBS>;
    fn add(self, rhs: ConstMontyForm<MOD, LIMBS>) -> ConstMontyForm<MOD, LIMBS> {
        &self + &rhs
    }
}

impl<MOD: ConstMontyParams<LIMBS>, const LIMBS: usize> AddAssign<&Self>
    for ConstMontyForm<MOD, LIMBS>
{
    fn add_assign(&mut self, rhs: &Self) {
        *self = *self + rhs;
    }
}

impl<MOD: ConstMontyParams<LIMBS>, const LIMBS: usize> AddAssign<Self>
    for ConstMontyForm<MOD, LIMBS>
{
    fn add_assign(&mut self, rhs: Self) {
        *self += &rhs;
    }
}

#[cfg(test)]
mod tests {
    use crate::{
        U256, const_monty_form, const_monty_params, modular::const_monty_form::ConstMontyParams,
    };

    const_monty_params!(
        Modulus,
        U256,
        "ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551"
    );

    const_monty_form!(Fe, Modulus);

    #[test]
    fn add_overflow() {
        let x =
            U256::from_be_hex("44acf6b7e36c1342c2c5897204fe09504e1e2efb1a900377dbc4e7a6a133ec56");
        let mut x_mod = Fe::new(&x);

        let y =
            U256::from_be_hex("d5777c45019673125ad240f83094d4252d829516fac8601ed01979ec1ec1a251");
        let y_mod = Fe::new(&y);

        x_mod += &y_mod;

        let expected =
            U256::from_be_hex("1a2472fde50286541d97ca6a3592dd75beb9c9646e40c511b82496cfc3926956");

        assert_eq!(expected, x_mod.retrieve());
    }
}
