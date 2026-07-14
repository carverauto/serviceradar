use crate::{Odd, Uint};

pub(crate) const fn add_montgomery_form<const LIMBS: usize>(
    a: &Uint<LIMBS>,
    b: &Uint<LIMBS>,
    modulus: &Odd<Uint<LIMBS>>,
) -> Uint<LIMBS> {
    a.add_mod(b, modulus.as_nz_ref())
}

pub(crate) const fn double_montgomery_form<const LIMBS: usize>(
    a: &Uint<LIMBS>,
    modulus: &Odd<Uint<LIMBS>>,
) -> Uint<LIMBS> {
    a.double_mod(modulus.as_nz_ref())
}
