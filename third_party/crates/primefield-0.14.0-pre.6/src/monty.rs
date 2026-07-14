//! Field elements which use an internal Montgomery form representation, implemented using
//! `crypto-bigint`'s [`MontyForm`].

use crate::ByteOrder;
use bigint::{
    ArrayEncoding, ByteArray, Integer, Invert, Reduce, Uint, Word,
    hybrid_array::{Array, ArraySize, typenum::Unsigned},
    modular::{ConstMontyForm as MontyForm, ConstMontyParams},
};
use core::{
    cmp::Ordering,
    fmt,
    iter::{Product, Sum},
    ops::{Add, AddAssign, Mul, MulAssign, Neg, Sub, SubAssign},
};
use ff::{Field, PrimeField};
use subtle::{
    Choice, ConditionallySelectable, ConstantTimeEq, ConstantTimeGreater, ConstantTimeLess,
    CtOption,
};

/// Extension trait for defining additional field parameters beyond the ones provided by
/// [`ConstMontyParams`].
pub trait MontyFieldParams<const LIMBS: usize>: ConstMontyParams<LIMBS> {
    /// Size of a field element when serialized as bytes.
    type ByteSize: ArraySize;

    /// Byte order to use when serializing a field element as byte.
    const BYTE_ORDER: ByteOrder;

    /// Type name to use in the `Debug` impl on elements of this field.
    const FIELD_ELEMENT_NAME: &'static str;

    /// Field modulus as a hexadecimal string.
    const MODULUS_HEX: &'static str;

    /// A fixed multiplicative generator of `modulus - 1` order.
    ///
    /// This element must also be a quadratic nonresidue.
    const MULTIPLICATIVE_GENERATOR: u64;

    /// `t = (modulus - 1) >> s`, where `S = (modulus - 1).trailing_zeros()`
    const T: &'static [u64];

    /// Compute modular square root.
    // TODO(tarcieri): generic implementations of various algorithms e.g. Tonelli–Shanks
    fn sqrt(_: &MontyFieldElement<Self, LIMBS>) -> CtOption<MontyFieldElement<Self, LIMBS>> {
        todo!()
    }
}

/// Serialized representation of a field element.
pub type MontyFieldBytes<MOD, const LIMBS: usize> =
    Array<u8, <MOD as MontyFieldParams<LIMBS>>::ByteSize>;

/// Field element type which uses an internal Montgomery form representation.
#[derive(Clone, Copy)]
pub struct MontyFieldElement<MOD, const LIMBS: usize>
where
    MOD: MontyFieldParams<LIMBS>,
{
    inner: MontyForm<MOD, LIMBS>,
}

