//! Unsigned integer reference type.

use crate::{Limb, Uint};
use core::{
    fmt,
    ops::{Index, IndexMut},
};

#[cfg(feature = "alloc")]
use crate::{ConstChoice, Word};

mod add;
mod bits;
mod invert_mod;
mod shl;
mod slice;
mod sub;

#[cfg(feature = "alloc")]
mod shr;

/// Unsigned integer reference type.
///
/// This type contains a limb slice which can be borrowed from either a [`Uint`] or [`BoxedUint`] and
/// thus provides an abstraction for writing shared implementations.
#[repr(transparent)]
#[derive(PartialEq, Eq)]
pub(crate) struct UintRef(pub [Limb]);

impl UintRef {
    /// Create a [`UintRef`] reference type from a [`Limb`] slice.
    #[inline]
    pub const fn new(limbs: &[Limb]) -> &Self {
        // SAFETY: `UintRef` is a `repr(transparent)` newtype for `[Limb]`.
        #[allow(trivial_casts, unsafe_code)]
        unsafe {
            &*(limbs as *const [Limb] as *const UintRef)
        }
    }

    /// Create a mutable [`UintRef`] reference type from a [`Limb`] slice.
    #[inline]
    pub const fn new_mut(limbs: &mut [Limb]) -> &mut Self {
        // SAFETY: `UintRef` is a `repr(transparent)` newtype for `[Limb]`.
        #[allow(trivial_casts, unsafe_code)]
        unsafe {
            &mut *(limbs as *mut [Limb] as *mut UintRef)
        }
    }

    /// Create a new mutable [`UintRef`] reference type from a slice of [`Limb`] arrays.
    pub const fn new_flattened_mut<const N: usize>(slice: &mut [[Limb; N]]) -> &mut Self {
        // This is a temporary shim for `[[T;N]]::as_flattened_mut` which is only const-stable as of Rust 1.87.
        let len = slice.len() * N;
        #[allow(unsafe_code)]
        Self::new_mut(unsafe { core::slice::from_raw_parts_mut(slice.as_mut_ptr().cast(), len) })
    }

    /// Borrow the inner `&[Limb]` slice.
    #[inline]
    pub const fn as_slice(&self) -> &[Limb] {
        &self.0
    }

    /// Mutably borrow the inner `&mut [Limb]` slice.
    #[inline]
    pub const fn as_mut_slice(&mut self) -> &mut [Limb] {
        &mut self.0
    }

    /// Borrow the inner limbs as a slice of [`Word`]s.
    #[cfg(feature = "alloc")]
    #[inline]
    pub const fn as_words(&self) -> &[Word] {
        // SAFETY: `Limb` is a `repr(transparent)` newtype for `Word`
        #[allow(trivial_casts, unsafe_code)]
        unsafe {
            &*((&self.0 as *const [Limb]) as *const [Word])
        }
    }

    /// Borrow the inner limbs as a mutable slice of [`Word`]s.
    #[cfg(feature = "alloc")]
    #[inline]
    pub const fn as_mut_words(&mut self) -> &mut [Word] {
        // SAFETY: `Limb` is a `repr(transparent)` newtype for `Word`
        #[allow(trivial_casts, unsafe_code)]
        unsafe {
            &mut *((&mut self.0 as *mut [Limb]) as *mut [Word])
        }
    }

    /// Get an iterator over the inner limbs.
    #[inline]
    pub fn iter(&self) -> impl DoubleEndedIterator<Item = &Limb> {
        self.0.iter()
    }

    /// Get a mutable iterator over the inner limbs.
    #[inline]
    #[allow(dead_code)] // TODO(tarcieri): use this
    pub fn iter_mut(&mut self) -> impl DoubleEndedIterator<Item = &mut Limb> {
        self.0.iter_mut()
    }

    /// Access the number of limbs.
    #[inline]
    pub const fn nlimbs(&self) -> usize {
        self.0.len()
    }

    /// Conditionally assign all of the limbs to zero.
    #[cfg(feature = "alloc")]
    #[inline]
    pub const fn conditional_set_zero(&mut self, choice: ConstChoice) {
        let mut i = 0;
        while i < self.nlimbs() {
            self.0[i] = Limb::select(self.0[i], Limb::ZERO, choice);
            i += 1;
        }
    }

    /// Extract up to `LIMBS` limbs into a new `Uint`.
    pub const fn to_uint_resize<const LIMBS: usize>(&self) -> Uint<LIMBS> {
        let mut out = Uint::ZERO;
        let len = if self.nlimbs() > LIMBS {
            LIMBS
        } else {
            self.nlimbs()
        };
        let mut i = 0;
        while i < len {
            out.limbs[i] = self.0[i];
            i += 1;
        }
        out
    }
}

impl AsRef<[Limb]> for UintRef {
    #[inline]
    fn as_ref(&self) -> &[Limb] {
        self.as_slice()
    }
}

impl AsMut<[Limb]> for UintRef {
    #[inline]
    fn as_mut(&mut self) -> &mut [Limb] {
        self.as_mut_slice()
    }
}

impl Index<usize> for UintRef {
    type Output = Limb;

    #[inline]
    fn index(&self, index: usize) -> &Limb {
        self.0.index(index)
    }
}

impl IndexMut<usize> for UintRef {
    #[inline]
    fn index_mut(&mut self, index: usize) -> &mut Limb {
        self.0.index_mut(index)
    }
}

impl fmt::Debug for UintRef {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "UintRef(0x{self:X})")
    }
}

impl fmt::Binary for UintRef {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if f.alternate() {
            write!(f, "0b")?;
        }

        for limb in self.iter().rev() {
            write!(f, "{:0width$b}", &limb.0, width = Limb::BITS as usize)?;
        }
        Ok(())
    }
}

impl fmt::Display for UintRef {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::UpperHex::fmt(self, f)
    }
}

impl fmt::LowerHex for UintRef {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if f.alternate() {
            write!(f, "0x")?;
        }
        for limb in self.iter().rev() {
            write!(f, "{:0width$x}", &limb.0, width = Limb::BYTES * 2)?;
        }
        Ok(())
    }
}

impl fmt::UpperHex for UintRef {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if f.alternate() {
            write!(f, "0x")?;
        }
        for limb in self.iter().rev() {
            write!(f, "{:0width$X}", &limb.0, width = Limb::BYTES * 2)?;
        }
        Ok(())
    }
}
