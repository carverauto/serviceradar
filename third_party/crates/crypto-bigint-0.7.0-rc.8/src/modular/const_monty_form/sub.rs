//! Subtractions between integers in Montgomery form with a constant modulus.

use super::{ConstMontyForm, ConstMontyParams};
use crate::modular::sub::sub_montgomery_form;
use core::ops::{Sub, SubAssign};

impl<MOD: ConstMontyParams<LIMBS>, const LIMBS: usize> ConstMontyForm<MOD, LIMBS> {
    /// Subtracts `rhs`.
    pub const fn sub(&self, rhs: &Self) -> Self {
        Self {
            montgomery_form: sub_montgomery_form(
                &self.montgomery_form,
                &rhs.montgomery_form,
                &MOD::PARAMS.modulus,
            ),
            phantom: core::marker::PhantomData,
        }
    }
}

impl<MOD: ConstMontyParams<LIMBS>, const LIMBS: usize> Sub<&ConstMontyForm<MOD, LIMBS>>
    for &ConstMontyForm<MOD, LIMBS>
{
    type Output = ConstMontyForm<MOD, LIMBS>;
    fn sub(self, rhs: &ConstMontyForm<MOD, LIMBS>) -> ConstMontyForm<MOD, LIMBS> {
        self.sub(rhs)
    }
}

impl<MOD: ConstMontyParams<LIMBS>, const LIMBS: usize> Sub<ConstMontyForm<MOD, LIMBS>>
    for &ConstMontyForm<MOD, LIMBS>
{
    type Output = ConstMontyForm<MOD, LIMBS>;
    #[allow(clippy::op_ref)]
    fn sub(self, rhs: ConstMontyForm<MOD, LIMBS>) -> ConstMontyForm<MOD, LIMBS> {
        self - &rhs
    }
}

impl<MOD: ConstMontyParams<LIMBS>, const LIMBS: usize> Sub<&ConstMontyForm<MOD, LIMBS>>
    for ConstMontyForm<MOD, LIMBS>
{
    type Output = ConstMontyForm<MOD, LIMBS>;
    #[allow(clippy::op_ref)]
    fn sub(self, rhs: &ConstMontyForm<MOD, LIMBS>) -> ConstMontyForm<MOD, LIMBS> {
        &self - rhs
    }
}

impl<MOD: ConstMontyParams<LIMBS>, const LIMBS: usize> Sub<ConstMontyForm<MOD, LIMBS>>
    for ConstMontyForm<MOD, LIMBS>
{
    type Output = ConstMontyForm<MOD, LIMBS>;
    fn sub(self, rhs: ConstMontyForm<MOD, LIMBS>) -> ConstMontyForm<MOD, LIMBS> {
        &self - &rhs
    }
}

impl<MOD: ConstMontyParams<LIMBS>, const LIMBS: usize> SubAssign<&Self>
    for ConstMontyForm<MOD, LIMBS>
{
    fn sub_assign(&mut self, rhs: &Self) {
        *self = *self - rhs;
    }
}

impl<MOD: ConstMontyParams<LIMBS>, const LIMBS: usize> SubAssign<Self>
    for ConstMontyForm<MOD, LIMBS>
{
    fn sub_assign(&mut self, rhs: Self) {
        *self -= &rhs;
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
    fn sub_overflow() {
        let x =
            U256::from_be_hex("44acf6b7e36c1342c2c5897204fe09504e1e2efb1a900377dbc4e7a6a133ec56");
        let mut x_mod = Fe::new(&x);

        let y =
            U256::from_be_hex("d5777c45019673125ad240f83094d4252d829516fac8601ed01979ec1ec1a251");
        let y_mod = Fe::new(&y);

        x_mod -= &y_mod;

        let expected =
            U256::from_be_hex("6f357a71e1d5a03167f34879d469352add829491c6df41ddff65387d7ed56f56");

        assert_eq!(expected, x_mod.retrieve());
    }
}
