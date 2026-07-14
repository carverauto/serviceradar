//! Support for computing modular symbols.

use crate::{JacobiSymbol, Odd, U64, U128, Uint};

impl<const LIMBS: usize> Uint<LIMBS> {
    /// Compute the Jacobi symbol `(self|rhs)`.
    ///
    /// For prime `rhs`, this corresponds to the Legendre symbol and
    /// indicates whether `self` is quadratic residue modulo `rhs`.
    pub const fn jacobi_symbol(&self, rhs: &Odd<Uint<LIMBS>>) -> JacobiSymbol {
        let (gcd, jacobi_neg) = if LIMBS < 4 {
            rhs.classic_bingcd_(self)
        } else {
            rhs.optimized_bingcd_::<{ U64::BITS }, { U64::LIMBS }, { U128::LIMBS }>(
                self,
                U64::BITS - 2,
            )
        };
        // The sign of the Jacobi symbol is represented by jacobi_neg. We select 0 as the
        // symbol when the GCD is not one, otherwise 1 or -1.
        let jacobi = (jacobi_neg as i8 * -2 + 1) as i64;
        JacobiSymbol::from_i8(Uint::eq(gcd.as_ref(), &Uint::ONE).select_i64(0, jacobi) as i8)
    }

    /// Compute the Jacobi symbol `(self|rhs)`.
    ///
    /// For prime `rhs`, this corresponds to the Legendre symbol and
    /// indicates whether `self` is quadratic residue modulo `rhs`.
    ///
    /// This method executes in variable-time for both inputs.
    pub const fn jacobi_symbol_vartime(&self, rhs: &Odd<Uint<LIMBS>>) -> JacobiSymbol {
        let (gcd, jacobi_neg) = if LIMBS < 4 {
            rhs.classic_bingcd_vartime_(self)
        } else {
            rhs.optimized_bingcd_vartime_::<{ U64::BITS }, { U64::LIMBS }, { U128::LIMBS }>(
                self,
                U64::BITS - 2,
            )
        };
        JacobiSymbol::from_i8(if gcd.as_ref().cmp_vartime(&Uint::ONE).is_eq() {
            jacobi_neg as i8 * -2 + 1
        } else {
            0
        })
    }
}

#[cfg(test)]
mod tests {
    use crate::{JacobiSymbol, U256};

    #[test]
    fn jacobi_quad_residue() {
        // Two semiprimes with no common factors, and
        // f is quadratic residue modulo g
        let f = U256::from(59u32 * 67);
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
        let f = U256::from(59u32 * 67 + 2);
        let g = U256::from(61u32 * 71).to_odd().unwrap();
        let res = f.jacobi_symbol(&g);
        let res_vartime = f.jacobi_symbol_vartime(&g);
        assert_eq!(res, JacobiSymbol::MinusOne);
        assert_eq!(res, res_vartime);
    }

    #[test]
    fn jacobi_non_coprime() {
        let f = U256::from(4391633u32);
        let g = U256::from(2022161u32).to_odd().unwrap();
        let res = f.jacobi_symbol(&g);
        let res_vartime = f.jacobi_symbol_vartime(&g);
        assert_eq!(res, JacobiSymbol::Zero);
        assert_eq!(res, res_vartime);
    }

    #[test]
    fn jacobi_zero() {
        let f = U256::ZERO;
        let g = U256::ONE.to_odd().unwrap();
        let res = f.jacobi_symbol(&g);
        let res_vartime = f.jacobi_symbol_vartime(&g);
        assert_eq!(res, JacobiSymbol::One);
        assert_eq!(res, res_vartime);
    }

    #[test]
    fn jacobi_one() {
        let f = U256::ONE;
        let g = U256::ONE.to_odd().unwrap();
        let res = f.jacobi_symbol(&g);
        let res_vartime = f.jacobi_symbol_vartime(&g);
        assert_eq!(res, JacobiSymbol::One);
        assert_eq!(res, res_vartime);
    }
}
