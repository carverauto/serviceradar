/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

mod display;
mod identifiable;
mod scalar_projector;
mod temporable;

use crate::{DiscreteTime, EntropicTime, EuclideanTime, LorentzianTime};

/// An enumeration of supported time models for unified, heterogeneous temporal reasoning.
///
/// `TimeKind` provides a polymorphic abstraction over multiple **time semantics**
/// used in both physical and symbolic systems. It allows causal models,
/// simulations, or reasoning engines to switch between **continuous**, **discrete**,
/// and **qualitative** time representations in a unified way.
///
/// This is especially useful in hybrid environments where:
/// - Time may be physical in one subsystem and symbolic in another
/// - Models must support both discrete and continuous timelines
/// - Simulation layers require flexible temporal modes
///
/// # Use Cases
/// - Dynamic systems with configurable time semantics
/// - Spacetime graphs mixing physics and logic
/// - Abstract symbolic timelines
/// - Causal models across domains (AI, physics, engineering)
///
/// # Variants
///
/// - `Lorentzian(LorentzianTime)`
///   - Real-valued time coordinate used in special/general relativity
///   - Metric signature: `(-+++), t ∈ ℝ`
///   - Appears in causal structure and physical propagation
///
/// - `Euclidean(EuclideanTime)`
///   - Imaginary time (Wick-rotated), used in quantum/statistical physics
///   - Metric signature: `(++++)`
///   - Common in quantum field theory (QFT), path integrals, and lattice simulations
///
/// - `Discrete(DiscreteTime)`
///   - Integer-valued ticks or steps (e.g., for simulation time, state machines)
///   - Unitless or context-dependent
///   - Used in agent-based models, control systems, and RL environments
///
// /// - `Symbolic(SymbolicTime)`
// ///   - Qualitative, label-based time points (e.g., `"Before(A)"`, `"T1"`)
// ///   - Useful in symbolic AI, planning, explainable graphs, or formal logic
///
/// # Example
///
/// ```rust
/// use deep_causality::*;
///
/// let lorentz = TimeKind::Lorentzian(LorentzianTime::new(1, TimeScale::Second, 3.14));
/// let discrete = TimeKind::Discrete(DiscreteTime::new(2, TimeScale::Second, 42));
///
/// println!("L: {}, ID: {}", lorentz, lorentz.id());
/// println!("D: {}, ID: {}", discrete, discrete.id());
/// ```
///
/// # Trait Compatibility
/// - Implements `Identifiable` based on the inner ID
/// - Implements `Display` for readable output
/// - Can be extended to support `Temporal<f64>` and `Temporal<u64>`
///
/// # See also
/// - `LorentzianTime`, `EuclideanTime`, `DiscreteTime`, `SymbolicTime`
/// - `SpaceKind` for spatial equivalents
/// - `SpacetimeInterval` for reasoning over separation or causality
///
/// # Design Note
/// For models that need a single time field but must support multiple
/// representations of time (e.g., symbolic vs physical), `TimeKind` provides
/// a principled and type-safe solution.
#[derive(Debug, Copy, Clone, PartialEq)]
pub enum TimeKind {
    /// Imaginary-time axis for quantum/statistical models via Wick rotation.
    Euclidean(EuclideanTime),

    /// Entropic time for emergent causal models via entropy.
    Entropic(EntropicTime),

    /// Discrete tick-based time (steps, iterations, simulation frames).
    Discrete(DiscreteTime),

    /// Real-valued coordinate time in Lorentzian (causal, relativistic) geometry.
    Lorentzian(LorentzianTime),
    // /// Symbolic or qualitative time labels (e.g., "before event A", "T1").
    // Symbolic(SymbolicTime),
}
