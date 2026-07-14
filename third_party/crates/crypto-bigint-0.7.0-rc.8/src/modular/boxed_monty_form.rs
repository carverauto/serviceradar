//! Implements heap-allocated `BoxedMontyForm`s, supporting modular arithmetic with a modulus set at runtime.

mod add;
mod invert;
mod lincomb;
mod mul;
mod neg;
mod pow;
mod sub;

use super::{MontyParams, Retrieve, div_by_2, reduction::montgomery_retrieve_inner};
use crate::{BoxedUint, Limb, Monty, Odd, U64, Word};
use mul::BoxedMontyMultiplier;

use alloc::sync::Arc;
use subtle::Choice;

#[cfg(feature = "zeroize")]
use zeroize::Zeroize;

/// Parameters to efficiently go to/from the Montgomery form for an odd modulus whose size and value
/// are both chosen at runtime.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BoxedMontyParams(Arc<BoxedMontyParamsInner>);

#[derive(Clone, Debug, Eq, PartialEq)]
struct BoxedMontyParamsInner {
    /// The constant modulus
    modulus: Odd<BoxedUint>,
    /// Parameter used in Montgomery reduction
    one: BoxedUint,
    /// R^2, used to move into Montgomery form
    r2: BoxedUint,
    /// The lowest limbs of MODULUS^-1 mod 2**64
    /// This value is used in Montgomery reduction and modular inversion
    mod_inv: U64,
    /// Leading zeros in the modulus, used to choose optimized algorithms
    mod_leading_zeros: u32,
}

impl BoxedMontyParams {
    /// Instantiates a new set of [`BoxedMontyParams`] representing the given `modulus`.
    ///
    /// TODO(tarcieri): DRY out with `MontyParams::new`?
    pub fn new(modulus: Odd<BoxedUint>) -> Self {
        let bits_precision = modulus.bits_precision();

        // `R mod modulus` where `R = 2^BITS`.
        // Represents 1 in Montgomery form.
        let one = BoxedUint::max(bits_precision)
            .rem(modulus.as_nz_ref())
            .wrapping_add(&BoxedUint::one());

        // `R^2 mod modulus`, used to convert integers to Montgomery form.
        let r2 = one.square_mod(modulus.as_nz_ref());

        // The inverse of the modulus modulo 2**64
        let mod_inv = U64::from_u64(modulus.as_uint_ref().invert_mod_u64());

        let mod_leading_zeros = modulus.as_ref().leading_zeros().min(Word::BITS - 1);

        Self(
            BoxedMontyParamsInner {
                modulus,
                one,
                r2,
                mod_inv,
                mod_leading_zeros,
            }
            .into(),
        )
    }

    /// Instantiates a new set of [`BoxedMontyParams`] representing the given `modulus`.
    /// This version operates in variable-time with respect to the modulus.
    ///
    /// TODO(tarcieri): DRY out with `MontyParams::new`?
    pub fn new_vartime(modulus: Odd<BoxedUint>) -> Self {
        let bits_precision = modulus.bits_precision();

        // `R mod modulus` where `R = 2^BITS`.
        // Represents 1 in Montgomery form.
        let one = BoxedUint::max(bits_precision)
            .rem_vartime(modulus.as_nz_ref())
            .wrapping_add(&BoxedUint::one());

        // `R^2 mod modulus`, used to convert integers to Montgomery form.
        let r2 = one.square_mod_vartime(modulus.as_nz_ref());

        // The inverse of the modulus modulo 2**64
        let mod_inv = U64::from_u64(modulus.as_uint_ref().invert_mod_u64());

        let mod_leading_zeros = modulus.as_ref().leading_zeros().min(Word::BITS - 1);

        Self(
            BoxedMontyParamsInner {
                modulus,
                one,
                r2,
                mod_inv,
                mod_leading_zeros,
            }
            .into(),
        )
    }

    /// Modulus value.
    pub fn modulus(&self) -> &Odd<BoxedUint> {
        &self.0.modulus
    }

    /// Bits of precision in the modulus.
    pub fn bits_precision(&self) -> u32 {
        self.0.modulus.bits_precision()
    }

