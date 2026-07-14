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

/// A time model representing **discrete, uniformly spaced ticks** instead of continuous physical time.
///
/// `DiscreteTime` is designed for systems that evolve in **fixed increments**, such as:
/// - Simulation steps
/// - Control loops
/// - State machines
/// - Reinforcement learning environments
/// - Event-driven or digital logic systems
///
/// This model is ideal when:
/// - You don’t need wall-clock time or sub-second resolution
/// - You care only about the **order and progression** of steps
/// - Time is measured in **counted ticks** or iterations
///
/// # Fields
/// - `id`: Unique numeric identifier for the time point
/// - `tick_scale`: Scale of the tick (e.g., `Milliseconds`, `Microseconds`, `Seconds`)
/// - `tick_unit`: The current tick index (`u64`), typically monotonically increasing
///
/// # Examples
///
/// ```rust
/// use deep_causality::{DiscreteTime, Temporal, TimeScale};
///
/// let t0 = DiscreteTime::new(1, TimeScale::Microseconds, 0);
/// let t1 = DiscreteTime::new(2, TimeScale::Microseconds, 1);
///
/// assert!(t0.time_unit() < t1.time_unit());
/// assert_eq!(t0.time_scale(), TimeScale::Microseconds);
/// ```
///
/// # Trait Compatibility
/// - Implements `Identifiable` via `id`
/// - Implements `Temporal<u64>`, so it can be used in any time-aware causal context
///
/// # Use Cases
/// - Agent-based simulations with fixed timesteps
/// - Ticking state machines (e.g., embedded control)
/// - Digital logic simulation
/// - Environments where **temporal resolution** is implicit or constant
///
/// # Note
/// While `tick_unit` is a `u64` and ordered, it does **not** imply any physical duration
/// unless paired with a meaningful `TimeScale`. The interpretation of ticks is context-dependent.
///
/// # See also
/// - `SymbolicTime` for non-numeric symbolic events
/// - `LorentzianTime` or `ProperTime` for physical time
#[derive(Debug, Copy, Clone, Hash, Eq, PartialEq)]
pub struct DiscreteTime {
    /// Unique identifier for this discrete time instance.
    id: u64,

    /// Semantic scale of the ticks (e.g., Steps, Cycles, Milliseconds).
    tick_scale: TimeScale,

    /// The actual tick count (monotonic unit of progression).
    tick_unit: u64,
}

impl DiscreteTime {
    pub fn new(id: u64, tick_scale: TimeScale, tick_unit: u64) -> Self {
        Self {
            id,
            tick_scale,
            tick_unit,
        }
    }
}

impl From<DiscreteTime> for TimeKind {
    fn from(t: DiscreteTime) -> Self {
        TimeKind::Discrete(t)
    }
}
