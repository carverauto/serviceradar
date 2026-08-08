//! Tests for previous bugs in the implementation.

#![allow(clippy::cast_possible_truncation, reason = "test")]

use cmov::{Cmov, CmovEq};
use core::hint::black_box;

#[test]
fn u64_cmoveq() {
    let n = 0x8200_0000_0000_0000u64;
    let mut cond = 0u8;
    n.cmoveq(&0, 1u8, &mut cond);

    // 0x8200_0000_0000_0000 is not equal to 0
    assert_eq!(cond, 0);
}

#[test]
fn cmovz_wrong_output() {
    // The black box is necessary here, as otherwise the compiler will
    // provide a constant 0 to the csel
    let condition: u32 = black_box(1 << 8);
    let mut left = 1;
    let right = 2;
    debug_assert_eq!(0, condition as u8);
    left.cmovz(&right, condition as u8);
    assert_eq!(left, right);
}

#[test]
fn cmoveq_wrong_output_u16() {
    let input = 1;
    let mut output = 0;
    let left: u32 = black_box(1 << 16);
    let right: u32 = black_box(1 << 17);
    debug_assert_eq!(left as u16, right as u16);
    (left as u16).cmoveq(&(right as u16), input, &mut output);
    assert_eq!(input, output);
}

#[test]
fn cmoveq_wrong_output_i16() {
    let input = 1;
    let mut output = 0;
    let left: u32 = black_box(1 << 16);
    let right: u32 = black_box(1 << 17);
    debug_assert_eq!(left as i16, right as i16);
    (left as i16).cmoveq(&(right as i16), input, &mut output);
    assert_eq!(input, output);
}