impl<MOD, const LIMBS: usize> MontyFieldElement<MOD, LIMBS>
where
    MOD: MontyFieldParams<LIMBS>,
{
    /// Zero element (additive identity).
    pub const ZERO: Self = Self {
        inner: MontyForm::ZERO,
    };

    /// Multiplicative identity.
    pub const ONE: Self = Self {
        inner: MontyForm::ONE,
    };

    /// Number of limbs used by the internal integer representation.
    pub const LIMBS: usize = LIMBS;

    /// Decode field element from a canonical bytestring representation.
    #[inline]
    pub fn from_bytes(repr: &MontyFieldBytes<MOD, LIMBS>) -> CtOption<Self>
    where
        Uint<LIMBS>: ArrayEncoding,
    {
        let mut byte_array = ByteArray::<Uint<LIMBS>>::default();
        debug_assert!(repr.len() <= byte_array.len());

        let offset = byte_array.len().saturating_sub(repr.len());
        let uint = match MOD::BYTE_ORDER {
            ByteOrder::BigEndian => {
                byte_array[offset..].copy_from_slice(repr);
                Uint::from_be_byte_array(byte_array)
            }
            ByteOrder::LittleEndian => {
                byte_array[..offset].copy_from_slice(repr);
                Uint::from_le_byte_array(byte_array)
            }
        };

        Self::from_uint(&uint)
    }

    /// Decode field element from a canonical byte slice.
    ///
    /// Slice is expected to be zero padded to the expected byte size.
    #[inline]
    pub fn from_slice(slice: &[u8]) -> Option<Self>
    where
        Uint<LIMBS>: ArrayEncoding,
    {
        let array = Array::try_from(slice).ok()?;
        Self::from_bytes(&array).into()
    }

    /// Decode a field element from hex-encoded bytes.
    ///
    /// This is primarily intended for defining constants using hex literals.
    ///
    /// # Panics
    ///
    /// - When hex is malformed
    /// - When input is the wrong length
    /// - If input overflows the modulus
    pub const fn from_hex_vartime(hex: &str) -> Self {
        let uint = match MOD::BYTE_ORDER {
            ByteOrder::BigEndian => Uint::from_be_hex(hex),
            ByteOrder::LittleEndian => Uint::from_le_hex(hex),
        };

        assert!(
            uint.cmp_vartime(MOD::PARAMS.modulus().as_ref()).is_lt(),
            "hex encoded field element overflows modulus"
        );

        Self::from_uint_reduced(&uint)
    }

    /// Convert [`Uint`] into [`MontyFieldElement`], first converting it into Montgomery form:
    ///
    /// ```text
    /// w * R^2 * R^-1 mod p = wR mod p
    /// ```
    ///
    /// Reduces the input modulo `p`.
    #[inline]
    pub const fn from_uint_reduced(uint: &Uint<LIMBS>) -> Self {
        Self {
            inner: MontyForm::new(uint),
        }
    }

    /// Convert [`Uint`] into [`MontyFieldElement`], first converting it into Montgomery form:
    ///
    /// ```text
    /// w * R^2 * R^-1 mod p = wR mod p
    /// ```
    ///
    /// # Returns
    ///
    /// The `CtOption` equivalent of `None` if the input overflows the modulus.
    #[inline]
    pub fn from_uint(uint: &Uint<LIMBS>) -> CtOption<Self> {
        let is_some = uint.ct_lt(MOD::PARAMS.modulus());

        // TODO(tarcieri): avoid unnecessary reduction here
        CtOption::new(Self::from_uint_reduced(uint), is_some)
    }

    /// Convert a `u64` into a [`MontyFieldElement`].
    ///
    /// # Panics
    ///
    /// If the modulus is 64-bits or smaller.
    #[inline]
    pub const fn from_u64(w: u64) -> Self {
        if MOD::PARAMS.modulus().as_ref().bits() <= 64 {
            panic!("modulus is too small to ensure all u64s are in range");
        }

        Self::from_uint_reduced(&Uint::from_u64(w))
    }

    /// Create [`MontyFieldElement`] from a [`Uint`] which is already in Montgomery form.
    ///
    /// #⚠️Warning
    ///
    /// This value is expected to be in Montgomery form and reduced. Failure to maintain these
    /// invariants will lead to miscomputation and potential security issues!
    #[inline]
    pub const fn from_montgomery(uint: Uint<LIMBS>) -> Self {
        Self {
            inner: MontyForm::from_montgomery(uint),
        }
    }

    /// Helper function to construct [`MontyFieldElement`] from words in Montgomery form.
    // TODO(tarcieri): this is here to simplify the inner type conversion for fiat-crypto.
    // After we've successfully done that, it would be good to try to remove this
    #[inline]
    pub const fn from_montgomery_words(words: [Word; LIMBS]) -> Self {
        Self::from_montgomery(Uint::from_words(words))
    }

    /// Borrow the inner [`Uint`] type which is in Montgomery form.
    ///
    /// #⚠️Warning
    ///
    /// Make sure you are actually expecting a value in Montgomery form! This is not the correct
    /// function for converting *out* of Montgomery form: that would be
    /// [`MontyFieldElement::to_canonical`].
    pub const fn as_montgomery(&self) -> &Uint<LIMBS> {
        self.inner.as_montgomery()
    }

    /// Retrieve the Montgomery form representation as an array of [`Word`]s.
    // TODO(tarcieri): like `from_montgomery_words`, phase this out after fiat-crypto is migrated
    pub const fn to_montgomery_words(&self) -> [Word; LIMBS] {
        self.as_montgomery().to_words()
    }

    /// Returns the bytestring encoding of this field element.
    #[inline]
    pub fn to_bytes(self) -> MontyFieldBytes<MOD, LIMBS>
    where
        MOD: MontyFieldParams<LIMBS>,
        Uint<LIMBS>: ArrayEncoding,
    {
        let mut repr = MontyFieldBytes::<MOD, LIMBS>::default();
        debug_assert!(repr.len() <= <Uint::<LIMBS> as ArrayEncoding>::ByteSize::USIZE);

        let offset = <Uint<LIMBS> as ArrayEncoding>::ByteSize::USIZE.saturating_sub(repr.len());

        match MOD::BYTE_ORDER {
            ByteOrder::BigEndian => {
                let padded = self.inner.retrieve().to_be_byte_array();
                repr.copy_from_slice(&padded[offset..]);
            }
            ByteOrder::LittleEndian => {
                let padded = self.inner.retrieve().to_le_byte_array();
                repr.copy_from_slice(&padded[..offset]);
            }
        }

        repr
    }

    /// Determine if this field element is odd: `self mod 2 == 1`.
    ///
    /// # Returns
    ///
    /// If odd, return `Choice(1)`.  Otherwise, return `Choice(0)`.
    #[inline]
    pub fn is_odd(&self) -> Choice {
        self.inner.retrieve().is_odd()
    }

    /// Determine if this field element is even: `self mod 2 == 0`.
    ///
    /// # Returns
    ///
    /// If even, return `Choice(1)`.  Otherwise, return `Choice(0)`.
    #[inline]
    pub fn is_even(&self) -> Choice {
        !self.is_odd()
    }

    /// Determine if this field element is zero.
    ///
    /// # Returns
    ///
    /// If zero, return `Choice(1)`.  Otherwise, return `Choice(0)`.
    #[inline]
    pub fn is_zero(&self) -> Choice {
        self.ct_eq(&Self::ZERO)
    }

    /// Translate field element out of the Montgomery domain, returning a [`Uint`] in canonical form.
    #[inline]
    pub const fn to_canonical(self) -> Uint<LIMBS> {
        self.inner.retrieve()
    }

    /// Add elements.
    #[inline]
    pub const fn add(&self, rhs: &Self) -> Self {
        Self {
            inner: MontyForm::add(&self.inner, &rhs.inner),
        }
    }

    /// Double element (add it to itself).
    #[inline]
    #[must_use]
    pub const fn double(&self) -> Self {
        self.add(self)
    }

    /// Subtract elements.
    #[inline]
    pub const fn sub(&self, rhs: &Self) -> Self {
        Self {
            inner: MontyForm::sub(&self.inner, &rhs.inner),
        }
    }

    /// Multiply elements.
    #[inline]
    pub const fn multiply(&self, rhs: &Self) -> Self {
        Self {
            inner: MontyForm::mul(&self.inner, &rhs.inner),
        }
    }

    /// Negate element.
    #[inline]
    pub const fn neg(&self) -> Self {
        Self {
            inner: MontyForm::neg(&self.inner),
        }
    }

    /// Compute modular square.
    #[inline]
    #[must_use]
    pub const fn square(&self) -> Self {
        self.multiply(self)
    }

    /// Compute field inversion: `1 / self`.
    #[inline]
    pub fn invert(&self) -> CtOption<Self> {
        CtOption::from(self.inner.invert()).map(|inner| Self { inner })
    }

    /// Compute field inversion as a `const fn`. Panics if `self` is zero.
    ///
    /// This is mainly intended for inverting constants at compile time.
    pub const fn const_invert(&self) -> Self {
        Self {
            inner: self
                .inner
                .invert()
                .expect("input to invert should be non-zero"),
        }
    }

    /// Returns `self^exp`, where `exp` is a little-endian integer exponent
    ///
    /// **This operation is variable time with respect to the exponent.**
    ///
    /// If the exponent is fixed, this operation is constant time.
    pub const fn pow_vartime(&self, exp: &[u64]) -> Self {
        let mut res = Self::ONE;
        let mut i = exp.len();

        while i > 0 {
            i -= 1;

            let mut j = 64;
            while j > 0 {
                j -= 1;
                res = res.square();

                if ((exp[i] >> j) & 1) == 1 {
                    res = res.multiply(self);
                }
            }
        }

        res
    }

    /// Returns self^(2^n) mod p.
    ///
    /// Variable-time with respect to `n`.
    pub const fn sqn_vartime(&self, n: usize) -> Self {
        let mut x = *self;
        let mut i = 0;
        while i < n {
            x = x.square();
            i += 1;
        }
        x
    }
}

