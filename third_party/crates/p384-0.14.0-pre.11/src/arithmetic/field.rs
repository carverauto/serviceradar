//! Field arithmetic modulo p = 2^{384} − 2^{128} − 2^{96} + 2^{32} − 1
//!
//! Arithmetic implementations have been synthesized using fiat-crypto.
//!
//! # License
//!
//! Copyright (c) 2015-2020 the fiat-crypto authors
//!
//! fiat-crypto is distributed under the terms of the MIT License, the
//! Apache License (Version 2.0), and the BSD 1-Clause License;
//! users may pick which license to apply.

#[cfg(target_pointer_width = "32")]
use fiat_crypto::p384_32::*;
#[cfg(target_pointer_width = "64")]
use fiat_crypto::p384_64::*;

use elliptic_curve::{
    bigint::U384,
    ff::PrimeField,
    subtle::{Choice, ConstantTimeEq, CtOption},
};

/// Constant representing the modulus
/// p = 2^{384} − 2^{128} − 2^{96} + 2^{32} − 1
const MODULUS_HEX: &str = "fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffeffffffff0000000000000000ffffffff";

primefield::monty_field_params!(
    name: FieldParams,
    modulus: MODULUS_HEX,
    uint: U384,
    byte_order: primefield::ByteOrder::BigEndian,
    multiplicative_generator: 19,
    fe_name: "FieldElement",
    doc: "P-384 field modulus"
);

/// Element of the secp384r1 base field used for curve coordinates.
#[derive(Clone, Copy)]
pub struct FieldElement(
    pub(super) primefield::MontyFieldElement<FieldParams, { FieldParams::LIMBS }>,
);

primefield::monty_field_element!(FieldElement, FieldParams, U384);

primefield::monty_field_fiat_arithmetic!(
    FieldElement,
    FieldParams,
    U384,
    fiat_p384_non_montgomery_domain_field_element,
    fiat_p384_montgomery_domain_field_element,
    fiat_p384_from_montgomery,
    fiat_p384_to_montgomery,
    fiat_p384_add,
    fiat_p384_sub,
    fiat_p384_mul,
    fiat_p384_opp,
    fiat_p384_square,
    fiat_p384_divstep_precomp,
    fiat_p384_divstep,
    fiat_p384_msat,
    fiat_p384_selectznz
);

impl FieldElement {
    /// Returns the square root of self mod p, or `None` if no square root
    /// exists.
    pub fn sqrt(&self) -> CtOption<Self> {
        // p mod 4 = 3 -> compute sqrt(x) using x^((p+1)/4) =
        // x^9850501549098619803069760025035903451269934817616361666987073351061430442874217582261816522064734500465401743278080
        let t1 = *self;
        let t10 = t1.square();
        let t11 = t1 * t10;
        let t110 = t11.square();
        let t111 = t1 * t110;
        let t111000 = t111.sqn(3);
        let t111111 = t111 * t111000;
        let t1111110 = t111111.square();
        let t1111111 = t1 * t1111110;
        let x12 = t1111110.sqn(5) * t111111;
        let x24 = x12.sqn(12) * x12;
        let x31 = x24.sqn(7) * t1111111;
        let x32 = x31.square() * t1;
        let x63 = x32.sqn(31) * x31;
        let x126 = x63.sqn(63) * x63;
        let x252 = x126.sqn(126) * x126;
        let x255 = x252.sqn(3) * t111;
        let x = ((x255.sqn(33) * x32).sqn(64) * t1).sqn(30);
        CtOption::new(x, x.square().ct_eq(&t1))
    }

    /// Returns self^(2^n) mod p
    const fn sqn(&self, n: usize) -> Self {
        Self(self.0.sqn_vartime(n))
    }
}

#[cfg(test)]
mod tests {
    use super::{FieldElement, U384};
    primefield::test_primefield!(FieldElement, U384);
}
