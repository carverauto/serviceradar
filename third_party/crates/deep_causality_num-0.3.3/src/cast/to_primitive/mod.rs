/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
mod to_primitive_float_impl;
mod to_primitive_isize_impl;
mod to_primitive_usize_impl;
mod to_primitive_wrapping_impl;

pub trait ToPrimitive {
    /// Converts the value of `self` to an `isize`. If the value cannot be
    /// represented by an `isize`, then `None` is returned.
    fn to_isize(&self) -> Option<isize>;

    /// Converts the value of `self` to an `i8`. If the value cannot be
    /// represented by an `i8`, then `None` is returned.
    fn to_i8(&self) -> Option<i8>;

    /// Converts the value of `self` to an `i16`. If the value cannot be
    /// represented by an `i16`, then `None` is returned.
    fn to_i16(&self) -> Option<i16>;

    /// Converts the value of `self` to an `i32`. If the value cannot be
    /// represented by an `i32`, then `None` is returned.
    fn to_i32(&self) -> Option<i32>;

    /// Converts the value of `self` to an `i64`. If the value cannot be
    /// represented by an `i64`, then `None` is returned.
    fn to_i64(&self) -> Option<i64>;

    /// Converts the value of `self` to an `i128`. If the value cannot be
    /// represented by an `i128` (`i64` under the default implementation), then
    /// `None` is returned.
    ///
    /// The default implementation converts through `to_i64()`. Types implementing
    /// this trait should override this method if they can represent a greater range.
    fn to_i128(&self) -> Option<i128>;

    /// Converts the value of `self` to a `usize`. If the value cannot be
    /// represented by a `usize`, then `None` is returned.
    fn to_usize(&self) -> Option<usize>;

    /// Converts the value of `self` to a `u8`. If the value cannot be
    /// represented by a `u8`, then `None` is returned.
    fn to_u8(&self) -> Option<u8>;

    /// Converts the value of `self` to a `u16`. If the value cannot be
    /// represented by a `u16`, then `None` is returned.
    fn to_u16(&self) -> Option<u16>;

    /// Converts the value of `self` to a `u32`. If the value cannot be
    /// represented by a `u32`, then `None` is returned.
    fn to_u32(&self) -> Option<u32>;

    /// Converts the value of `self` to a `u64`. If the value cannot be
    /// represented by a `u64`, then `None` is returned.
    fn to_u64(&self) -> Option<u64>;

    /// Converts the value of `self` to a `u128`. If the value cannot be
    /// represented by a `u128` (`u64` under the default implementation), then
    /// `None` is returned.
    fn to_u128(&self) -> Option<u128>;

    /// Converts the value of `self` to an `f32`. Overflows may map to positive
    /// or negative inifinity, otherwise `None` is returned if the value cannot
    /// be represented by an `f32`.
    fn to_f32(&self) -> Option<f32>;

    /// Converts the value of `self` to an `f64`. Overflows may map to positive
    /// or negative inifinity, otherwise `None` is returned if the value cannot
    /// be represented by an `f64`.
    fn to_f64(&self) -> Option<f64>;
}
