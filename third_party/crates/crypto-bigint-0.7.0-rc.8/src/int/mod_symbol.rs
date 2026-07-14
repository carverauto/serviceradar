//! Support for computing modular symbols.

use crate::{ConstChoice, Int, JacobiSymbol, Odd, Uint};

impl<const LIMBS: usize> Int<LIMBS> {
    /// Compute the Jacobi symbol `(self|rhs)`.
    ///
    /// For prime `rhs`, this corresponds to the Legendre symbol and
    /// indicates whether `self` is quadratic residue modulo `rhs`.
    pub const fn jacobi_symbol(&self, rhs: &Odd<Uint<LIMBS>>) -> JacobiSymbol {
        let (abs, sign) = self.abs_sign();
        let jacobi = abs.jacobi_symbol(rhs) as i64;
        // (-self|rhs) = -(self|rhs) iff rhs = 3 mod 4
        let swap = sign.and(ConstChoice::from_word_eq(rhs.as_ref().limbs[0].0 & 3, 3));
        JacobiSymbol::from_i8(swap.select_i64(jacobi, -jacobi) as i8)
    }

    /// Compute the Jacobi symbol `(self|rhs)`.
    ///
    /// For prime `rhs`, this corresponds to the Legendre symbol and
    /// indicates whether `self` is quadratic residue modulo `rhs`.
    ///
    /// This method executes in variable-time for the value of `self`.
    pub const fn jacobi_symbol_vartime(&self, rhs: &Odd<Uint<LIMBS>>) -> JacobiSymbol {
        let (abs, sign) = self.abs_sign();
        let jacobi = abs.jacobi_symbol_vartime(rhs);
        JacobiSymbol::from_i8(
            if sign.is_true_vartime() && rhs.as_ref().limbs[0].0 & 3 == 3 {
                -(jacobi as i8)
            } else {
                jacobi as i8
            },
        )
    }
}

#[cfg(test)]
mod tests {
    use crate::{I256, JacobiSymbol, U256};

    #[test]
    fn jacobi_quad_residue() {
        // Two semiprimes with no common factors, and
        // f is quadratic residue modulo g
        let f = I256::from(59i32 * 67);
        let g = U256::from(61u32 * 71).to_odd().unwrap();
        let res = f.jacobi_symbol(&g);
        let res_vartime = f.jacobi_symbol_vartime(&g);
        assert_eq!(res, JacobiSymbol::One);
        assert_eq!(res, res_vartime);
    }

    #[test]
    fn jacobi_non_quad_residue() {
        // f and g have no common factors, but
        // f is not quadratic residue modulo g
        let f = I256::from(59i32 * 67 + 2);
        let g = U256::from(61u32 * 71).to_odd().unwrap();
        let res = f.jacobi_symbol(&g);
        let res_vartime = f.jacobi_symbol_vartime(&g);
        assert_eq!(res, JacobiSymbol::MinusOne);
        assert_eq!(res, res_vartime);
    }

    #[test]
    fn jacobi_non_coprime() {
        let f = I256::from(4391633i32);
        let g = U256::from(2022161u32).to_odd().unwrap();
        let res = f.jacobi_symbol(&g);
        let res_vartime = f.jacobi_symbol_vartime(&g);
        assert_eq!(res, JacobiSymbol::Zero);
        assert_eq!(res, res_vartime);
    }

    #[test]
    fn jacobi_zero() {
        assert_eq!(
            I256::ZERO.jacobi_symbol(&U256::ONE.to_odd().unwrap()),
            JacobiSymbol::One
        );
    }

    #[test]
    fn jacobi_neg_one() {
        let f = I256::ONE;
        assert_eq!(
            f.jacobi_symbol(&U256::ONE.to_odd().unwrap()),
            JacobiSymbol::One
        );
        assert_eq!(
            f.jacobi_symbol(&U256::from(3u8).to_odd().unwrap()),
            JacobiSymbol::One
        );
    }

    #[test]
    fn jacobi_int() {
        // Two semiprimes with no common factors, and
        // f is quadratic residue modulo g
        let f = I256::from(59i32 * 67);
        let g = U256::from(61u32 * 71).to_odd().unwrap();
        let res = f.jacobi_symbol(&g);
        let res_vartime = f.jacobi_symbol_vartime(&g);
        assert_eq!(res, JacobiSymbol::One);
        assert_eq!(res, res_vartime);

        let res = f.checked_neg().unwrap().jacobi_symbol(&g);
        let res_vartime = f.checked_neg().unwrap().jacobi_symbol_vartime(&g);
        assert_eq!(res, JacobiSymbol::MinusOne);
        assert_eq!(res, res_vartime);
    }
}
