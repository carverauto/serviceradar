use crate::{Odd, Uint};

pub(crate) const fn sub_montgomery_form<const LIMBS: usize>(
    a: &Uint<LIMBS>,
    b: &Uint<LIMBS>,
    modulus: &Odd<Uint<LIMBS>>,
) -> Uint<LIMBS> {
    a.sub_mod(b, modulus.as_nz_ref())
}
