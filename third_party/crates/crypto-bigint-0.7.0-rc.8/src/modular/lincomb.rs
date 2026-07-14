use crate::{Limb, Odd, Uint, modular::MontyForm};

use super::{ConstMontyForm, ConstMontyParams};

#[cfg(feature = "alloc")]
use super::BoxedMontyForm;
#[cfg(feature = "alloc")]
use crate::BoxedUint;

/// Implement the coarse interleaved sum of products (Algorithm 2 for B=1) from
/// Efficient Algorithms for Large Prime Characteristic Fields and Their Application
/// to Bilinear Pairings by Patrick Longa. https://eprint.iacr.org/2022/367
///
/// For correct results, the un-reduced sum of products must not exceed `p•R`  where `p`
/// is the modulus. Given a list of pairs `(a_1, b_1)..(a_k, b_k)` in Montgomery form,
/// where each `a_i < p` and `b_i < p`, we have `sum(a_i•b_i) < k•p^2` and so up to
/// `k = floor(R/p)` pairs may be safely accumulated per call.
///
/// This is implemented as a macro to abstract over `const fn` and boxed use cases, since the latter
/// needs mutable references and thus the unstable `const_mut_refs` feature (rust-lang/rust#57349).
///
// TODO: change this into a `const fn` when `const_mut_refs` is stable
macro_rules! impl_longa_monty_lincomb {
    ($a_b:expr, $u:expr, $modulus:expr, $mod_neg_inv:expr, $nlimbs:expr) => {{
        let len = $a_b.len();
        let mut hi_carry = Limb::ZERO;
        let mut hi;
        let mut carry;

        let mut j = 0;
        while j < $nlimbs {
            hi = hi_carry;
            hi_carry = Limb::ZERO;

            let mut i = 0;
            while i < len {
                let (ai, bi) = &$a_b[i];
                carry = Limb::ZERO;

                let mut k = 0;
                while k < $nlimbs {
                    ($u[k], carry) = ai.as_montgomery().limbs[j].carrying_mul_add(
                        bi.as_montgomery().limbs[k],
                        $u[k],
                        carry,
                    );
                    k += 1;
                }
                (hi, carry) = hi.carrying_add(carry, Limb::ZERO);
                hi_carry = hi_carry.wrapping_add(carry);

                i += 1;
            }

            let q = $u[0].wrapping_mul($mod_neg_inv);

            (_, carry) = q.carrying_mul_add($modulus[0], $u[0], Limb::ZERO);

            i = 1;
            while i < $nlimbs {
                ($u[i - 1], carry) = q.carrying_mul_add($modulus[i], $u[i], carry);
                i += 1;
            }
            ($u[$nlimbs - 1], carry) = hi.carrying_add(carry, Limb::ZERO);
            hi_carry = hi_carry.wrapping_add(carry);

            j += 1;
        }

        hi_carry
    }};
}

pub const fn lincomb_const_monty_form<MOD: ConstMontyParams<LIMBS>, const LIMBS: usize>(
    mut products: &[(ConstMontyForm<MOD, LIMBS>, ConstMontyForm<MOD, LIMBS>)],
    modulus: &Odd<Uint<LIMBS>>,
    mod_neg_inv: Limb,
) -> Uint<LIMBS> {
    let max_accum = 1 << (MOD::PARAMS.mod_leading_zeros as usize);
    let mut ret = Uint::ZERO;
    let mut remain = products.len();
    if remain <= max_accum {
        let carry =
            impl_longa_monty_lincomb!(products, ret.limbs, modulus.0.limbs, mod_neg_inv, LIMBS);
        ret.sub_mod_with_carry(carry, &modulus.0, &modulus.0)
    } else {
        let mut window;
        while remain > 0 {
            let mut buf = Uint::ZERO;
            let mut count = remain;
            if count > max_accum {
                count = max_accum;
            }
            (window, products) = products.split_at(count);
            let carry =
                impl_longa_monty_lincomb!(window, buf.limbs, modulus.0.limbs, mod_neg_inv, LIMBS);
            buf = buf.sub_mod_with_carry(carry, &modulus.0, &modulus.0);
            ret = ret.add_mod(&buf, modulus.as_nz_ref());
            remain -= count;
        }
        ret
    }
}

pub const fn lincomb_monty_form<const LIMBS: usize>(
    mut products: &[(&MontyForm<LIMBS>, &MontyForm<LIMBS>)],
    modulus: &Odd<Uint<LIMBS>>,
    mod_neg_inv: Limb,
    mod_leading_zeros: u32,
) -> Uint<LIMBS> {
    let max_accum = 1 << (mod_leading_zeros as usize);
    let mut ret = Uint::ZERO;
    let mut remain = products.len();
    if remain <= max_accum {
        let carry =
            impl_longa_monty_lincomb!(products, ret.limbs, modulus.0.limbs, mod_neg_inv, LIMBS);
        ret.sub_mod_with_carry(carry, &modulus.0, &modulus.0)
    } else {
        let mut window;
        while remain > 0 {
            let mut count = remain;
            if count > max_accum {
                count = max_accum;
            }
            (window, products) = products.split_at(count);
            let mut buf = Uint::ZERO;
            let carry =
                impl_longa_monty_lincomb!(window, buf.limbs, modulus.0.limbs, mod_neg_inv, LIMBS);
            buf = buf.sub_mod_with_carry(carry, &modulus.0, &modulus.0);
            ret = ret.add_mod(&buf, modulus.as_nz_ref());
            remain -= count;
        }
        ret
    }
}

#[cfg(feature = "alloc")]
pub fn lincomb_boxed_monty_form(
    mut products: &[(&BoxedMontyForm, &BoxedMontyForm)],
    modulus: &Odd<BoxedUint>,
    mod_neg_inv: Limb,
    mod_leading_zeros: u32,
) -> BoxedUint {
    let max_accum = 1 << (mod_leading_zeros as usize);
    let nlimbs = modulus.0.nlimbs();
    let mut ret = BoxedUint::zero_with_precision(modulus.0.bits_precision());
    let mut remain = products.len();
    if remain <= max_accum {
        let carry =
            impl_longa_monty_lincomb!(products, ret.limbs, modulus.0.limbs, mod_neg_inv, nlimbs);
        ret.sub_assign_mod_with_carry(carry, &modulus.0, &modulus.0);
    } else {
        let mut window;
        let mut buf = BoxedUint::zero_with_precision(modulus.0.bits_precision());
        while remain > 0 {
            buf.limbs.fill(Limb::ZERO);
            let mut count = remain;
            if count > max_accum {
                count = max_accum;
            }
            (window, products) = products.split_at(count);
            let carry =
                impl_longa_monty_lincomb!(window, buf.limbs, modulus.0.limbs, mod_neg_inv, nlimbs);
            buf.sub_assign_mod_with_carry(carry, &modulus.0, &modulus.0);
            let carry = ret.carrying_add_assign(&buf, Limb::ZERO);
            ret.sub_assign_mod_with_carry(carry, &modulus.0, &modulus.0);
            remain -= count;
        }
    }
    ret
}
