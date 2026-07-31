//! Portable "best effort" implementation of `Cmov`/`CmovEq`.
//!
//! This implementation is based on portable arithmetic operations augmented with tactical usage of
//! `core::hint::black_box` based on past observations of where the optimizer has inserted branches
//! (see CVE-2026-23519), but the fully portable implementation cannot guarantee that the resulting
//! generated assembly is free of branch instructions.
//!
//! For select platforms using this backend (currently limited to ARM32) we use `asm!` for mask
//! generation which should largely mitigate the optimizer potentially inserting branches.

use crate::{Cmov, CmovEq, Condition};
use core::ops::{BitAnd, BitOr, Not};

#[cfg_attr(docsrs, doc(cfg(true)))]
impl Cmov for u16 {
    #[inline]
    fn cmovnz(&mut self, value: &u16, condition: Condition) {
        *self = masksel(*self, *value, (masknz32(condition.into()) & 0xFFFF) as u16);
    }

    #[inline]
    fn cmovz(&mut self, value: &u16, condition: Condition) {
        *self = masksel(*self, *value, (!masknz32(condition.into()) & 0xFFFF) as u16);
    }
}

#[cfg_attr(docsrs, doc(cfg(true)))]
impl Cmov for u32 {
    #[inline]
    fn cmovnz(&mut self, value: &Self, condition: Condition) {
        *self = masksel(*self, *value, masknz32(condition.into()));
    }

    #[inline]
    fn cmovz(&mut self, value: &Self, condition: Condition) {
        *self = masksel(*self, *value, !masknz32(condition.into()));
    }
}

#[cfg_attr(docsrs, doc(cfg(true)))]
impl Cmov for u64 {
    #[inline]
    fn cmovnz(&mut self, value: &Self, condition: Condition) {
        *self = masksel(*self, *value, masknz64(condition.into()));
    }

    #[inline]
    fn cmovz(&mut self, value: &Self, condition: Condition) {
        *self = masksel(*self, *value, !masknz64(condition.into()));
    }
}

#[cfg_attr(docsrs, doc(cfg(true)))]
impl CmovEq for u16 {
    #[inline]
    fn cmovne(&self, rhs: &Self, input: Condition, output: &mut Condition) {
        *output = masksel(
            *output,
            input,
            (masknz32((*self ^ *rhs).into()) & 0xFF) as Condition,
        );
    }

    #[inline]
    fn cmoveq(&self, rhs: &Self, input: Condition, output: &mut Condition) {
        *output = masksel(
            *output,
            input,
            (!masknz32((*self ^ *rhs).into()) & 0xFF) as Condition,
        );
    }
}

#[cfg_attr(docsrs, doc(cfg(true)))]
impl CmovEq for u32 {
    #[inline]
    fn cmovne(&self, rhs: &Self, input: Condition, output: &mut Condition) {
        *output = masksel(*output, input, (maskne32(*self, *rhs) & 0xFF) as Condition);
    }

    #[inline]
    fn cmoveq(&self, rhs: &Self, input: Condition, output: &mut Condition) {
        *output = masksel(*output, input, (maskeq32(*self, *rhs) & 0xFF) as Condition);
    }
}

#[cfg_attr(docsrs, doc(cfg(true)))]
impl CmovEq for u64 {
    #[inline]
    fn cmovne(&self, rhs: &Self, input: Condition, output: &mut Condition) {
        *output = masksel(*output, input, (maskne64(*self, *rhs) & 0xFF) as Condition);
    }

    #[inline]
    fn cmoveq(&self, rhs: &Self, input: Condition, output: &mut Condition) {
        *output = masksel(*output, input, (maskeq64(*self, *rhs) & 0xFF) as Condition);
    }
}

/// Returns `u32::MAX` if `x` is equal to `y`, otherwise returns `0` (32-bit version)
#[inline]
fn maskeq32(x: u32, y: u32) -> u32 {
    !maskne32(x, y)
}

