//! Implements `MontyForm`s, supporting modular arithmetic with a modulus set at runtime.

mod add;
pub(super) mod invert;
mod lincomb;
mod mod_symbol;
mod mul;
mod neg;
mod pow;
mod sub;

use super::{
    Retrieve,
    const_monty_form::{ConstMontyForm, ConstMontyParams},
    div_by_2::div_by_2,
    reduction::{montgomery_reduction, montgomery_retrieve},
};
use crate::{ConstChoice, Limb, Monty, Odd, U64, Uint, Word};
use mul::DynMontyMultiplier;
use subtle::{Choice, ConditionallySelectable, ConstantTimeEq};

/// Parameters to efficiently go to/from the Montgomery form for an odd modulus provided at runtime.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct MontyParams<const LIMBS: usize> {
    /// The constant modulus
    pub(super) modulus: Odd<Uint<LIMBS>>,
    /// 1 in Montgomery form (a.k.a. `R`)
    pub(super) one: Uint<LIMBS>,
    /// `R^2 mod modulus`, used to move into Montgomery form
    pub(super) r2: Uint<LIMBS>,
    /// The lowest limbs of MODULUS^-1 mod 2**64
    /// This value is used in Montgomery reduction and modular inversion
    pub(super) mod_inv: U64,
    /// Leading zeros in the modulus, used to choose optimized algorithms
    pub(super) mod_leading_zeros: u32,
}

impl<const LIMBS: usize> MontyParams<LIMBS> {
    /// Instantiates a new set of `MontyParams` representing the given odd `modulus`.
    pub const fn new(modulus: Odd<Uint<LIMBS>>) -> Self {
        // `R mod modulus` where `R = 2^BITS`.
        // Represents 1 in Montgomery form.
        let one = Uint::<LIMBS>::MAX
            .rem(modulus.as_nz_ref())
            .wrapping_add(&Uint::ONE);

        // `R^2 mod modulus`, used to convert integers to Montgomery form.
        let r2 = one.square_mod(modulus.as_nz_ref());

        // The inverse of the modulus modulo 2**64
        let mod_inv = U64::from_u64(modulus.as_uint_ref().invert_mod_u64());

        let mod_leading_zeros = modulus.as_ref().leading_zeros();
        let mod_leading_zeros = ConstChoice::from_u32_lt(mod_leading_zeros, Word::BITS - 1)
            .select_u32(Word::BITS - 1, mod_leading_zeros);

        Self {
            modulus,
            one,
            r2,
            mod_inv,
            mod_leading_zeros,
        }
    }
}

impl<const LIMBS: usize> MontyParams<LIMBS> {
    /// Instantiates a new set of `MontyParams` representing the given odd `modulus`.
    pub const fn new_vartime(modulus: Odd<Uint<LIMBS>>) -> Self {
        // `R mod modulus` where `R = 2^BITS`.
        // Represents 1 in Montgomery form.
        let one = Uint::MAX
            .rem_vartime(modulus.as_nz_ref())
            .wrapping_add(&Uint::ONE);

        // `R^2 mod modulus`, used to convert integers to Montgomery form.
        let r2 = one.square_mod_vartime(modulus.as_nz_ref());

        // The inverse of the modulus modulo 2**64
        let mod_inv = U64::from_u64(modulus.as_uint_ref().invert_mod_u64());

        let mod_leading_zeros = modulus.as_ref().leading_zeros_vartime();
        let mod_leading_zeros = if mod_leading_zeros < Word::BITS - 1 {
            mod_leading_zeros
        } else {
            Word::BITS - 1
        };

        Self {
            modulus,
            one,
            r2,
            mod_inv,
            mod_leading_zeros,
        }
    }

    /// Returns the modulus which was used to initialize these parameters.
    pub const fn modulus(&self) -> &Odd<Uint<LIMBS>> {
        &self.modulus
    }

    /// 1 in Montgomery form (a.k.a. `R`).
    pub const fn one(&self) -> &Uint<LIMBS> {
        &self.one
    }

