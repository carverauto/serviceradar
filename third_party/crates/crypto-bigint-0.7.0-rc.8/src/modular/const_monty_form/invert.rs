//! Multiplicative inverses of integers in Montgomery form with a constant modulus.

use super::{ConstMontyForm, ConstMontyParams};
use crate::{ConstCtOption, Invert, modular::SafeGcdInverter};
use core::marker::PhantomData;
use subtle::CtOption;

impl<MOD: ConstMontyParams<LIMBS>, const LIMBS: usize> ConstMontyForm<MOD, LIMBS> {
    /// Computes `self^-1` representing the multiplicative inverse of `self`,
    /// i.e. `self * self^-1 = 1`.
    ///
    /// If the number was invertible, the second element of the tuple is the truthy value,
    /// otherwise it is the falsy value (in which case the first element's value is unspecified).
    #[deprecated(since = "0.7.0", note = "please use `invert` instead")]
    pub const fn inv(&self) -> ConstCtOption<Self> {
        self.invert()
    }

    /// Computes `self^-1` representing the multiplicative inverse of `self`,
    /// i.e. `self * self^-1 = 1`.
    ///
    /// If the number was invertible, the second element of the tuple is the truthy value,
    /// otherwise it is the falsy value (in which case the first element's value is unspecified).
    pub const fn invert(&self) -> ConstCtOption<Self> {
        let inverter = SafeGcdInverter::new_with_inverse(
            &MOD::PARAMS.modulus,
            MOD::PARAMS.mod_inv,
            &MOD::PARAMS.r2,
        );

        let maybe_inverse = inverter.invert(&self.montgomery_form);
        let (inverse, inverse_is_some) = maybe_inverse.components_ref();

        let ret = Self {
            montgomery_form: *inverse,
            phantom: PhantomData,
        };

        ConstCtOption::new(ret, inverse_is_some)
    }

    /// Computes `self^-1` representing the multiplicative inverse of `self`,
    /// i.e. `self * self^-1 = 1`.
    ///
    /// If the number was invertible, the second element of the tuple is the truthy value,
    /// otherwise it is the falsy value (in which case the first element's value is unspecified).
    ///
    /// This version is variable-time with respect to the value of `self`, but constant-time with
    /// respect to `MOD`.
    #[deprecated(since = "0.7.0", note = "please use `invert_vartime` instead")]
    pub const fn inv_vartime(&self) -> ConstCtOption<Self> {
        self.invert_vartime()
    }

    /// Computes `self^-1` representing the multiplicative inverse of `self`,
    /// i.e. `self * self^-1 = 1`.
    ///
    /// If the number was invertible, the second element of the tuple is the truthy value,
    /// otherwise it is the falsy value (in which case the first element's value is unspecified).
    ///
    /// This version is variable-time with respect to the value of `self`, but constant-time with
    /// respect to `MOD`.
    pub const fn invert_vartime(&self) -> ConstCtOption<Self> {
        let inverter = SafeGcdInverter::new_with_inverse(
            &MOD::PARAMS.modulus,
            MOD::PARAMS.mod_inv,
            &MOD::PARAMS.r2,
        );

        let maybe_inverse = inverter.invert_vartime(&self.montgomery_form);
        let (inverse, inverse_is_some) = maybe_inverse.components_ref();

        let ret = Self {
            montgomery_form: *inverse,
            phantom: PhantomData,
        };

        ConstCtOption::new(ret, inverse_is_some)
    }
}

impl<MOD: ConstMontyParams<LIMBS>, const LIMBS: usize> Invert for ConstMontyForm<MOD, LIMBS> {
    type Output = CtOption<Self>;

    fn invert(&self) -> Self::Output {
        self.invert().into()
    }

    fn invert_vartime(&self) -> Self::Output {
        self.invert_vartime().into()
    }
}

#[cfg(test)]
mod tests {
    use super::ConstMontyParams;
    use crate::{U256, const_monty_form, const_monty_params};

    const_monty_params!(
        Modulus,
        U256,
        "15477BCCEFE197328255BFA79A1217899016D927EF460F4FF404029D24FA4409"
    );

    const_monty_form!(Fe, Modulus);

    #[test]
    fn test_self_inverse() {
        let x =
            U256::from_be_hex("77117F1273373C26C700D076B3F780074D03339F56DD0EFB60E7F58441FD3685");
        let x_mod = Fe::new(&x);

        let inv = x_mod.invert().unwrap();
        let res = x_mod * inv;

        assert_eq!(res.retrieve(), U256::ONE);
    }
}
