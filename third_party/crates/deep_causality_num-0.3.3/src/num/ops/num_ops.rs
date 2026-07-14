/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::Num;
use core::ops::{Add, AddAssign, Div, DivAssign, Mul, MulAssign, Rem, RemAssign, Sub, SubAssign};

/// Generic trait for types implementing basic numeric operations
///
/// This is automatically implemented for types which implement the operators.
pub trait NumOps<Rhs = Self, Output = Self>:
    Add<Rhs, Output = Output>
    + Sub<Rhs, Output = Output>
    + Mul<Rhs, Output = Output>
    + Div<Rhs, Output = Output>
    + Rem<Rhs, Output = Output>
{
}

impl<T, Rhs, Output> NumOps<Rhs, Output> for T where
    T: Add<Rhs, Output = Output>
        + Sub<Rhs, Output = Output>
        + Mul<Rhs, Output = Output>
        + Div<Rhs, Output = Output>
        + Rem<Rhs, Output = Output>
{
}

/// The trait for `Num` types which also implement numeric operations taking
/// the second operand by reference.
///
/// This is automatically implemented for types which implement the operators.
pub trait NumRef: Num + for<'r> NumOps<&'r Self> {}
impl<T> NumRef for T where T: Num + for<'r> NumOps<&'r T> {}

/// The trait for `Num` references which implement numeric operations, taking the
/// second operand either by value or by reference.
///
/// This is automatically implemented for all types which implement the operators. It covers
/// every type implementing the operations though, regardless of it being a reference or
/// related to `Num`.
pub trait RefNum<Base>: NumOps<Base, Base> + for<'r> NumOps<&'r Base, Base> {}
impl<T, Base> RefNum<Base> for T where T: NumOps<Base, Base> + for<'r> NumOps<&'r Base, Base> {}

/// Generic trait for types implementing numeric assignment operators (like `+=`).
///
/// This is automatically implemented for types which implement the operators.
pub trait NumAssignOps<Rhs = Self>:
    AddAssign<Rhs> + SubAssign<Rhs> + MulAssign<Rhs> + DivAssign<Rhs> + RemAssign<Rhs>
{
}

impl<T, Rhs> NumAssignOps<Rhs> for T where
    T: AddAssign<Rhs> + SubAssign<Rhs> + MulAssign<Rhs> + DivAssign<Rhs> + RemAssign<Rhs>
{
}

/// The trait for `Num` types which also implement assignment operators.
///
/// This is automatically implemented for types which implement the operators.
pub trait NumAssign: Num + NumAssignOps {}
impl<T> NumAssign for T where T: Num + NumAssignOps {}

/// The trait for `NumAssign` types which also implement assignment operations
/// taking the second operand by reference.
///
/// This is automatically implemented for types which implement the operators.
pub trait NumAssignRef: NumAssign + for<'r> NumAssignOps<&'r Self> {}
impl<T> NumAssignRef for T where T: NumAssign + for<'r> NumAssignOps<&'r T> {}