//
// `ff` crate trait impls
//

impl<MOD, const LIMBS: usize> Field for MontyFieldElement<MOD, LIMBS>
where
    MOD: MontyFieldParams<LIMBS>,
    MontyFieldBytes<MOD, LIMBS>: Copy,
    Uint<LIMBS>: ArrayEncoding,
{
    const ZERO: Self = Self::ZERO;
    const ONE: Self = Self::ONE;

    fn try_from_rng<R: rand_core::TryRngCore + ?Sized>(rng: &mut R) -> Result<Self, R::Error> {
        let mut bytes = MontyFieldBytes::<MOD, LIMBS>::default();

        loop {
            rng.try_fill_bytes(&mut bytes)?;
            if let Some(fe) = Self::from_bytes(&bytes).into() {
                return Ok(fe);
            }
        }
    }

    fn is_zero(&self) -> Choice {
        Self::ZERO.ct_eq(self)
    }

    fn square(&self) -> Self {
        self.square()
    }

    fn double(&self) -> Self {
        self.double()
    }

    fn invert(&self) -> CtOption<Self> {
        self.invert()
    }

    fn sqrt(&self) -> CtOption<Self> {
        MOD::sqrt(self)
    }

    fn sqrt_ratio(num: &Self, div: &Self) -> (Choice, Self) {
        ff::helpers::sqrt_ratio_generic(num, div)
    }
}

