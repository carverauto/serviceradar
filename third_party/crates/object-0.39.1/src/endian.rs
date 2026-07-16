//! Types for compile-time and run-time endianness.

use crate::pod::Pod;
use core::fmt::{self, Debug};
use core::marker::PhantomData;

/// A trait for using an endianness specification.
///
/// Provides methods for converting between the specified endianness and
/// the native endianness of the target machine.
///
/// This trait does not require that the endianness is known at compile time.
pub trait Endian: Debug + Default + Clone + Copy + PartialEq + Eq + 'static {
    /// Construct a specification for the endianness of some values.
    ///
    /// Returns `None` if the type does not support specifying the given endianness.
    fn from_big_endian(big_endian: bool) -> Option<Self>;

    /// Construct a specification for the endianness of some values.
    ///
    /// Returns `None` if the type does not support specifying the given endianness.
    fn from_little_endian(little_endian: bool) -> Option<Self> {
        Self::from_big_endian(!little_endian)
    }

    /// Return true for big endian byte order.
    fn is_big_endian(self) -> bool;

    /// Return true for little endian byte order.
    #[inline]
    fn is_little_endian(self) -> bool {
        !self.is_big_endian()
    }

    /// Converts an unaligned unsigned 16 bit integer to native endian.
    #[inline]
    fn read_u16(self, n: [u8; 2]) -> u16 {
        if self.is_big_endian() {
            u16::from_be_bytes(n)
        } else {
            u16::from_le_bytes(n)
        }
    }

    /// Converts an unaligned unsigned 32 bit integer to native endian.
    #[inline]
    fn read_u32(self, n: [u8; 4]) -> u32 {
        if self.is_big_endian() {
            u32::from_be_bytes(n)
        } else {
            u32::from_le_bytes(n)
        }
    }

    /// Converts an unaligned unsigned 64 bit integer to native endian.
    #[inline]
    fn read_u64(self, n: [u8; 8]) -> u64 {
        if self.is_big_endian() {
            u64::from_be_bytes(n)
        } else {
            u64::from_le_bytes(n)
        }
    }

    /// Converts an unaligned signed 16 bit integer to native endian.
    #[inline]
    fn read_i16(self, n: [u8; 2]) -> i16 {
        if self.is_big_endian() {
            i16::from_be_bytes(n)
        } else {
            i16::from_le_bytes(n)
        }
    }

    /// Converts an unaligned signed 32 bit integer to native endian.
    #[inline]
    fn read_i32(self, n: [u8; 4]) -> i32 {
        if self.is_big_endian() {
            i32::from_be_bytes(n)
        } else {
            i32::from_le_bytes(n)
        }
    }

    /// Converts an unaligned signed 64 bit integer to native endian.
    #[inline]
    fn read_i64(self, n: [u8; 8]) -> i64 {
        if self.is_big_endian() {
            i64::from_be_bytes(n)
        } else {
            i64::from_le_bytes(n)
        }
    }

    /// Converts an unaligned unsigned 16 bit integer from native endian.
    #[inline]
    fn write_u16(self, n: u16) -> [u8; 2] {
        if self.is_big_endian() {
            u16::to_be_bytes(n)
        } else {
            u16::to_le_bytes(n)
        }
    }

    /// Converts an unaligned unsigned 32 bit integer from native endian.
    #[inline]
    fn write_u32(self, n: u32) -> [u8; 4] {
        if self.is_big_endian() {
            u32::to_be_bytes(n)
        } else {
            u32::to_le_bytes(n)
        }
    }

    /// Converts an unaligned unsigned 64 bit integer from native endian.
    #[inline]
    fn write_u64(self, n: u64) -> [u8; 8] {
        if self.is_big_endian() {
            u64::to_be_bytes(n)
        } else {
            u64::to_le_bytes(n)
        }
    }

    /// Converts an unaligned signed 16 bit integer from native endian.
    #[inline]
    fn write_i16(self, n: i16) -> [u8; 2] {
        if self.is_big_endian() {
            i16::to_be_bytes(n)
        } else {
            i16::to_le_bytes(n)
        }
    }

    /// Converts an unaligned signed 32 bit integer from native endian.
    #[inline]
    fn write_i32(self, n: i32) -> [u8; 4] {
        if self.is_big_endian() {
            i32::to_be_bytes(n)
        } else {
            i32::to_le_bytes(n)
        }
    }

    /// Converts an unaligned signed 64 bit integer from native endian.
    #[inline]
    fn write_i64(self, n: i64) -> [u8; 8] {
        if self.is_big_endian() {
            i64::to_be_bytes(n)
        } else {
            i64::to_le_bytes(n)
        }
    }
}

