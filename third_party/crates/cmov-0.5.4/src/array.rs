//! Trait impls for core arrays.
//!
//! Implemented generically, delegating to the slice impls.

use crate::{Cmov, CmovEq, Condition};

// Optimized implementation for arrays which coalesces them into word-sized chunks first,
// then performs [`Cmov`] at the word-level to cut down on the total number of instructions.
impl<T, const N: usize> Cmov for [T; N]
where
    [T]: Cmov,
{
    #[inline]
    fn cmovnz(&mut self, value: &Self, condition: Condition) {
        self.as_mut_slice().cmovnz(value, condition);
    }
}

// Optimized implementation for arrays which coalesces them into word-sized chunks first,
// then performs [`CmovEq`] at the word-level to cut down on the total number of instructions.
impl<T, const N: usize> CmovEq for [T; N]
where
    [T]: CmovEq,
{
    #[inline]
    fn cmovne(&self, rhs: &Self, input: Condition, output: &mut Condition) {
        self.as_slice().cmovne(rhs, input, output);
    }
}