    /// `R^2 mod modulus`, used to move into Montgomery form.
    pub const fn r2(&self) -> &Uint<LIMBS> {
        &self.r2
    }

    /// Returns the modulus which was used to initialize these parameters.
    #[inline(always)]
    pub(crate) const fn mod_neg_inv(&self) -> Limb {
        self.mod_inv.limbs[0].wrapping_neg()
    }
}

impl<const LIMBS: usize> ConditionallySelectable for MontyParams<LIMBS> {
    fn conditional_select(a: &Self, b: &Self, choice: Choice) -> Self {
        Self {
            modulus: Odd::conditional_select(&a.modulus, &b.modulus, choice),
            one: Uint::conditional_select(&a.one, &b.one, choice),
            r2: Uint::conditional_select(&a.r2, &b.r2, choice),
            mod_inv: U64::conditional_select(&a.mod_inv, &b.mod_inv, choice),
            mod_leading_zeros: u32::conditional_select(
                &a.mod_leading_zeros,
                &b.mod_leading_zeros,
                choice,
            ),
        }
    }
}

impl<const LIMBS: usize> ConstantTimeEq for MontyParams<LIMBS> {
    fn ct_eq(&self, other: &Self) -> Choice {
        self.modulus.ct_eq(&other.modulus)
            & self.one.ct_eq(&other.one)
            & self.r2.ct_eq(&other.r2)
            & self.mod_inv.ct_eq(&other.mod_inv)
    }
}

#[cfg(feature = "zeroize")]
impl<const LIMBS: usize> zeroize::Zeroize for MontyParams<LIMBS> {
    fn zeroize(&mut self) {
        self.modulus.zeroize();
        self.one.zeroize();
        self.r2.zeroize();
        self.mod_inv.zeroize();
        self.mod_leading_zeros.zeroize();
    }
}

/// An integer in Montgomery form represented using `LIMBS` limbs.
/// The odd modulus is set at runtime.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MontyForm<const LIMBS: usize> {
    montgomery_form: Uint<LIMBS>,
    params: MontyParams<LIMBS>,
}

impl<const LIMBS: usize> MontyForm<LIMBS> {
    /// Instantiates a new `MontyForm` that represents this `integer` mod `MOD`.
    pub const fn new(integer: &Uint<LIMBS>, params: MontyParams<LIMBS>) -> Self {
        let product = integer.widening_mul(&params.r2);
        let montgomery_form = montgomery_reduction(&product, &params.modulus, params.mod_neg_inv());

        Self {
            montgomery_form,
            params,
        }
    }

    /// Retrieves the integer currently encoded in this `MontyForm`, guaranteed to be reduced.
    pub const fn retrieve(&self) -> Uint<LIMBS> {
        montgomery_retrieve(
            &self.montgomery_form,
            &self.params.modulus,
            self.params.mod_neg_inv(),
        )
    }

    /// Instantiates a new `MontyForm` that represents zero.
    pub const fn zero(params: MontyParams<LIMBS>) -> Self {
        Self {
            montgomery_form: Uint::<LIMBS>::ZERO,
            params,
        }
    }

    /// Instantiates a new `MontyForm` that represents 1.
    pub const fn one(params: MontyParams<LIMBS>) -> Self {
        Self {
            montgomery_form: params.one,
            params,
        }
    }

    /// Returns the parameter struct used to initialize this object.
    pub const fn params(&self) -> &MontyParams<LIMBS> {
        &self.params
    }

    /// Access the `MontyForm` value in Montgomery form.
    pub const fn as_montgomery(&self) -> &Uint<LIMBS> {
        &self.montgomery_form
    }

    /// Mutably access the `MontyForm` value in Montgomery form.
    pub fn as_montgomery_mut(&mut self) -> &mut Uint<LIMBS> {
        &mut self.montgomery_form
    }

