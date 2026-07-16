/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::ScalarValue;

/// A trait that defines how to extract a scalar value from a structured input type.
///
/// The `ScalarProjector` trait enables decoupling of scalar signal extraction from data structures,
/// allowing structured or composite types (e.g., `GPSSample`, `IMUReading`, or `SymbolicTime`)
/// to be mapped onto simple scalar values (e.g., `f64`, `i64`) for use in causal inference,
/// thresholding, or signal comparison.
///
/// This is particularly useful in systems like DeepCausality, where reasoning operates over
/// `NumericalValue`s (e.g., `f64`) but data inputs may be structured or symbolic.
/// By implementing `ScalarProjector`, you gain the ability to compose, test, and swap
/// scalar extraction strategies without modifying the underlying data types.
///
/// # Associated Types
///
/// - `Input`: The structured data type from which to extract a scalar (e.g., `GPSSample`)
/// - `Scalar`: The scalar value extracted, which must implement [`ScalarValue`] (e.g., `f64`, `i64`)
///
/// # See Also
///
/// - [`ScalarValue`]: A trait representing primitive scalar types
/// - `Causaloid`: The core reasoning unit in DeepCausality that can consume projectors
pub trait ScalarProjector {
    /// The scalar value extracted from the input (must implement `ScalarValue`)
    type Scalar: ScalarValue;

    /// Extracts a scalar from `self`.
    fn project(&self) -> Self::Scalar;
}
