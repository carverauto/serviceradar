//! Exponentiation of integers in Montgomery form with a modulus set at runtime.

use super::MontyForm;
use crate::{
    MultiExponentiateBoundedExp, PowBoundedExp, Uint,
    modular::pow::{multi_exponentiate_montgomery_form_array, pow_montgomery_form},
};

#[cfg(feature = "alloc")]
use {crate::modular::pow::multi_exponentiate_montgomery_form_slice, alloc::vec::Vec};

impl<const LIMBS: usize> MontyForm<LIMBS> {
    /// Raises to the `exponent` power.
    pub const fn pow<const RHS_LIMBS: usize>(
        &self,
        exponent: &Uint<RHS_LIMBS>,
    ) -> MontyForm<LIMBS> {
        self.pow_bounded_exp(exponent, Uint::<RHS_LIMBS>::BITS)
    }

    /// Raises to the `exponent` power,
    /// with `exponent_bits` representing the number of (least significant) bits
    /// to take into account for the exponent.
    ///
    /// NOTE: `exponent_bits` may be leaked in the time pattern.
    pub const fn pow_bounded_exp<const RHS_LIMBS: usize>(
        &self,
        exponent: &Uint<RHS_LIMBS>,
        exponent_bits: u32,
    ) -> Self {
        Self {
            montgomery_form: pow_montgomery_form(
                &self.montgomery_form,
                exponent,
                exponent_bits,
                &self.params.modulus,
                &self.params.one,
                self.params.mod_neg_inv(),
            ),
            params: self.params,
        }
    }
}

impl<const LIMBS: usize, const RHS_LIMBS: usize> PowBoundedExp<Uint<RHS_LIMBS>>
    for MontyForm<LIMBS>
{
    fn pow_bounded_exp(&self, exponent: &Uint<RHS_LIMBS>, exponent_bits: u32) -> Self {
        self.pow_bounded_exp(exponent, exponent_bits)
    }
}

impl<const N: usize, const LIMBS: usize, const RHS_LIMBS: usize>
    MultiExponentiateBoundedExp<Uint<RHS_LIMBS>, [(Self, Uint<RHS_LIMBS>); N]>
    for MontyForm<LIMBS>
{
    fn multi_exponentiate_bounded_exp(
        bases_and_exponents: &[(Self, Uint<RHS_LIMBS>); N],
        exponent_bits: u32,
    ) -> Self {
        assert!(N != 0, "bases_and_exponents must not be empty");
        let params = bases_and_exponents[0].0.params;

        let mut bases_and_exponents_montgomery_form =
            [(Uint::<LIMBS>::ZERO, Uint::<RHS_LIMBS>::ZERO); N];

        let mut i = 0;
        while i < N {
            let (base, exponent) = bases_and_exponents[i];
            bases_and_exponents_montgomery_form[i] = (base.montgomery_form, exponent);
            i += 1;
        }

        Self {
            montgomery_form: multi_exponentiate_montgomery_form_array(
                &bases_and_exponents_montgomery_form,
                exponent_bits,
                &params.modulus,
                &params.one,
                params.mod_neg_inv(),
            ),
            params,
        }
    }
}

#[cfg(feature = "alloc")]
impl<const LIMBS: usize, const RHS_LIMBS: usize>
    MultiExponentiateBoundedExp<Uint<RHS_LIMBS>, [(Self, Uint<RHS_LIMBS>)]> for MontyForm<LIMBS>
{
    fn multi_exponentiate_bounded_exp(
        bases_and_exponents: &[(Self, Uint<RHS_LIMBS>)],
        exponent_bits: u32,
    ) -> Self {
        assert!(
            !bases_and_exponents.is_empty(),
            "bases_and_exponents must not be empty"
        );
        let params = bases_and_exponents[0].0.params;

        let bases_and_exponents: Vec<(Uint<LIMBS>, Uint<RHS_LIMBS>)> = bases_and_exponents
            .iter()
            .map(|(base, exp)| (base.montgomery_form, *exp))
            .collect();
        Self {
            montgomery_form: multi_exponentiate_montgomery_form_slice(
                &bases_and_exponents,
                exponent_bits,
                &params.modulus,
                &params.one,
                params.mod_neg_inv(),
            ),
            params,
        }
    }
}
