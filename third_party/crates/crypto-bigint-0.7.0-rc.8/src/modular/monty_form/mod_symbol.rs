//! Modular symbol calculation for integers in Montgomery form with a constant modulus.

use crate::JacobiSymbol;

use super::MontyForm;

impl<const LIMBS: usize> MontyForm<LIMBS> {
    /// Compute the Jacobi symbol `(self|modulus)`.
    ///
    /// For a prime modulus, this corresponds to the Legendre symbol and indicates
    /// whether `self` is quadratic residue.
    pub const fn jacobi_symbol(&self) -> JacobiSymbol {
        self.retrieve().jacobi_symbol(self.params().modulus())
    }

    /// Compute the Jacobi symbol `(self|modulus)`.
    ///
    /// For a prime modulus, this corresponds to the Legendre symbol and indicates
    /// whether `self` is quadratic residue.
    ///
    /// This method is variable-time with respect to the value of `self`.
    pub const fn jacobi_symbol_vartime(&self) -> JacobiSymbol {
        self.retrieve()
            .jacobi_symbol_vartime(self.params().modulus())
    }
}

#[cfg(test)]
mod tests {
    use crate::{
        JacobiSymbol, Odd, U256,
        modular::{MontyForm, MontyParams},
    };

    const PARAMS: MontyParams<{ U256::LIMBS }> =
        MontyParams::new_vartime(Odd::<U256>::from_be_hex(
            "2523648240000001BA344D80000000086121000000000013A700000000000013",
        ));

    #[test]
    fn jacobi_quad_residue() {
        let x =
            U256::from_be_hex("14BFAE46F4026E97C7A3FCD889B379A5F025719911C994A594FC6C5092AC58B1");
        let x_mod = MontyForm::new(&x, PARAMS);

        let jac = x_mod.jacobi_symbol();
        let jac_vartime = x_mod.jacobi_symbol_vartime();
        assert_eq!(jac, JacobiSymbol::One);
        assert_eq!(jac, jac_vartime);
    }

    #[test]
    fn jacobi_quad_nonresidue() {
        let x =
            U256::from_be_hex("1D2EFB21D283A2DDE77004B9DE9A9624F7B15CEEF055CD02E9EF1A9F1B76F253");
        let x_mod = MontyForm::new(&x, PARAMS);

        let jac = x_mod.jacobi_symbol();
        let jac_vartime = x_mod.jacobi_symbol_vartime();
        assert_eq!(jac, JacobiSymbol::MinusOne);
        assert_eq!(jac, jac_vartime);
    }
}
