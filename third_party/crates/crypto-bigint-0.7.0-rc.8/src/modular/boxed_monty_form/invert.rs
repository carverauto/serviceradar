//! Multiplicative inverses of boxed integers in Montgomery form.

use super::{BoxedMontyForm, BoxedMontyParams};
use crate::{Invert, modular::safegcd::boxed::BoxedSafeGcdInverter};
use subtle::CtOption;

impl BoxedMontyForm {
    /// Computes `self^-1` representing the multiplicative inverse of `self`,
    /// i.e. `self * self^-1 = 1`.
    pub fn invert(&self) -> CtOption<Self> {
        let montgomery_form = self.params.inverter().invert(&self.montgomery_form);
        let is_some = montgomery_form.is_some();
        let montgomery_form2 = self.montgomery_form.clone();
        let ret = BoxedMontyForm {
            montgomery_form: Option::from(montgomery_form).unwrap_or(montgomery_form2),
            params: self.params.clone(),
        };

        CtOption::new(ret, is_some)
    }

    /// Computes `self^-1` representing the multiplicative inverse of `self`,
    /// i.e. `self * self^-1 = 1`.
    ///
    /// This version is variable-time with respect to the self of `self`, but constant-time with
    /// respect to `self`'s `params`.
    pub fn invert_vartime(&self) -> CtOption<Self> {
        let montgomery_form = self.params.inverter().invert_vartime(&self.montgomery_form);
        let is_some = montgomery_form.is_some();
        let montgomery_form2 = self.montgomery_form.clone();
        let ret = BoxedMontyForm {
            montgomery_form: Option::from(montgomery_form).unwrap_or(montgomery_form2),
            params: self.params.clone(),
        };

        CtOption::new(ret, is_some)
    }
}

impl Invert for BoxedMontyForm {
    type Output = CtOption<Self>;

    fn invert(&self) -> Self::Output {
        self.invert()
    }

    fn invert_vartime(&self) -> Self::Output {
        self.invert_vartime()
    }
}

impl BoxedMontyParams {
    /// Compute the inverter for these params.
    fn inverter(&self) -> BoxedSafeGcdInverter {
        BoxedSafeGcdInverter::new_with_inverse(
            self.modulus().clone(),
            self.mod_inv(),
            self.r2().clone(),
        )
    }
}

#[cfg(test)]
mod tests {
    use crate::{
        BoxedUint,
        modular::{BoxedMontyForm, BoxedMontyParams},
    };
    use hex_literal::hex;

    fn monty_params() -> BoxedMontyParams {
        BoxedMontyParams::new(
            BoxedUint::from_be_slice(
                &hex!("15477BCCEFE197328255BFA79A1217899016D927EF460F4FF404029D24FA4409"),
                256,
            )
            .unwrap()
            .to_odd()
            .unwrap(),
        )
    }

    #[test]
    fn test_self_inverse() {
        let params = monty_params();
        let x = BoxedUint::from_be_slice(
            &hex!("77117F1273373C26C700D076B3F780074D03339F56DD0EFB60E7F58441FD3685"),
            256,
        )
        .unwrap();
        let x_mod = BoxedMontyForm::new(x, params);

        let inv = x_mod.invert().unwrap();
        let res = x_mod * inv;

        assert!(bool::from(res.retrieve().is_one()));
    }
}