impl<MOD, const LIMBS: usize> PrimeField for MontyFieldElement<MOD, LIMBS>
where
    MOD: MontyFieldParams<LIMBS>,
    MontyFieldBytes<MOD, LIMBS>: Copy,
    Uint<LIMBS>: ArrayEncoding,
{
    type Repr = MontyFieldBytes<MOD, LIMBS>;

    const MODULUS: &'static str = MOD::MODULUS_HEX;
    const NUM_BITS: u32 = MOD::PARAMS.modulus().as_ref().bits();
    const CAPACITY: u32 = Self::NUM_BITS - 1; // TODO(tarcieri): less naive calculation?
    const TWO_INV: Self = Self::from_u64(2).const_invert();
    const MULTIPLICATIVE_GENERATOR: Self = Self::from_u64(MOD::MULTIPLICATIVE_GENERATOR);
    const S: u32 = compute_s(MOD::PARAMS.modulus().as_ref());
    const ROOT_OF_UNITY: Self = Self::MULTIPLICATIVE_GENERATOR.pow_vartime(MOD::T);
    const ROOT_OF_UNITY_INV: Self = Self::ROOT_OF_UNITY.const_invert();
    const DELTA: Self = Self::MULTIPLICATIVE_GENERATOR.sqn_vartime(Self::S as usize);

    fn from_repr(bytes: Self::Repr) -> CtOption<Self> {
        Self::from_bytes(&bytes)
    }

    fn to_repr(&self) -> Self::Repr {
        self.to_bytes()
    }

    fn is_odd(&self) -> Choice {
        self.is_odd()
    }
}

//
// Arithmetic trait impls
//

