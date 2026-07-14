/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

#![cfg_attr(not(feature = "std"), no_std)]
extern crate core;

mod alias;
mod cast;
mod float;
mod float_106;
mod float_option;
mod identity;
mod integer;
mod num;

// Alias types
pub use crate::alias::{Matrix3, Vector3};

// Casts
pub use crate::cast::as_primitive::AsPrimitive;
pub use crate::cast::as_scalar::float_as_scalar_impl::FloatAsScalar;
pub use crate::cast::as_scalar::int_as_scalar_impl::IntAsScalar;
pub use crate::cast::from_primitive::FromPrimitive;
pub use crate::cast::num_cast::NumCast;
pub use crate::cast::to_float::{FloatFromInt, IntoFloat};
pub use crate::cast::to_primitive::ToPrimitive;

// Float number types
pub use crate::float::Float;
pub use crate::float_106::Float106;

// Float option number type
pub use crate::float_option::FloatOption;

// Identity types
pub use crate::identity::one::{ConstOne, One};
pub use crate::identity::zero::{ConstZero, Zero};

// Integer types
pub use crate::integer::{Integer, SignedInt, UnsignedInt};

// General numeric traits
pub use crate::num::Num;
pub use crate::num::num_ops::*;