    /// Create a `MontyForm` from a value in Montgomery form.
    pub const fn from_montgomery(integer: Uint<LIMBS>, params: MontyParams<LIMBS>) -> Self {
        Self {
            montgomery_form: integer,
            params,
        }
    }

    /// Extract the value from the `MontyForm` in Montgomery form.
    pub const fn to_montgomery(&self) -> Uint<LIMBS> {
        self.montgomery_form
    }

    /// Performs division by 2, that is returns `x` such that `x + x = self`.
    pub const fn div_by_2(&self) -> Self {
        Self {
            montgomery_form: div_by_2(&self.montgomery_form, &self.params.modulus),
            params: self.params,
        }
    }
}

impl<const LIMBS: usize> Retrieve for MontyForm<LIMBS> {
    type Output = Uint<LIMBS>;
    fn retrieve(&self) -> Self::Output {
        self.retrieve()
    }
}

impl<const LIMBS: usize> Monty for MontyForm<LIMBS> {
    type Integer = Uint<LIMBS>;
    type Params = MontyParams<LIMBS>;
    type Multiplier<'a> = DynMontyMultiplier<'a, LIMBS>;

    fn new_params_vartime(modulus: Odd<Self::Integer>) -> Self::Params {
        MontyParams::new_vartime(modulus)
    }

    fn new(value: Self::Integer, params: Self::Params) -> Self {
        MontyForm::new(&value, params)
    }

    fn zero(params: Self::Params) -> Self {
        MontyForm::zero(params)
    }

    fn one(params: Self::Params) -> Self {
        MontyForm::one(params)
    }

    fn params(&self) -> &Self::Params {
        &self.params
    }

    fn as_montgomery(&self) -> &Self::Integer {
        &self.montgomery_form
    }

    fn copy_montgomery_from(&mut self, other: &Self) {
        debug_assert_eq!(self.params, other.params);
        self.montgomery_form = other.montgomery_form;
    }

    fn double(&self) -> Self {
        MontyForm::double(self)
    }

    fn div_by_2(&self) -> Self {
        MontyForm::div_by_2(self)
    }

    fn lincomb_vartime(products: &[(&Self, &Self)]) -> Self {
        MontyForm::lincomb_vartime(products)
    }
}

impl<const LIMBS: usize, P: ConstMontyParams<LIMBS>> From<&ConstMontyForm<P, LIMBS>>
    for MontyForm<LIMBS>
{
    fn from(const_monty_form: &ConstMontyForm<P, LIMBS>) -> Self {
        Self {
            montgomery_form: const_monty_form.to_montgomery(),
            params: P::PARAMS,
        }
    }
}

impl<const LIMBS: usize> ConditionallySelectable for MontyForm<LIMBS> {
    fn conditional_select(a: &Self, b: &Self, choice: Choice) -> Self {
        Self {
            montgomery_form: Uint::conditional_select(
                &a.montgomery_form,
                &b.montgomery_form,
                choice,
            ),
            params: MontyParams::conditional_select(&a.params, &b.params, choice),
        }
    }
}

impl<const LIMBS: usize> ConstantTimeEq for MontyForm<LIMBS> {
    fn ct_eq(&self, other: &Self) -> Choice {
        self.montgomery_form.ct_eq(&other.montgomery_form) & self.params.ct_eq(&other.params)
    }
}

#[cfg(feature = "zeroize")]
impl<const LIMBS: usize> zeroize::Zeroize for MontyForm<LIMBS> {
    fn zeroize(&mut self) {
        self.montgomery_form.zeroize();
        self.params.zeroize();
    }
}

#[cfg(test)]
mod tests {
    use super::MontyParams;
    use crate::{Limb, Odd, Uint};

    #[test]
    fn new_params_with_valid_modulus() {
        let modulus = Odd::new(Uint::from(3u8)).unwrap();
        let params = MontyParams::<1>::new(modulus);

        assert_eq!(params.mod_leading_zeros, Limb::BITS - 2);
    }
}
