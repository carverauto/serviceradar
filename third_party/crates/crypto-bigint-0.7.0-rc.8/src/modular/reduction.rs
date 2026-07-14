//! Modular reduction implementation.

use crate::{Limb, Odd, Uint};

/// Algorithm 14.32 in Handbook of Applied Cryptography <https://cacr.uwaterloo.ca/hac/about/chap14.pdf>
#[inline(always)]
const fn montgomery_reduction_inner(
    upper: &mut [Limb],
    lower: &mut [Limb],
    modulus: &[Limb],
    mod_neg_inv: Limb,
) -> Limb {
    let nlimbs = modulus.len();
    debug_assert!(nlimbs == upper.len());
    debug_assert!(nlimbs == lower.len());

    let mut meta_carry = Limb::ZERO;
    let mut new_sum;

    let mut i = 0;
    while i < nlimbs {
        let u = lower[i].wrapping_mul(mod_neg_inv);

        let (_, mut carry) = u.carrying_mul_add(modulus[0], lower[i], Limb::ZERO);
        let mut new_limb;

        let mut j = 1;
        while j < (nlimbs - i) {
            (new_limb, carry) = u.carrying_mul_add(modulus[j], lower[i + j], carry);
            lower[i + j] = new_limb;
            j += 1;
        }
        while j < nlimbs {
            (new_limb, carry) = u.carrying_mul_add(modulus[j], upper[i + j - nlimbs], carry);
            upper[i + j - nlimbs] = new_limb;
            j += 1;
        }

        (new_sum, meta_carry) = upper[i].carrying_add(carry, meta_carry);
        upper[i] = new_sum;

        i += 1;
    }

    meta_carry
}

/// Algorithm 14.32 in Handbook of Applied Cryptography <https://cacr.uwaterloo.ca/hac/about/chap14.pdf>
pub(crate) const fn montgomery_reduction<const LIMBS: usize>(
    lower_upper: &(Uint<LIMBS>, Uint<LIMBS>),
    modulus: &Odd<Uint<LIMBS>>,
    mod_neg_inv: Limb,
) -> Uint<LIMBS> {
    let (mut lower, mut upper) = *lower_upper;
    let meta_carry = montgomery_reduction_inner(
        &mut upper.limbs,
        &mut lower.limbs,
        &modulus.0.limbs,
        mod_neg_inv,
    );

    // Division is simply taking the upper half of the limbs
    // Final reduction (at this point, the value is at most 2 * modulus,
    // so `meta_carry` is either 0 or 1)
    upper.sub_mod_with_carry(meta_carry, &modulus.0, &modulus.0)
}

/// This algorithm corresponds to a Montgomery reduction of the wide input `(x, 0)`,
/// Algorithm 14.32 in Handbook of Applied Cryptography <https://cacr.uwaterloo.ca/hac/about/chap14.pdf>
/// Or to a Montgomery multiplication of `x` by `1` (Algorithm 14.36).
/// This version does not produce a carry and does not need further correction by
/// subtracting the modulus as long as `x < modulus`. This is guaranteed because
/// `x < modulus => u < modulus => ((x + u•modulus) << N) < modulus`.
#[inline(always)]
pub const fn montgomery_retrieve_inner(
    x: &[Limb],
    out: &mut [Limb],
    modulus: &[Limb],
    mod_neg_inv: Limb,
) {
    let nlimbs = modulus.len();
    assert!(nlimbs == x.len() && nlimbs == out.len());

    let mut i = 0;
    while i < nlimbs {
        let xi = x[i];
        let u = out[0].wrapping_add(xi).wrapping_mul(mod_neg_inv);

        out[0] = u.carrying_mul_add(modulus[0], xi, out[0]).1;

        let mut j = 1;
        while j < nlimbs {
            (out[j - 1], out[j]) = u.carrying_mul_add(modulus[j], out[j], out[j - 1]);
            j += 1;
        }

        i += 1;
    }
}

/// For input `x < modulus` in Montgomery form, compute `x•R^-1 mod modulus`.
pub const fn montgomery_retrieve<const LIMBS: usize>(
    montgomery_form: &Uint<LIMBS>,
    modulus: &Odd<Uint<LIMBS>>,
    mod_neg_inv: Limb,
) -> Uint<LIMBS> {
    debug_assert!(Uint::lt(montgomery_form, modulus.as_ref()).is_true_vartime());
    let mut res = Uint::ZERO;
    montgomery_retrieve_inner(
        montgomery_form.as_limbs(),
        res.as_mut_limbs(),
        modulus.0.as_limbs(),
        mod_neg_inv,
    );
    res
}
