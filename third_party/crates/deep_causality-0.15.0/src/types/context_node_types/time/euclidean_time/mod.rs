/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

mod adjustable;
mod display;
mod identifiable;
mod scalar_projector;
mod temporable;

use crate::{TimeKind, TimeScale};

/// A time model based on **Euclidean (imaginary) time**, primarily used in theoretical and computational physics.
///
/// In contrast to real-valued Lorentzian time (used in classical and relativistic physics),
/// **Euclidean time** is defined by the **Wick rotation**:
///
/// ```text
/// τ = i · t
/// ```
///
/// This rotation converts Minkowski spacetime (− + + +) into a **positive-definite Euclidean metric** (+ + + +),
/// which is advantageous for:
/// - **Statistical mechanics**
/// - **Quantum field theory (QFT)**
/// - **Path integral formulations**
/// - **Numerical simulations**, such as lattice QCD or Monte Carlo methods
///
/// Though the imaginary component `i` is not explicitly modeled in this struct,
/// `EuclideanTime` semantically represents the rotated, **imaginary-time axis** as a real-valued scalar `f64`.
///
/// # Fields
/// - `id`: Unique identifier for the time instance
/// - `time_scale`: Time resolution or granularity (e.g., `Seconds`, `Milliseconds`)
/// - `time_unit`: Scalar value of the time coordinate in the Euclidean regime
///
/// # Example
/// ```rust
/// use deep_causality::{EuclideanTime, Identifiable, Temporal, TimeScale};
///
/// let tau = EuclideanTime::new(42, TimeScale::Second, std::f64::consts::PI);
///
/// assert_eq!(tau.id(), 42);
/// assert_eq!(tau.time_scale(), TimeScale::Second);
/// ```
///
/// # Use Cases
/// - Euclidean quantum mechanics or statistical field theory
/// - Simulations where real-time evolution is unstable
/// - Causal modeling systems extended to Wick-rotated or thermal domains
///
/// # Trait Compatibility
/// - Implements `Identifiable` via `id`
/// - Implements `Temporal<f64>` via `time_unit`
///
/// # Important Note
/// The field `time_unit` contains a **real-valued representation of imaginary time** (τ),
/// which is conceptually distinct from Lorentzian coordinate time `t`.
/// Use this type only in contexts where **analytic continuation** or
/// **positive-definite geometry** is intended.
///
/// # See also
/// - `LorentzianTime` for real-time physical models
/// - `ProperTime` for observer-dependent clock time
/// - `SymbolicTime` for abstract, label-based event time
#[derive(Debug, Copy, Clone, PartialEq)]
pub struct EuclideanTime {
    /// Unique numeric identifier for the time instance.
    id: u64,

    /// Resolution or interpretation of the time unit (e.g., Seconds, Milliseconds).
    time_scale: TimeScale,

    /// The Euclidean (imaginary) time value, represented as a real number.
    time_unit: f64,
}

impl EuclideanTime {
    pub fn new(id: u64, time_scale: TimeScale, time_unit: f64) -> Self {
        Self {
            id,
            time_scale,
            time_unit,
        }
    }
}

impl From<EuclideanTime> for TimeKind {
    fn from(t: EuclideanTime) -> Self {
        TimeKind::Euclidean(t)
    }
}