/// An endianness specification that has a fixed value.
pub trait FixedEndian: Endian {
    /// The fixed value.
    const FIXED: Self;
}

/// An endianness that is selectable at run-time.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Endianness {
    /// Little endian byte order.
    Little,
    /// Big endian byte order.
    Big,
}

impl Default for Endianness {
    #[cfg(target_endian = "little")]
    #[inline]
    fn default() -> Endianness {
        Endianness::Little
    }

    #[cfg(target_endian = "big")]
    #[inline]
    fn default() -> Endianness {
        Endianness::Big
    }
}

impl Endian for Endianness {
    #[inline]
    fn from_big_endian(big_endian: bool) -> Option<Self> {
        Some(if big_endian {
            Endianness::Big
        } else {
            Endianness::Little
        })
    }

    #[inline]
    fn is_big_endian(self) -> bool {
        self != Endianness::Little
    }
}

/// Compile-time little endian byte order.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct LittleEndian;

impl Default for LittleEndian {
    #[inline]
    fn default() -> LittleEndian {
        LittleEndian
    }
}

impl Endian for LittleEndian {
    #[inline]
    fn from_big_endian(big_endian: bool) -> Option<Self> {
        if big_endian {
            None
        } else {
            Some(LittleEndian)
        }
    }

    #[inline]
    fn is_big_endian(self) -> bool {
        false
    }
}

impl FixedEndian for LittleEndian {
    const FIXED: Self = LittleEndian;
}

/// Compile-time big endian byte order.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct BigEndian;

impl Default for BigEndian {
    #[inline]
    fn default() -> BigEndian {
        BigEndian
    }
}

impl Endian for BigEndian {
    #[inline]
    fn from_big_endian(big_endian: bool) -> Option<Self> {
        if big_endian {
            Some(BigEndian)
        } else {
            None
        }
    }

    #[inline]
    fn is_big_endian(self) -> bool {
        true
    }
}

impl FixedEndian for BigEndian {
    const FIXED: Self = BigEndian;
}

/// The native endianness for the target platform.
#[cfg(target_endian = "little")]
pub type NativeEndian = LittleEndian;

#[cfg(target_endian = "little")]
#[allow(non_upper_case_globals)]
#[doc(hidden)]
pub const NativeEndian: LittleEndian = LittleEndian;

/// The native endianness for the target platform.
#[cfg(target_endian = "big")]
pub type NativeEndian = BigEndian;

#[cfg(target_endian = "big")]
#[allow(non_upper_case_globals)]
#[doc(hidden)]
pub const NativeEndian: BigEndian = BigEndian;

macro_rules! unsafe_impl_endian_pod {
    ($($struct_name:ident),+ $(,)?) => {
        $(
            unsafe impl<E: Endian> Pod for $struct_name<E> { }
        )+
    }
}

/// An unaligned `u16` value with an externally specified endianness of type `E`.
#[deprecated]
pub type U16Bytes<E> = U16<E>;

/// An unaligned `u32` value with an externally specified endianness of type `E`.
#[deprecated]
pub type U32Bytes<E> = U32<E>;

/// An unaligned `u64` value with an externally specified endianness of type `E`.
#[deprecated]
pub type U64Bytes<E> = U64<E>;

/// An unaligned `i16` value with an externally specified endianness of type `E`.
#[deprecated]
pub type I16Bytes<E> = I16<E>;

/// An unaligned `i32` value with an externally specified endianness of type `E`.
#[deprecated]
pub type I32Bytes<E> = I32<E>;

/// An unaligned `i64` value with an externally specified endianness of type `E`.
#[deprecated]
pub type I64Bytes<E> = I64<E>;

