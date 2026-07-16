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

/// A time model representing **Lorentzian (physical) time** in relativistic spacetimes.
///
/// `LorentzianTime` corresponds to the real-valued **coordinate time** used in
/// special and general relativity. It is the standard temporal axis in
/// Minkowski and Lorentzian manifolds with metric signature **(− + + +)**.
///
/// This time coordinate governs:
/// - **Causal structure** (what can affect what)
/// - **Relativistic dynamics** (time dilation, simultaneity)
/// - **Spacetime intervals** (light cones, timelike/spacelike separation)
///
/// # Fields
/// - `id`: Unique numeric identifier for this time point
/// - `time_scale`: Resolution or unit granularity (e.g., `Seconds`, `Nanoseconds`)
/// - `time_unit`: Real-valued coordinate time in seconds or specified unit
///
/// # Example
/// ```rust
/// use deep_causality::{Identifiable, LorentzianTime, Temporal, TimeScale};
///
/// let t = LorentzianTime::new(1, TimeScale::Second, std::f64::consts::E);
///
/// assert_eq!(t.id(), 1);
/// assert_eq!(t.time_scale(), TimeScale::Second);
/// ```
///
/// # Use Cases
/// - Relativistic spacetime models (Minkowski, Schwarzschild, FLRW, etc.)
/// - General relativity simulations and geodesics
/// - Causal propagation using light cones
/// - Lorentz-invariant physical systems
///
/// # Trait Compatibility
/// - Implements `Identifiable` via `id`
/// - Implements `Temporal<f64>` via `time_unit`
///
/// # Theoretical Background
/// Coordinate time in Lorentzian geometry appears in the invariant spacetime interval:
///
/// ```text
/// s² = -c²·t² + x² + y² + z²
/// ```
///
/// Unlike Euclidean time (used in QFT), Lorentzian time preserves **causal order**
/// and reflects real-world physics.
///
/// # See also
/// - `EuclideanTime` for Wick-rotated quantum/statistical domains
/// - `SymbolicTime` for logic-based systems
#[derive(Debug, Copy, Clone, PartialEq)]
pub struct LorentzianTime {
    /// Unique numeric identifier for the time instance.
    id: u64,

    /// The scale/granularity of the time unit (e.g., Seconds, Nanoseconds).
    time_scale: TimeScale,

    /// Real-valued coordinate time in seconds or scaled units.
    time_unit: f64,
}

impl LorentzianTime {
    pub fn new(id: u64, time_scale: TimeScale, time_unit: f64) -> Self {
        Self {
            id,
            time_scale,
            time_unit,
        }
    }
}

impl From<LorentzianTime> for TimeKind {
    fn from(t: LorentzianTime) -> Self {
        TimeKind::Lorentzian(t)
    }
}
