use crate::{Cmov, CmovEq, Condition};
use core::arch::asm;

/// Conditional select
macro_rules! csel {
    ($tst:expr, $csel:expr, $dst:expr, $src:expr, $condition:expr) => {
        unsafe {
            asm! {
                $tst,
                $csel,
                in(reg) $condition,
                inlateout(reg) *$dst,
                in(reg) *$src,
                in(reg) *$dst,
                options(pure, nomem, nostack),
            };
        }
    };
}

/// Conditional select-based equality test
macro_rules! cseleq {
    ($eor:expr, $cmp:expr, $instruction:expr, $lhs:expr, $rhs:expr, $condition:expr, $dst:expr) => {
        let mut tmp = u16::from(*$dst);
        let condition = u16::from($condition);
        unsafe {
            asm! {
                $eor,
                $cmp,
                $instruction,
                out(reg) _,
                in(reg) *$lhs,
                in(reg) *$rhs,
                inlateout(reg) tmp,
                in(reg) condition,
                in(reg) tmp,
                options(pure, nomem, nostack),
            };
        };

        *$dst = (tmp & 0xFF) as u8;
    };
}

/// Conditional select using 32-bit `:w` registers
macro_rules! csel32 {
    ($csel:expr, $dst:expr, $src:expr, $condition:expr) => {
        csel!("tst {0:w}, 0xff", $csel, $dst, $src, $condition)
    };
}

/// Conditional select using 64-bit `:x` registers
macro_rules! csel64 {
    ($csel:expr, $dst:expr, $src:expr, $condition:expr) => {
        csel!("tst {0:x}, 0xff", $csel, $dst, $src, $condition)
    };
}

/// Conditional select equality test using 32-bit `:w` registers and
/// correctly handling unspecified upper bits of 16 bit inputs
macro_rules! cseleq16 {
    ($instruction:expr, $lhs:expr, $rhs:expr, $condition:expr, $dst:expr) => {
        cseleq!(
            "eor {0:w}, {1:w}, {2:w}",
            "tst {0:w}, 0xffff",
            $instruction,
            $lhs,
            $rhs,
            $condition,
            $dst
        )
    };
}

/// Conditional select equality test using 32-bit `:w` registers
macro_rules! cseleq32 {
    ($instruction:expr, $lhs:expr, $rhs:expr, $condition:expr, $dst:expr) => {
        cseleq!(
            "eor {0:w}, {1:w}, {2:w}",
            "cmp {0:w}, 0",
            $instruction,
            $lhs,
            $rhs,
            $condition,
            $dst
        )
    };
}

/// Conditional select equality test using 64-bit `:w` registers
macro_rules! cseleq64 {
    ($instruction:expr, $lhs:expr, $rhs:expr, $condition:expr, $dst:expr) => {
        cseleq!(
            "eor {0:x}, {1:x}, {2:x}",
            "cmp {0:x}, 0",
            $instruction,
            $lhs,
            $rhs,
            $condition,
            $dst
        )
    };
}

#[cfg_attr(docsrs, doc(cfg(true)))]
impl Cmov for u16 {
    #[inline]
    fn cmovnz(&mut self, value: &Self, condition: Condition) {
        csel32!("csel {1:w}, {2:w}, {3:w}, NE", self, value, condition);
    }

    #[inline]
    fn cmovz(&mut self, value: &Self, condition: Condition) {
        csel32!("csel {1:w}, {2:w}, {3:w}, EQ", self, value, condition);
    }
}

#[cfg_attr(docsrs, doc(cfg(true)))]
impl Cmov for u32 {
    #[inline]
    fn cmovnz(&mut self, value: &Self, condition: Condition) {
        csel32!("csel {1:w}, {2:w}, {3:w}, NE", self, value, condition);
    }

    #[inline]
    fn cmovz(&mut self, value: &Self, condition: Condition) {
        csel32!("csel {1:w}, {2:w}, {3:w}, EQ", self, value, condition);
    }
}

#[cfg_attr(docsrs, doc(cfg(true)))]
impl Cmov for u64 {
    #[inline]
    fn cmovnz(&mut self, value: &Self, condition: Condition) {
        csel64!("csel {1:x}, {2:x}, {3:x}, NE", self, value, condition);
    }

    #[inline]
    fn cmovz(&mut self, value: &Self, condition: Condition) {
        csel64!("csel {1:x}, {2:x}, {3:x}, EQ", self, value, condition);
    }
}

#[cfg_attr(docsrs, doc(cfg(true)))]
impl CmovEq for u16 {
    #[inline]
    fn cmovne(&self, rhs: &Self, input: Condition, output: &mut Condition) {
        cseleq16!("csel {3:w}, {4:w}, {5:w}, NE", self, rhs, input, output);
    }

    #[inline]
    fn cmoveq(&self, rhs: &Self, input: Condition, output: &mut Condition) {
        cseleq16!("csel {3:w}, {4:w}, {5:w}, EQ", self, rhs, input, output);
    }
}

#[cfg_attr(docsrs, doc(cfg(true)))]
impl CmovEq for u32 {
    #[inline]
    fn cmovne(&self, rhs: &Self, input: Condition, output: &mut Condition) {
        cseleq32!("csel {3:w}, {4:w}, {5:w}, NE", self, rhs, input, output);
    }

    #[inline]
    fn cmoveq(&self, rhs: &Self, input: Condition, output: &mut Condition) {
        cseleq32!("csel {3:w}, {4:w}, {5:w}, EQ", self, rhs, input, output);
    }
}

#[cfg_attr(docsrs, doc(cfg(true)))]
impl CmovEq for u64 {
    #[inline]
    fn cmovne(&self, rhs: &Self, input: Condition, output: &mut Condition) {
        cseleq64!("csel {3:x}, {4:x}, {5:x}, NE", self, rhs, input, output);
    }

    #[inline]
    fn cmoveq(&self, rhs: &Self, input: Condition, output: &mut Condition) {
        cseleq64!("csel {3:x}, {4:x}, {5:x}, EQ", self, rhs, input, output);
    }
}
