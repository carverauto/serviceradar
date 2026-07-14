//! Multiplicative inverses of integers in Montgomery form with a modulus set at runtime.

use super::{MontyForm, MontyParams};
use crate::{ConstCtOption, modular::SafeGcdInverter, traits::Invert};
use subtle::CtOption;

impl<const LIMBS: usize> MontyForm<LIMBS> {
    /// Computes `self^-1` representing the multiplicative inverse of `self`.
    /// i.e. `self * self^-1 = 1`.
    ///
    /// If the number was invertible, the second element of the tuple is the truthy value,
    /// otherwise it is the falsy value (in which case the first element's value is unspecified).
    #[deprecated(since = "0.7.0", note = "please use `invert` instead")]
    pub const fn inv(&self) -> ConstCtOption<Self> {
        self.invert()
    }

    /// Computes `self^-1` representing the multiplicative inverse of `self`.
    /// i.e. `self * self^-1 = 1`.
    ///
    /// If the number was invertible, the second element of the tuple is the truthy value,
    /// otherwise it is the falsy value (in which case the first element's value is unspecified).
    pub const fn invert(&self) -> ConstCtOption<Self> {
        let inverter = self.params.inverter();
        let maybe_inverse = inverter.invert(&self.montgomery_form);
        let (inverse, inverse_is_some) = maybe_inverse.components_ref();

        let ret = Self {
            montgomery_form: *inverse,
            params: self.params,
        };

        ConstCtOption::new(ret, inverse_is_some)
    }

    /// Computes `self^-1` representing the multiplicative inverse of `self`.
    /// i.e. `self * self^-1 = 1`.
    ///
    /// If the number was invertible, the second element of the tuple is the truthy value,
    /// otherwise it is the falsy value (in which case the first element's value is unspecified).
    ///
    /// This version is variable-time with respect to the value of `self`, but constant-time with
    /// respect to `self`'s `params`.
    #[deprecated(since = "0.7.0", note = "please use `invert_vartime` instead")]
    pub const fn inv_vartime(&self) -> ConstCtOption<Self> {
        self.invert_vartime()
    }

    /// Computes `self^-1` representing the multiplicative inverse of `self`.
    /// i.e. `self * self^-1 = 1`.
    ///
    /// If the number was invertible, the second element of the tuple is the truthy value,
    /// otherwise it is the falsy value (in which case the first element's value is unspecified).
    ///
    /// This version is variable-time with respect to the value of `self`, but constant-time with
    /// respect to `self`'s `params`.
    pub const fn invert_vartime(&self) -> ConstCtOption<Self> {
        let inverter = self.params.inverter();
        let maybe_inverse = inverter.invert_vartime(&self.montgomery_form);
        let (inverse, inverse_is_some) = maybe_inverse.components_ref();

        let ret = Self {
            montgomery_form: *inverse,
            params: self.params,
        };

        ConstCtOption::new(ret, inverse_is_some)
    }
}

impl<const LIMBS: usize> Invert for MontyForm<LIMBS> {
    type Output = CtOption<Self>;

    fn invert(&self) -> Self::Output {
        self.invert().into()
    }

    fn invert_vartime(&self) -> Self::Output {
        self.invert_vartime().into()
    }
}

impl<const LIMBS: usize> MontyParams<LIMBS> {
    /// Create a modular inverter for the modulus of these params.
    const fn inverter(&self) -> SafeGcdInverter<LIMBS> {
        SafeGcdInverter::new_with_inverse(&self.modulus, self.mod_inv, &self.r2)
    }
}

#[cfg(test)]
mod tests {
    use super::{MontyForm, MontyParams};
    use crate::{Odd, U256};

    fn params() -> MontyParams<{ U256::LIMBS }> {
        MontyParams::new_vartime(Odd::<U256>::from_be_hex(
            "15477BCCEFE197328255BFA79A1217899016D927EF460F4FF404029D24FA4409",
        ))
    }

    #[test]
    fn test_self_inverse() {
        let params = params();
        let x =
            U256::from_be_hex("77117F1273373C26C700D076B3F780074D03339F56DD0EFB60E7F58441FD3685");
        let x_monty = MontyForm::new(&x, params);

        let inv = x_monty.invert().unwrap();
        let res = x_monty * inv;

        assert_eq!(res.retrieve(), U256::ONE);
    }
}