/// An unaligned `u16` value with an externally specified endianness of type `E`.
#[derive(Default, Copy, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
#[repr(transparent)]
pub struct U16<E: Endian>([u8; 2], PhantomData<E>);

impl<E: Endian> U16<E> {
    /// Construct a new value given bytes that already have the required endianness.
    pub const fn from_bytes(n: [u8; 2]) -> Self {
        Self(n, PhantomData)
    }

    /// Construct a new value given a native endian value.
    pub fn new(e: E, n: u16) -> Self {
        Self(e.write_u16(n), PhantomData)
    }

    /// Return the value as a native endian value.
    pub fn get(self, e: E) -> u16 {
        e.read_u16(self.0)
    }

    /// Set the value given a native endian value.
    pub fn set(&mut self, e: E, n: u16) {
        self.0 = e.write_u16(n);
    }
}

/// An unaligned `u32` value with an externally specified endianness of type `E`.
#[derive(Default, Copy, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
#[repr(transparent)]
pub struct U32<E: Endian>([u8; 4], PhantomData<E>);

impl<E: Endian> U32<E> {
    /// Construct a new value given bytes that already have the required endianness.
    pub const fn from_bytes(n: [u8; 4]) -> Self {
        Self(n, PhantomData)
    }

    /// Construct a new value given a native endian value.
    pub fn new(e: E, n: u32) -> Self {
        Self(e.write_u32(n), PhantomData)
    }

    /// Return the value as a native endian value.
    pub fn get(self, e: E) -> u32 {
        e.read_u32(self.0)
    }

    /// Set the value given a native endian value.
    pub fn set(&mut self, e: E, n: u32) {
        self.0 = e.write_u32(n);
    }
}

/// An unaligned `u64` value with an externally specified endianness of type `E`.
#[derive(Default, Copy, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
#[repr(transparent)]
pub struct U64<E: Endian>([u8; 8], PhantomData<E>);

impl<E: Endian> U64<E> {
    /// Construct a new value given bytes that already have the required endianness.
    pub const fn from_bytes(n: [u8; 8]) -> Self {
        Self(n, PhantomData)
    }

    /// Construct a new value given a native endian value.
    pub fn new(e: E, n: u64) -> Self {
        Self(e.write_u64(n), PhantomData)
    }

    /// Return the value as a native endian value.
    pub fn get(self, e: E) -> u64 {
        e.read_u64(self.0)
    }

    /// Set the value given a native endian value.
    pub fn set(&mut self, e: E, n: u64) {
        self.0 = e.write_u64(n);
    }
}

/// An unaligned `i16` value with an externally specified endianness of type `E`.
#[derive(Default, Copy, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
#[repr(transparent)]
pub struct I16<E: Endian>([u8; 2], PhantomData<E>);

impl<E: Endian> I16<E> {
    /// Construct a new value given bytes that already have the required endianness.
    pub const fn from_bytes(n: [u8; 2]) -> Self {
        Self(n, PhantomData)
    }

    /// Construct a new value given a native endian value.
    pub fn new(e: E, n: i16) -> Self {
        Self(e.write_i16(n), PhantomData)
    }

    /// Return the value as a native endian value.
    pub fn get(self, e: E) -> i16 {
        e.read_i16(self.0)
    }

    /// Set the value given a native endian value.
    pub fn set(&mut self, e: E, n: i16) {
        self.0 = e.write_i16(n);
    }
}

/// An unaligned `i32` value with an externally specified endianness of type `E`.
#[derive(Default, Copy, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
#[repr(transparent)]
pub struct I32<E: Endian>([u8; 4], PhantomData<E>);

impl<E: Endian> I32<E> {
    /// Construct a new value given bytes that already have the required endianness.
    pub const fn from_bytes(n: [u8; 4]) -> Self {
        Self(n, PhantomData)
    }

    /// Construct a new value given a native endian value.
    pub fn new(e: E, n: i32) -> Self {
        Self(e.write_i32(n), PhantomData)
    }

    /// Return the value as a native endian value.
    pub fn get(self, e: E) -> i32 {
        e.read_i32(self.0)
    }

