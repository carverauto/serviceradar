use super::reduction::montgomery_reduction;
use crate::{Limb, Odd, Uint};

pub(crate) const fn mul_montgomery_form<const LIMBS: usize>(
    a: &Uint<LIMBS>,
    b: &Uint<LIMBS>,
    modulus: &Odd<Uint<LIMBS>>,
    mod_neg_inv: Limb,
) -> Uint<LIMBS> {
    let product = a.widening_mul(b);
    montgomery_reduction::<LIMBS>(&product, modulus, mod_neg_inv)
}

pub(crate) const fn square_montgomery_form<const LIMBS: usize>(
    a: &Uint<LIMBS>,
    modulus: &Odd<Uint<LIMBS>>,
    mod_neg_inv: Limb,
) -> Uint<LIMBS> {
    let product = a.square_wide();
    montgomery_reduction::<LIMBS>(&product, modulus, mod_neg_inv)
}