/// Emit a `core::ops` trait wrapper for an inherent method.
macro_rules! monty_field_op {
    ($op:tt, $func:ident, $inner_func:ident) => {
        impl<MOD, const LIMBS: usize> $op for MontyFieldElement<MOD, LIMBS>
        where
            MOD: MontyFieldParams<LIMBS>,
        {
            type Output = MontyFieldElement<MOD, LIMBS>;

            #[inline]
            fn $func(self, rhs: MontyFieldElement<MOD, LIMBS>) -> MontyFieldElement<MOD, LIMBS> {
                <MontyFieldElement<MOD, LIMBS>>::$inner_func(&self, &rhs)
            }
        }

        impl<MOD, const LIMBS: usize> $op<&Self> for MontyFieldElement<MOD, LIMBS>
        where
            MOD: MontyFieldParams<LIMBS>,
        {
            type Output = MontyFieldElement<MOD, LIMBS>;

            #[inline]
            fn $func(self, rhs: &MontyFieldElement<MOD, LIMBS>) -> MontyFieldElement<MOD, LIMBS> {
                <MontyFieldElement<MOD, LIMBS>>::$inner_func(&self, rhs)
            }
        }

        impl<MOD, const LIMBS: usize> $op<Self> for &MontyFieldElement<MOD, LIMBS>
        where
            MOD: MontyFieldParams<LIMBS>,
        {
            type Output = MontyFieldElement<MOD, LIMBS>;

            #[inline]
            fn $func(self, rhs: &MontyFieldElement<MOD, LIMBS>) -> MontyFieldElement<MOD, LIMBS> {
                <MontyFieldElement<MOD, LIMBS>>::$inner_func(self, rhs)
            }
        }
    };
}

monty_field_op!(Add, add, add);
monty_field_op!(Sub, sub, sub);
monty_field_op!(Mul, mul, multiply);

impl<MOD, const LIMBS: usize> AddAssign<Self> for MontyFieldElement<MOD, LIMBS>
where
    MOD: MontyFieldParams<LIMBS>,
{
    #[inline]
    fn add_assign(&mut self, other: MontyFieldElement<MOD, LIMBS>) {
        *self = *self + other;
    }
}

impl<MOD, const LIMBS: usize> AddAssign<&Self> for MontyFieldElement<MOD, LIMBS>
where
    MOD: MontyFieldParams<LIMBS>,
{
    #[inline]
    fn add_assign(&mut self, other: &MontyFieldElement<MOD, LIMBS>) {
        *self = *self + other;
    }
}

impl<MOD, const LIMBS: usize> SubAssign<Self> for MontyFieldElement<MOD, LIMBS>
where
    MOD: MontyFieldParams<LIMBS>,
{
    #[inline]
    fn sub_assign(&mut self, other: MontyFieldElement<MOD, LIMBS>) {
        *self = *self - other;
    }
}

impl<MOD, const LIMBS: usize> SubAssign<&Self> for MontyFieldElement<MOD, LIMBS>
where
    MOD: MontyFieldParams<LIMBS>,
{
    #[inline]
    fn sub_assign(&mut self, other: &MontyFieldElement<MOD, LIMBS>) {
        *self = *self - other;
    }
}

impl<MOD, const LIMBS: usize> MulAssign<&Self> for MontyFieldElement<MOD, LIMBS>
where
    MOD: MontyFieldParams<LIMBS>,
{
    #[inline]
    fn mul_assign(&mut self, other: &MontyFieldElement<MOD, LIMBS>) {
        *self = *self * other;
    }
}

impl<MOD, const LIMBS: usize> MulAssign for MontyFieldElement<MOD, LIMBS>
where
    MOD: MontyFieldParams<LIMBS>,
{
    #[inline]
    fn mul_assign(&mut self, other: MontyFieldElement<MOD, LIMBS>) {
        *self = *self * other;
    }
}

impl<MOD, const LIMBS: usize> Neg for MontyFieldElement<MOD, LIMBS>
where
    MOD: MontyFieldParams<LIMBS>,
{
    type Output = MontyFieldElement<MOD, LIMBS>;

    #[inline]
    fn neg(self) -> MontyFieldElement<MOD, LIMBS> {
        <MontyFieldElement<MOD, LIMBS>>::neg(&self)
    }
}

impl<MOD, const LIMBS: usize> Neg for &MontyFieldElement<MOD, LIMBS>
where
    MOD: MontyFieldParams<LIMBS>,
{
    type Output = MontyFieldElement<MOD, LIMBS>;

    #[inline]
    fn neg(self) -> MontyFieldElement<MOD, LIMBS> {
        <MontyFieldElement<MOD, LIMBS>>::neg(self)
    }
}

impl<MOD, const LIMBS: usize> Sum for MontyFieldElement<MOD, LIMBS>
where
    MOD: MontyFieldParams<LIMBS>,
{
    fn sum<I: Iterator<Item = Self>>(iter: I) -> Self {
        iter.reduce(Add::add).unwrap_or(Self::ZERO)
    }
}

