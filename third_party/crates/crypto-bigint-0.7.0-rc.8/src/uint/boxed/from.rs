//! `From`-like conversions for [`BoxedUint`].

use crate::{BoxedUint, Limb, Odd, U64, U128, Uint, Word};
use alloc::{boxed::Box, vec::Vec};
use core::mem;

impl From<u8> for BoxedUint {
    fn from(n: u8) -> Self {
        vec![Limb::from(n); 1].into()
    }
}

impl From<u16> for BoxedUint {
    fn from(n: u16) -> Self {
        vec![Limb::from(n); 1].into()
    }
}

impl From<u32> for BoxedUint {
    fn from(n: u32) -> Self {
        vec![Limb::from(n); 1].into()
    }
}

impl From<u64> for BoxedUint {
    fn from(n: u64) -> Self {
        U64::from(n).into()
    }
}

impl From<u128> for BoxedUint {
    fn from(n: u128) -> Self {
        U128::from(n).into()
    }
}

impl From<Limb> for BoxedUint {
    fn from(limb: Limb) -> Self {
        vec![limb; 1].into()
    }
}

impl From<&[Limb]> for BoxedUint {
    fn from(limbs: &[Limb]) -> BoxedUint {
        Self {
            limbs: limbs.into(),
        }
    }
}

impl From<Box<[Limb]>> for BoxedUint {
    fn from(limbs: Box<[Limb]>) -> BoxedUint {
        Vec::from(limbs).into()
    }
}

impl From<Vec<Limb>> for BoxedUint {
    fn from(mut limbs: Vec<Limb>) -> BoxedUint {
        if limbs.is_empty() {
            limbs.push(Limb::ZERO);
        }

        Self {
            limbs: limbs.into_boxed_slice(),
        }
    }
}

impl From<Vec<Word>> for BoxedUint {
    fn from(mut words: Vec<Word>) -> BoxedUint {
        // SAFETY: `Limb` is a `repr(transparent)` newtype for `Word`
        #[allow(unsafe_code)]
        unsafe {
            let ptr = words.as_mut_ptr() as *mut Limb;
            let len = words.len();
            let capacity = words.capacity();
            mem::forget(words);
            Vec::<Limb>::from_raw_parts(ptr, len, capacity)
        }
        .into()
    }
}

impl<const LIMBS: usize> From<Uint<LIMBS>> for BoxedUint {
    #[inline]
    fn from(uint: Uint<LIMBS>) -> BoxedUint {
        Self::from(&uint)
    }
}

impl<const LIMBS: usize> From<&Uint<LIMBS>> for BoxedUint {
    #[inline]
    fn from(uint: &Uint<LIMBS>) -> BoxedUint {
        Vec::from(uint.to_limbs()).into()
    }
}

impl<const LIMBS: usize> From<Odd<Uint<LIMBS>>> for BoxedUint {
    #[inline]
    fn from(uint: Odd<Uint<LIMBS>>) -> BoxedUint {
        Self::from(&uint.0)
    }
}

impl<const LIMBS: usize> From<&Odd<Uint<LIMBS>>> for BoxedUint {
    #[inline]
    fn from(uint: &Odd<Uint<LIMBS>>) -> BoxedUint {
        Self::from(&uint.0)
    }
}

impl<const LIMBS: usize> From<Odd<Uint<LIMBS>>> for Odd<BoxedUint> {
    #[inline]
    fn from(uint: Odd<Uint<LIMBS>>) -> Odd<BoxedUint> {
        Odd(BoxedUint::from(&uint.0))
    }
}

impl<const LIMBS: usize> From<&Odd<Uint<LIMBS>>> for Odd<BoxedUint> {
    #[inline]
    fn from(uint: &Odd<Uint<LIMBS>>) -> Odd<BoxedUint> {
        Odd(BoxedUint::from(&uint.0))
    }
}
