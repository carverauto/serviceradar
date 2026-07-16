/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

#[cfg(feature = "alloc")]
use alloc::string::String;
/// The unique identifier for a Cause or Context in the Causality Graph
pub type IdentificationValue = u64;

pub type TeloidTag = &'static str;
pub type TeloidID = u64;
pub type ContextId = u64;
pub type ContextoidId = u64;
pub type CausaloidId = u64;

#[cfg(feature = "alloc")]
/// A string value that provides a human-readable description of a Cause or Context
pub type DescriptionValue = String;
/// A floating point value that represents a numerical measure
pub type NumericalValue = f64;

/// A type alias for unsigned integers, used for numerical counting and indexing
pub type NumberType = u64;
/// A type alias for floating point numbers, used for numerical calculations
pub type FloatType = f64;