impl<'a, MOD, const LIMBS: usize> Sum<&'a Self> for MontyFieldElement<MOD, LIMBS>
where
    MOD: MontyFieldParams<LIMBS>,
{
    fn sum<I: Iterator<Item = &'a MontyFieldElement<MOD, LIMBS>>>(iter: I) -> Self {
        iter.copied().sum()
    }
}

impl<MOD, const LIMBS: usize> Product for MontyFieldElement<MOD, LIMBS>
where
    MOD: MontyFieldParams<LIMBS>,
{
    fn product<I: Iterator<Item = Self>>(iter: I) -> Self {
        iter.reduce(Mul::mul).unwrap_or(Self::ONE)
    }
}

impl<'a, MOD: MontyFieldParams<LIMBS>, const LIMBS: usize>
    Product<&'a MontyFieldElement<MOD, LIMBS>> for MontyFieldElement<MOD, LIMBS>
{
    fn product<I: Iterator<Item = &'a Self>>(iter: I) -> Self {
        iter.copied().product()
    }
}

impl<MOD, const LIMBS: usize> Invert for MontyFieldElement<MOD, LIMBS>
where
    MOD: MontyFieldParams<LIMBS>,
    MontyForm<MOD, LIMBS>: Invert<Output = CtOption<MontyForm<MOD, LIMBS>>>,
{
    type Output = CtOption<Self>;

    fn invert(&self) -> CtOption<Self> {
        Self::invert(self)
    }
}

impl<MOD, const LIMBS: usize> Reduce<Uint<LIMBS>> for MontyFieldElement<MOD, LIMBS>
where
    MOD: MontyFieldParams<LIMBS>,
{
    #[inline]
    fn reduce(w: &Uint<LIMBS>) -> Self {
        Self::from_uint_reduced(w)
    }
}

impl<MOD, const LIMBS: usize> Reduce<MontyFieldBytes<MOD, LIMBS>> for MontyFieldElement<MOD, LIMBS>
where
    MOD: MontyFieldParams<LIMBS>,
    Uint<LIMBS>: ArrayEncoding<ByteSize = MOD::ByteSize>,
{
    #[inline]
    fn reduce(bytes: &MontyFieldBytes<MOD, LIMBS>) -> Self {
        let uint = match MOD::BYTE_ORDER {
            ByteOrder::BigEndian => Uint::<LIMBS>::from_be_byte_array(bytes.clone()),
            ByteOrder::LittleEndian => Uint::<LIMBS>::from_le_byte_array(bytes.clone()),
        };

        Self::reduce(&uint)
    }
}

//
// `subtle` trait impls
//

impl<MOD, const LIMBS: usize> ConditionallySelectable for MontyFieldElement<MOD, LIMBS>
where
    MOD: MontyFieldParams<LIMBS>,
{
    fn conditional_select(a: &Self, b: &Self, choice: Choice) -> Self {
        Self {
            inner: MontyForm::conditional_select(&a.inner, &b.inner, choice),
        }
    }
}

impl<MOD, const LIMBS: usize> ConstantTimeEq for MontyFieldElement<MOD, LIMBS>
where
    MOD: MontyFieldParams<LIMBS>,
{
    fn ct_eq(&self, other: &Self) -> Choice {
        self.inner.ct_eq(&other.inner)
    }
}

impl<MOD, const LIMBS: usize> ConstantTimeGreater for MontyFieldElement<MOD, LIMBS>
where
    MOD: MontyFieldParams<LIMBS>,
{
    fn ct_gt(&self, other: &Self) -> Choice {
        // TODO(tarcieri): impl `ConstantTimeGreater` for `ConstMontyForm`
        self.inner.retrieve().ct_gt(&other.inner.retrieve())
    }
}

impl<MOD, const LIMBS: usize> ConstantTimeLess for MontyFieldElement<MOD, LIMBS>
where
    MOD: MontyFieldParams<LIMBS>,
{
    fn ct_lt(&self, other: &Self) -> Choice {
        // TODO(tarcieri): impl `ConstantTimeLess` for `ConstMontyForm`
        self.inner.retrieve().ct_lt(&other.inner.retrieve())
    }
}