    /// Set the value given a native endian value.
    pub fn set(&mut self, e: E, n: i32) {
        self.0 = e.write_i32(n);
    }
}

/// An unaligned `i64` value with an externally specified endianness of type `E`.
#[derive(Default, Copy, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
#[repr(transparent)]
pub struct I64<E: Endian>([u8; 8], PhantomData<E>);

impl<E: Endian> I64<E> {
    /// Construct a new value given bytes that already have the required endianness.
    pub const fn from_bytes(n: [u8; 8]) -> Self {
        Self(n, PhantomData)
    }

    /// Construct a new value given a native endian value.
    pub fn new(e: E, n: i64) -> Self {
        Self(e.write_i64(n), PhantomData)
    }

    /// Return the value as a native endian value.
    pub fn get(self, e: E) -> i64 {
        e.read_i64(self.0)
    }

    /// Set the value given a native endian value.
    pub fn set(&mut self, e: E, n: i64) {
        self.0 = e.write_i64(n);
    }
}

impl<E: Endian> fmt::Debug for U16<E> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "U16({:02x}{:02x})", self.0[0], self.0[1],)
    }
}

impl<E: Endian> fmt::Debug for U32<E> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "U32({:02x}{:02x}{:02x}{:02x})",
            self.0[0], self.0[1], self.0[2], self.0[3],
        )
    }
}

impl<E: Endian> fmt::Debug for U64<E> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "U64({:02x}{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}{:02x})",
            self.0[0], self.0[1], self.0[2], self.0[3], self.0[4], self.0[5], self.0[6], self.0[7],
        )
    }
}

impl<E: Endian> fmt::Debug for I16<E> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "I16({:02x}{:02x})", self.0[0], self.0[1],)
    }
}

impl<E: Endian> fmt::Debug for I32<E> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "I32({:02x}{:02x}{:02x}{:02x})",
            self.0[0], self.0[1], self.0[2], self.0[3],
        )
    }
}

impl<E: Endian> fmt::Debug for I64<E> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "I64({:02x}{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}{:02x})",
            self.0[0], self.0[1], self.0[2], self.0[3], self.0[4], self.0[5], self.0[6], self.0[7],
        )
    }
}

impl<E: FixedEndian> From<u16> for U16<E> {
    fn from(val: u16) -> Self {
        Self::new(E::FIXED, val)
    }
}

impl<E: FixedEndian> From<U16<E>> for u16 {
    fn from(val: U16<E>) -> Self {
        val.get(E::FIXED)
    }
}

impl<E: FixedEndian> From<u32> for U32<E> {
    fn from(val: u32) -> Self {
        Self::new(E::FIXED, val)
    }
}

impl<E: FixedEndian> From<U32<E>> for u32 {
    fn from(val: U32<E>) -> Self {
        val.get(E::FIXED)
    }
}

impl<E: FixedEndian> From<u64> for U64<E> {
    fn from(val: u64) -> Self {
        Self::new(E::FIXED, val)
    }
}

impl<E: FixedEndian> From<U64<E>> for u64 {
    fn from(val: U64<E>) -> Self {
        val.get(E::FIXED)
    }
}

impl<E: FixedEndian> From<i16> for I16<E> {
    fn from(val: i16) -> Self {
        Self::new(E::FIXED, val)
    }
}

impl<E: FixedEndian> From<I16<E>> for i16 {
    fn from(val: I16<E>) -> Self {
        val.get(E::FIXED)
    }
}

impl<E: FixedEndian> From<i32> for I32<E> {
    fn from(val: i32) -> Self {
        Self::new(E::FIXED, val)
    }
}

impl<E: FixedEndian> From<I32<E>> for i32 {
    fn from(val: I32<E>) -> Self {
        val.get(E::FIXED)
    }
}

impl<E: FixedEndian> From<i64> for I64<E> {
    fn from(val: i64) -> Self {
        Self::new(E::FIXED, val)
    }
}

impl<E: FixedEndian> From<I64<E>> for i64 {
    fn from(val: I64<E>) -> Self {
        val.get(E::FIXED)
    }
}

unsafe_impl_endian_pod!(U16, U32, U64, I16, I32, I64);