    pub(crate) fn r2(&self) -> &BoxedUint {
        &self.0.r2
    }

    pub(crate) fn one(&self) -> &BoxedUint {
        &self.0.one
    }

    pub(crate) fn mod_inv(&self) -> U64 {
        self.0.mod_inv
    }

    pub(crate) fn mod_neg_inv(&self) -> Limb {
        self.0.mod_inv.limbs[0].wrapping_neg()
    }

    pub(crate) fn mod_leading_zeros(&self) -> u32 {
        self.0.mod_leading_zeros
    }
}

impl<const LIMBS: usize> From<&MontyParams<LIMBS>> for BoxedMontyParams {
    fn from(params: &MontyParams<LIMBS>) -> Self {
        Self(
            BoxedMontyParamsInner {
                modulus: params.modulus.into(),
                one: params.one.into(),
                r2: params.r2.into(),
                mod_inv: params.mod_inv,
                mod_leading_zeros: params.mod_leading_zeros,
            }
            .into(),
        )
    }
}

impl<const LIMBS: usize> From<MontyParams<LIMBS>> for BoxedMontyParams {
    fn from(params: MontyParams<LIMBS>) -> Self {
        BoxedMontyParams::from(&params)
    }
}

/// An integer in Montgomery form represented using heap-allocated limbs.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BoxedMontyForm {
    /// Value in the Montgomery form.
    montgomery_form: BoxedUint,

    /// Montgomery form parameters.
    params: BoxedMontyParams,
}

impl BoxedMontyForm {
    /// Instantiates a new [`BoxedMontyForm`] that represents an integer modulo the provided params.
    pub fn new(mut integer: BoxedUint, params: BoxedMontyParams) -> Self {
        debug_assert_eq!(integer.bits_precision(), params.bits_precision());
        convert_to_montgomery(&mut integer, &params);

        #[allow(clippy::useless_conversion)]
        Self {
            montgomery_form: integer,
            params,
        }
    }

    /// Bits of precision in the modulus.
    pub fn bits_precision(&self) -> u32 {
        self.params.bits_precision()
    }

    /// Retrieves the integer currently encoded in this [`BoxedMontyForm`], guaranteed to be reduced.
    pub fn retrieve(&self) -> BoxedUint {
        let mut out = BoxedUint::zero_with_precision(self.bits_precision());
        montgomery_retrieve_inner(
            &self.montgomery_form.limbs,
            &mut out.limbs,
            self.params.modulus().as_ref().as_limbs(),
            self.params.mod_neg_inv(),
        );
        out
    }

    /// Instantiates a new `ConstMontyForm` that represents zero.
    pub fn zero(params: BoxedMontyParams) -> Self {
        Self {
            montgomery_form: BoxedUint::zero_with_precision(params.bits_precision()),
            params,
        }
    }

    /// Instantiates a new `ConstMontyForm` that represents 1.
    pub fn one(params: BoxedMontyParams) -> Self {
        Self {
            montgomery_form: params.one().clone(),
            params,
        }
    }

    /// Determine if this value is equal to zero.
    ///
    /// # Returns
    ///
    /// If zero, returns `Choice(1)`. Otherwise, returns `Choice(0)`.
    pub fn is_zero(&self) -> Choice {
        self.montgomery_form.is_zero()
    }

    /// Determine if this value is not equal to zero.
    ///
    /// # Returns
    ///
    /// If zero, returns `Choice(0)`. Otherwise, returns `Choice(1)`.
    #[inline]
    pub fn is_nonzero(&self) -> Choice {
        !self.is_zero()
    }

    /// Returns the parameter struct used to initialize this object.
    pub fn params(&self) -> &BoxedMontyParams {
        &self.params
    }

    /// Access the [`BoxedMontyForm`] value in Montgomery form.
    pub fn as_montgomery(&self) -> &BoxedUint {
        debug_assert!(&self.montgomery_form < self.params.modulus());
        &self.montgomery_form
    }

    /// Create a [`BoxedMontyForm`] from a value in Montgomery form.
    pub fn from_montgomery(integer: BoxedUint, params: BoxedMontyParams) -> Self {
        debug_assert_eq!(integer.bits_precision(), params.bits_precision());
        Self {
            montgomery_form: integer,
            params,
        }
    }