//
// `core::fmt` trait impls
//

impl<MOD, const LIMBS: usize> fmt::Debug for MontyFieldElement<MOD, LIMBS>
where
    MOD: MontyFieldParams<LIMBS>,
{
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let canonical = self.to_canonical();
        write!(f, "{}(0x{:X})", MOD::FIELD_ELEMENT_NAME, &canonical)
    }
}

impl<MOD, const LIMBS: usize> fmt::Display for MontyFieldElement<MOD, LIMBS>
where
    MOD: MontyFieldParams<LIMBS>,
{
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::UpperHex::fmt(self, f)
    }
}

impl<MOD, const LIMBS: usize> fmt::Binary for MontyFieldElement<MOD, LIMBS>
where
    MOD: MontyFieldParams<LIMBS>,
{
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Binary::fmt(&self.to_canonical(), f)
    }
}

impl<MOD, const LIMBS: usize> fmt::LowerHex for MontyFieldElement<MOD, LIMBS>
where
    MOD: MontyFieldParams<LIMBS>,
{
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::LowerHex::fmt(&self.to_canonical(), f)
    }
}

impl<MOD, const LIMBS: usize> fmt::UpperHex for MontyFieldElement<MOD, LIMBS>
where
    MOD: MontyFieldParams<LIMBS>,
{
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::UpperHex::fmt(&self.to_canonical(), f)
    }
}

//
// Miscellaneous trait impls
//

impl<MOD, const LIMBS: usize> Default for MontyFieldElement<MOD, LIMBS>
where
    MOD: MontyFieldParams<LIMBS>,
{
    fn default() -> Self {
        Self::ZERO
    }
}

impl<MOD: MontyFieldParams<LIMBS>, const LIMBS: usize> Eq for MontyFieldElement<MOD, LIMBS> {}
impl<MOD: MontyFieldParams<LIMBS>, const LIMBS: usize> PartialEq for MontyFieldElement<MOD, LIMBS> {
    fn eq(&self, rhs: &Self) -> bool {
        self.inner.ct_eq(&(rhs.inner)).into()
    }
}

impl<MOD, const LIMBS: usize> From<u32> for MontyFieldElement<MOD, LIMBS>
where
    MOD: MontyFieldParams<LIMBS>,
{
    #[inline]
    fn from(n: u32) -> MontyFieldElement<MOD, LIMBS> {
        Self::from_uint_reduced(&Uint::from(n))
    }
}

impl<MOD, const LIMBS: usize> From<u64> for MontyFieldElement<MOD, LIMBS>
where
    MOD: MontyFieldParams<LIMBS>,
{
    #[inline]
    fn from(n: u64) -> MontyFieldElement<MOD, LIMBS> {
        Self::from_u64(n)
    }
}

impl<MOD, const LIMBS: usize> From<u128> for MontyFieldElement<MOD, LIMBS>
where
    MOD: MontyFieldParams<LIMBS>,
{
    fn from(n: u128) -> MontyFieldElement<MOD, LIMBS> {
        Self::from_uint_reduced(&Uint::from(n))
    }
}

impl<MOD, const LIMBS: usize> From<MontyFieldElement<MOD, LIMBS>> for MontyFieldBytes<MOD, LIMBS>
where
    MOD: MontyFieldParams<LIMBS>,
    Uint<LIMBS>: ArrayEncoding,
{
    fn from(fe: MontyFieldElement<MOD, LIMBS>) -> Self {
        MontyFieldBytes::<MOD, LIMBS>::from(&fe)
    }
}

impl<MOD, const LIMBS: usize> From<&MontyFieldElement<MOD, LIMBS>> for MontyFieldBytes<MOD, LIMBS>
where
    MOD: MontyFieldParams<LIMBS>,
    Uint<LIMBS>: ArrayEncoding,
{
    fn from(fe: &MontyFieldElement<MOD, LIMBS>) -> Self {
        fe.to_bytes()
    }
}

