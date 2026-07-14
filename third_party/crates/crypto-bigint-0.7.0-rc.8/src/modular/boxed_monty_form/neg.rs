//! Negations of boxed integers in Montgomery form.

use super::BoxedMontyForm;
use core::ops::Neg;

impl BoxedMontyForm {
    /// Negates the number.
    pub fn neg(&self) -> Self {
        Self {
            montgomery_form: self
                .montgomery_form
                .neg_mod(self.params.modulus().as_nz_ref()),
            params: self.params.clone(),
        }
    }
}

impl Neg for BoxedMontyForm {
    type Output = Self;
    fn neg(self) -> Self {
        BoxedMontyForm::neg(&self)
    }
}

impl Neg for &BoxedMontyForm {
    type Output = BoxedMontyForm;
    fn neg(self) -> BoxedMontyForm {
        BoxedMontyForm::neg(self)
    }
}

#[cfg(test)]
mod tests {
    use crate::{
        BoxedUint,
        modular::{BoxedMontyForm, BoxedMontyParams},
    };
    use hex_literal::hex;

    #[test]
    fn neg_expected() {
        let modulus = BoxedUint::from_be_slice(
            &hex!("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551"),
            256,
        )
        .expect("error creating modulus");
        let params = BoxedMontyParams::new(modulus.to_odd().unwrap());

        let x = BoxedUint::from_be_slice(
            &hex!("44acf6b7e36c1342c2c5897204fe09504e1e2efb1a900377dbc4e7a6a133ec56"),
            256,
        )
        .expect("error creating boxeduint");
        let x_mod = BoxedMontyForm::new(x, params.clone());

        assert!(bool::from((x_mod.neg() + x_mod).is_zero()));
    }
}
