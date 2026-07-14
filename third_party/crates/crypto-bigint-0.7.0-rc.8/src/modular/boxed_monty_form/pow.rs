//! Modular exponentiation support for [`BoxedMontyForm`].

use super::{BoxedMontyForm, mul::BoxedMontyMultiplier};
use crate::{BoxedUint, ConstantTimeSelect, Limb, PowBoundedExp, Word};
use alloc::vec::Vec;
use subtle::{ConstantTimeEq, ConstantTimeLess};

impl BoxedMontyForm {
    /// Raises to the `exponent` power.
    pub fn pow(&self, exponent: &BoxedUint) -> Self {
        self.pow_bounded_exp(exponent, exponent.bits_precision())
    }

    /// Raises to the `exponent` power,
    /// with `exponent_bits` representing the number of (least significant) bits
    /// to take into account for the exponent.
    ///
    /// NOTE: `exponent_bits` may be leaked in the time pattern.
    pub fn pow_bounded_exp(&self, exponent: &BoxedUint, exponent_bits: u32) -> Self {
        let ret = Self {
            montgomery_form: pow_montgomery_form(
                &self.montgomery_form,
                exponent,
                exponent_bits,
                self.params.modulus(),
                self.params.one(),
                self.params.mod_neg_inv(),
            ),
            params: self.params.clone(),
        };

        debug_assert!(&ret.retrieve() < self.params.modulus());
        ret
    }
}

impl PowBoundedExp<BoxedUint> for BoxedMontyForm {
    fn pow_bounded_exp(&self, exponent: &BoxedUint, exponent_bits: u32) -> Self {
        self.pow_bounded_exp(exponent, exponent_bits)
    }
}

/// Performs modular exponentiation using Montgomery's ladder.
///
/// `exponent_bits` represents the length of the exponent in bits.
///
/// NOTE: `exponent_bits` is leaked in the time pattern.
fn pow_montgomery_form(
    x: &BoxedUint,
    exponent: &BoxedUint,
    exponent_bits: u32,
    modulus: &BoxedUint,
    one: &BoxedUint,
    mod_neg_inv: Limb,
) -> BoxedUint {
    if exponent_bits == 0 {
        return one.clone(); // 1 in Montgomery form
    }

    const WINDOW: u32 = 4;
    const WINDOW_MASK: Word = (1 << WINDOW) - 1;

    let mut multiplier = BoxedMontyMultiplier::new(modulus, mod_neg_inv);

    // powers[i] contains x^i
    let mut powers = Vec::with_capacity(1 << WINDOW);
    powers.push(one.clone()); // 1 in Montgomery form
    powers.push(x.clone());

    for i in 2..(1 << WINDOW) {
        powers.push(multiplier.mul_amm(&powers[i - 1], x));
    }

    let starting_limb = ((exponent_bits - 1) / Limb::BITS) as usize;
    let starting_bit_in_limb = (exponent_bits - 1) % Limb::BITS;
    let starting_window = starting_bit_in_limb / WINDOW;
    let starting_window_mask = (1 << (starting_bit_in_limb % WINDOW + 1)) - 1;

    let mut z = one.clone(); // 1 in Montgomery form
    let mut power = powers[0].clone();

    for limb_num in (0..=starting_limb).rev() {
        let w = exponent.as_limbs()[limb_num].0;

        let mut window_num = if limb_num == starting_limb {
            starting_window + 1
        } else {
            Limb::BITS / WINDOW
        };

        while window_num > 0 {
            window_num -= 1;

            let mut idx = (w >> (window_num * WINDOW)) & WINDOW_MASK;

            if limb_num == starting_limb && window_num == starting_window {
                idx &= starting_window_mask;
            } else {
                for _ in 1..=WINDOW {
                    multiplier.square_amm_assign(&mut z);
                }
            }

            // Constant-time lookup in the array of powers
            power.limbs.copy_from_slice(&powers[0].limbs);
            for i in 1..(1 << WINDOW) {
                power.ct_assign(&powers[i as usize], i.ct_eq(&idx));
            }

            multiplier.mul_amm_assign(&mut z, &power);
        }
    }

    // Ensure the output is properly reduced.
    //
    // Using the properties of `almost_montgomery_mul()` (see its documentation):
    // - We have an incoming `x` which is fully reduced (`floor(x / modulus) = 0`).
    // - We build an array of `powers` which are produced by multiplying the previous power by `x`,
    //   so for each power `floor(power / modulus) <= 1`.
    // - Then we take turns squaring the accumulator `z` (bringing `floor(z / modulus)` to 1
    //   regardless of the previous reduction level) and multiplying by a power of `x`
    //   (bringing `floor(z / modulus)` to at most 2).
    // - Then we either exit the loop, or square again, which brings `floor(z / modulus)` back to 1.
    //
    // Now that we exited the loop, we need to reduce `z` at most twice
    // to bring it within `[0, modulus)`.

    z.conditional_borrowing_sub_assign(modulus, !z.ct_lt(modulus));
    z.conditional_borrowing_sub_assign(modulus, !z.ct_lt(modulus));
    debug_assert!(&z < modulus);

    z
}
