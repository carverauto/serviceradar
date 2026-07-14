//! Subtractions between boxed integers in Montgomery form.

use super::BoxedMontyForm;
use crate::Limb;
use core::ops::{Sub, SubAssign};

impl BoxedMontyForm {
    /// Subtracts `rhs`.
    pub fn sub(&self, rhs: &Self) -> Self {
        debug_assert_eq!(self.params, rhs.params);

        Self {
            montgomery_form: self
                .montgomery_form
                .sub_mod(&rhs.montgomery_form, self.params.modulus().as_nz_ref()),
            params: self.params.clone(),
        }
    }
}

impl Sub<&BoxedMontyForm> for &BoxedMontyForm {
    type Output = BoxedMontyForm;
    fn sub(self, rhs: &BoxedMontyForm) -> BoxedMontyForm {
        debug_assert_eq!(self.params, rhs.params);
        self.sub(rhs)
    }
}

impl Sub<BoxedMontyForm> for &BoxedMontyForm {
    type Output = BoxedMontyForm;
    #[allow(clippy::op_ref)]
    fn sub(self, rhs: BoxedMontyForm) -> BoxedMontyForm {
        self - &rhs
    }
}

impl Sub<&BoxedMontyForm> for BoxedMontyForm {
    type Output = BoxedMontyForm;
    #[allow(clippy::op_ref)]
    fn sub(self, rhs: &BoxedMontyForm) -> BoxedMontyForm {
        &self - rhs
    }
}

impl Sub<BoxedMontyForm> for BoxedMontyForm {
    type Output = BoxedMontyForm;
    fn sub(self, rhs: BoxedMontyForm) -> BoxedMontyForm {
        &self - &rhs
    }
}

impl SubAssign<&BoxedMontyForm> for BoxedMontyForm {
    fn sub_assign(&mut self, rhs: &BoxedMontyForm) {
        debug_assert_eq!(self.params, rhs.params);
        self.montgomery_form.sub_assign_mod_with_carry(
            Limb::ZERO,
            &rhs.montgomery_form,
            self.params.modulus(),
        );
    }
}

impl SubAssign<BoxedMontyForm> for BoxedMontyForm {
    fn sub_assign(&mut self, rhs: BoxedMontyForm) {
        *self -= &rhs;
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
    fn sub_overflow() {
        let modulus = BoxedUint::from_be_slice(
            &hex!("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551"),
            256,
        )
        .unwrap();
        let params = BoxedMontyParams::new(modulus.to_odd().unwrap());

        let x = BoxedUint::from_be_slice(
            &hex!("44acf6b7e36c1342c2c5897204fe09504e1e2efb1a900377dbc4e7a6a133ec56"),
            256,
        )
        .unwrap();
        let mut x_mod = BoxedMontyForm::new(x, params.clone());

        let y = BoxedUint::from_be_slice(
            &hex!("d5777c45019673125ad240f83094d4252d829516fac8601ed01979ec1ec1a251"),
            256,
        )
        .unwrap();
        let y_mod = BoxedMontyForm::new(y, params);

        x_mod -= &y_mod;

        let expected = BoxedUint::from_be_slice(
            &hex!("6f357a71e1d5a03167f34879d469352add829491c6df41ddff65387d7ed56f56"),
            256,
        )
        .unwrap();

        assert_eq!(expected, x_mod.retrieve());
    }
}