    /// Extract the value from the [`BoxedMontyForm`] in Montgomery form.
    pub fn to_montgomery(&self) -> BoxedUint {
        debug_assert!(&self.montgomery_form < self.params.modulus());
        self.montgomery_form.clone()
    }

    /// Performs division by 2, that is returns `x` such that `x + x = self`.
    pub fn div_by_2(&self) -> Self {
        Self {
            montgomery_form: div_by_2::div_by_2_boxed(&self.montgomery_form, self.params.modulus()),
            params: self.params.clone(),
        }
    }

    /// Performs division by 2 inplace, that is finds `x` such that `x + x = self`
    /// and writes it into `self`.
    pub fn div_by_2_assign(&mut self) {
        div_by_2::div_by_2_boxed_assign(&mut self.montgomery_form, self.params.modulus())
    }
}

impl Retrieve for BoxedMontyForm {
    type Output = BoxedUint;
    fn retrieve(&self) -> BoxedUint {
        self.retrieve()
    }
}

impl Monty for BoxedMontyForm {
    type Integer = BoxedUint;
    type Params = BoxedMontyParams;
    type Multiplier<'a> = BoxedMontyMultiplier<'a>;

    fn new_params_vartime(modulus: Odd<Self::Integer>) -> Self::Params {
        BoxedMontyParams::new_vartime(modulus)
    }

    fn new(value: Self::Integer, params: Self::Params) -> Self {
        BoxedMontyForm::new(value, params)
    }

    fn zero(params: Self::Params) -> Self {
        BoxedMontyForm::zero(params)
    }

    fn one(params: Self::Params) -> Self {
        BoxedMontyForm::one(params)
    }

    fn params(&self) -> &Self::Params {
        &self.params
    }

    fn as_montgomery(&self) -> &Self::Integer {
        &self.montgomery_form
    }

    fn copy_montgomery_from(&mut self, other: &Self) {
        debug_assert_eq!(
            self.montgomery_form.bits_precision(),
            other.montgomery_form.bits_precision()
        );
        debug_assert_eq!(self.params, other.params);
        self.montgomery_form
            .limbs
            .copy_from_slice(&other.montgomery_form.limbs);
    }

    fn double(&self) -> Self {
        BoxedMontyForm::double(self)
    }

    fn div_by_2(&self) -> Self {
        BoxedMontyForm::div_by_2(self)
    }

    fn div_by_2_assign(&mut self) {
        BoxedMontyForm::div_by_2_assign(self)
    }

    fn lincomb_vartime(products: &[(&Self, &Self)]) -> Self {
        BoxedMontyForm::lincomb_vartime(products)
    }
}

/// NOTE: This zeroizes the value, but _not_ the associated parameters!
#[cfg(feature = "zeroize")]
impl Zeroize for BoxedMontyForm {
    fn zeroize(&mut self) {
        self.montgomery_form.zeroize();
    }
}

/// Convert the given integer into the Montgomery domain.
#[inline]
fn convert_to_montgomery(integer: &mut BoxedUint, params: &BoxedMontyParams) {
    let mut mm = BoxedMontyMultiplier::from(params);
    mm.mul_assign(integer, params.r2());
}

#[cfg(test)]
mod tests {
    use super::{BoxedMontyForm, BoxedMontyParams};
    use crate::{BoxedUint, Limb, Odd};

    #[test]
    fn new_params_with_valid_modulus() {
        let modulus = Odd::new(BoxedUint::from(3u8)).unwrap();
        let params = BoxedMontyParams::new(modulus);

        assert_eq!(params.mod_leading_zeros(), Limb::BITS - 2);
    }

    #[test]
    fn div_by_2() {
        let modulus = Odd::new(BoxedUint::from(9u8)).unwrap();
        let params = BoxedMontyParams::new(modulus);
        let zero = BoxedMontyForm::zero(params.clone());
        let one = BoxedMontyForm::one(params.clone());
        let two = one.add(&one);

        assert_eq!(zero.div_by_2(), zero);
        assert_eq!(one.div_by_2().mul(&two), one);
    }
}