impl<MOD, const LIMBS: usize> From<MontyFieldElement<MOD, LIMBS>> for Uint<LIMBS>
where
    MOD: MontyFieldParams<LIMBS>,
{
    fn from(fe: MontyFieldElement<MOD, LIMBS>) -> Uint<LIMBS> {
        Uint::from(&fe)
    }
}

impl<MOD, const LIMBS: usize> From<&MontyFieldElement<MOD, LIMBS>> for Uint<LIMBS>
where
    MOD: MontyFieldParams<LIMBS>,
{
    fn from(fe: &MontyFieldElement<MOD, LIMBS>) -> Uint<LIMBS> {
        fe.to_canonical()
    }
}

impl<MOD: MontyFieldParams<LIMBS>, const LIMBS: usize> Ord for MontyFieldElement<MOD, LIMBS> {
    fn cmp(&self, other: &Self) -> Ordering {
        self.to_canonical().cmp(&other.to_canonical())
    }
}
impl<MOD: MontyFieldParams<LIMBS>, const LIMBS: usize> PartialOrd
    for MontyFieldElement<MOD, LIMBS>
{
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

/// Compute `S = (modulus - 1).trailing_zeros()`
const fn compute_s<const LIMBS: usize>(modulus: &Uint<LIMBS>) -> u32 {
    modulus.wrapping_sub(&Uint::ONE).trailing_zeros()
}

/// Compute `t = (modulus - 1) >> S`
pub const fn compute_t<const N: usize, const LIMBS: usize>(modulus: &Uint<LIMBS>) -> [u64; N] {
    #[cfg(target_pointer_width = "32")]
    assert!(
        LIMBS.div_ceil(2) == N,
        "t array should have length LIMBS.div_ceil(2) on 32-bit architectures"
    );
    #[cfg(target_pointer_width = "64")]
    assert!(
        LIMBS == N,
        "t array should have length LIMBS on 64-bit architectures"
    );

    let s = compute_s(modulus);
    let t = modulus.wrapping_sub(&Uint::ONE).wrapping_shr(s);

    let mut ret = [0; N];
    let mut i = 0;

    #[cfg(target_pointer_width = "32")]
    while i < N {
        let hi_i = (2 * i) + 1;
        let hi = if hi_i < LIMBS { t.as_words()[hi_i] } else { 0 };
        let lo = t.as_words()[2 * i];
        ret[i] = (hi as u64) << 32 | (lo as u64);
        i += 1;
    }
    #[cfg(target_pointer_width = "64")]
    while i < N {
        ret[i] = t.as_words()[i];
        i += 1;
    }

    ret
}

#[cfg(test)]
mod tests {
    use crate::{
        ByteOrder, monty_field_params, test_field_identity, test_field_invert,
        test_primefield_constants,
    };
    use bigint::U256;

    // Example modulus: P-256 base field.
    // p = 2^{224}(2^{32} − 1) + 2^{192} + 2^{96} − 1
    monty_field_params!(
        name: FieldParams,
        modulus: "ffffffff00000001000000000000000000000000ffffffffffffffffffffffff",
        uint: U256,
        byte_order: ByteOrder::BigEndian,
        multiplicative_generator: 6,
        fe_name: "FieldElement",
        doc: "P-256 field modulus"
    );

    /// P-256 field element
    type FieldElement = super::MontyFieldElement<FieldParams, { U256::LIMBS }>;

    // TODO(tarcieri): change `test_primefield_constants!` to compute `T` like this:
    // /// t = (modulus - 1) >> S
    // const T: U256 = FieldParams::PARAMS
    //     .modulus()
    //     .as_ref()
    //     .wrapping_sub(&Uint::ONE)
    //     .wrapping_shr(FieldElement::S);

    test_primefield_constants!(FieldElement, U256);
    test_field_identity!(FieldElement);
    test_field_invert!(FieldElement);

    #[test]
    fn modulus_bits_constant() {
        assert_eq!(FieldElement::NUM_BITS, 256);
    }

    #[test]
    fn s_constant() {
        assert_eq!(FieldElement::S, 1);
    }

    #[test]
    fn computed_delta_constant() {
        assert_eq!(FieldElement::DELTA, FieldElement::from_u64(36));
    }
}