/// Returns `u64::MAX` if `x` is equal to `y`, otherwise returns `0` (64-bit version)
#[inline]
fn maskeq64(x: u64, y: u64) -> u64 {
    !maskne64(x, y)
}

/// Returns `0` if `x` is equal to `y`, otherwise returns `u32::MAX` (32-bit version)
#[inline]
fn maskne32(x: u32, y: u32) -> u32 {
    masknz32(x ^ y)
}

/// Returns `0` if `x` is equal to `y`, otherwise returns `u64::MAX` (64-bit version)
#[inline]
fn maskne64(x: u64, y: u64) -> u64 {
    masknz64(x ^ y)
}

/// Return a `u32::MAX` mask if `condition` is non-zero, otherwise return zero for a zero input.
#[cfg(any(
    miri,
    not(any(target_arch = "arm", target_arch = "riscv32", target_arch = "riscv64"))
))]
fn masknz32(condition: u32) -> u32 {
    masknz!(condition: u32)
}

/// Return a `u64::MAX` mask if `condition` is non-zero, otherwise return zero for a zero input.
#[cfg(any(
    miri,
    not(any(target_arch = "arm", target_arch = "riscv32", target_arch = "riscv64"))
))]
fn masknz64(condition: u64) -> u64 {
    masknz!(condition: u64)
}

/// Optimized mask generation for ARM32 targets.
///
/// This is written in assembly both for performance and because we've had problematic code
/// generation in this routine in the past which lead to the insertion of a branch, which using
/// assembly should guarantee won't happen again in the future (CVE-2026-23519).
#[cfg(all(target_arch = "arm", not(miri)))]
fn masknz32(condition: u32) -> u32 {
    let mut mask: u32;
    unsafe {
        core::arch::asm!(
            "rsbs {0}, {1}, #0",  // Reverse subtract
            "sbcs {0}, {0}, {0}", // Subtract with carry, setting flags
            lateout(reg) mask,
            in(reg) condition,
            options(nostack, nomem),
        );
    }
    mask
}

/// Optimized mask generation for riscv32 targets.
#[cfg(all(target_arch = "riscv32", not(miri)))]
fn masknz32(condition: u32) -> u32 {
    let mut mask: u32;
    unsafe {
        core::arch::asm!(
            "seqz {0}, {1}",  // Set-if-not-zero pseudo-instruction
            "addi {0}, {0}, -1", // Subtract 1, to have either full ones or full zeroes mask
            lateout(reg) mask,
            in(reg) condition,
            options(nostack, nomem),
        );
    }
    mask
}

/// Optimized mask generation for riscv32 targets.
#[cfg(all(target_arch = "riscv64", not(miri)))]
fn masknz32(condition: u32) -> u32 {
    (masknz64(condition.into()) & 0xFFFF_FFFF) as u32
}

/// Optimized mask generation for riscv64 targets.
#[cfg(all(target_arch = "riscv64", not(miri)))]
fn masknz64(condition: u64) -> u64 {
    let mut mask: u64;
    unsafe {
        core::arch::asm!(
            "seqz {0}, {1}",  // Set-if-not-zero pseudo-instruction
            "addi {0}, {0}, -1", // Subtract 1, to have either full ones or full zeroes mask
            lateout(reg) mask,
            in(reg) condition,
            options(nostack, nomem),
        );
    }
    mask
}

/// 64-bit wrapper for targets that implement 32-bit mask generation in assembly.
#[cfg(all(any(target_arch = "arm", target_arch = "riscv32"), not(miri)))]
fn masknz64(condition: u64) -> u64 {
    let lo = masknz32((condition & 0xFFFF_FFFF) as u32);
    let hi = masknz32((condition >> 32) as u32);
    let mask = u64::from(lo | hi);
    mask | mask << 32
}

/// Given a supplied mask of `0` or all 1-bits (i.e. `u*::MAX`), select `a` if the mask is all-zeros
/// and `b` if the mask is all-ones.
///
/// This function shouldn't be used with a mask that isn't `0` or `u*::MAX`.
#[inline]
fn masksel<T>(a: T, b: T, mask: T) -> T
where
    T: BitAnd<Output = T> + BitOr<Output = T> + Copy + Not<Output = T>,
{
    (a & !mask) | (b & mask)
}

#[cfg(test)]
mod tests {
    // Spot check up to a given limit
    const TEST_LIMIT: u32 = 65536;

    #[test]
    fn maskeq32() {
        assert_eq!(super::maskeq32(0, 0), u32::MAX);
        assert_eq!(super::maskeq32(1, 0), 0);
        assert_eq!(super::maskeq32(0, 1), 0);
        assert_eq!(super::maskeq32(1, 1), u32::MAX);
        assert_eq!(super::maskeq32(u32::MAX, 1), 0);
        assert_eq!(super::maskeq32(1, u32::MAX), 0);
        assert_eq!(super::maskeq32(u32::MAX, u32::MAX), u32::MAX);
    }

    #[test]
    fn maskeq64() {
        assert_eq!(super::maskeq64(0, 0), u64::MAX);
        assert_eq!(super::maskeq64(1, 0), 0);
        assert_eq!(super::maskeq64(0, 1), 0);
        assert_eq!(super::maskeq64(1, 1), u64::MAX);
        assert_eq!(super::maskeq64(u64::MAX, 1), 0);
        assert_eq!(super::maskeq64(1, u64::MAX), 0);
        assert_eq!(super::maskeq64(u64::MAX, u64::MAX), u64::MAX);
    }

    #[test]
    fn maskne32() {
        assert_eq!(super::maskne32(0, 0), 0);
        assert_eq!(super::maskne32(1, 0), u32::MAX);
        assert_eq!(super::maskne32(0, 1), u32::MAX);
        assert_eq!(super::maskne32(1, 1), 0);
        assert_eq!(super::maskne32(u32::MAX, 1), u32::MAX);
        assert_eq!(super::maskne32(1, u32::MAX), u32::MAX);
        assert_eq!(super::maskne32(u32::MAX, u32::MAX), 0);
    }

    #[test]
    fn maskne64() {
        assert_eq!(super::maskne64(0, 0), 0);
        assert_eq!(super::maskne64(1, 0), u64::MAX);
        assert_eq!(super::maskne64(0, 1), u64::MAX);
        assert_eq!(super::maskne64(1, 1), 0);
        assert_eq!(super::maskne64(u64::MAX, 1), u64::MAX);
        assert_eq!(super::maskne64(1, u64::MAX), u64::MAX);
        assert_eq!(super::maskne64(u64::MAX, u64::MAX), 0);
    }

    #[test]
    fn masknz32() {
        assert_eq!(super::masknz32(0), 0);
        for i in 1..=TEST_LIMIT {
            assert_eq!(super::masknz32(i), u32::MAX);
        }

        for i in (u32::MAX - TEST_LIMIT)..=u32::MAX {
            assert_eq!(super::masknz32(i), u32::MAX);
        }
    }

    #[test]
    fn masknz64() {
        assert_eq!(super::masknz64(0), 0);
        for i in 1..=(TEST_LIMIT as u64) {
            assert_eq!(super::masknz64(i), u64::MAX);
        }

        for i in (u64::MAX - TEST_LIMIT as u64)..=u64::MAX {
            assert_eq!(super::masknz64(i), u64::MAX);
        }
    }

    #[test]
    fn masksel() {
        assert_eq!(super::masksel(23u8, 42u8, 0u8), 23u8);
        assert_eq!(super::masksel(23u8, 42u8, u8::MAX), 42u8);

        assert_eq!(super::masksel(17u32, 101077u32, 0u32), 17u32);
        assert_eq!(super::masksel(17u32, 101077u32, u32::MAX), 101077u32);

        assert_eq!(super::masksel(129u64, 0xFFEEDDCCBBAA9988u64, 0u64), 129u64);
        assert_eq!(
            super::masksel(129u64, 0xFFEEDDCCBBAA9988u64, u64::MAX),
            0xFFEEDDCCBBAA9988u64
        );
    }
}
