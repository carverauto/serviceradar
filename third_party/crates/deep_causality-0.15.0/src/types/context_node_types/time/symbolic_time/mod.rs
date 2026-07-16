/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

mod display;
mod identifiable;
mod scalar_projector;
mod temporable;

/// A symbolic time representation for use in logic-based, non-numeric, or event-driven causal systems.
///
/// `SymbolicTime` models time points that are defined in terms of **symbolic relationships**
/// rather than purely numeric values. It wraps a `SymbolicTimeUnit` enum that encodes
/// relations like `"Before Event X"`, `"After Event Y"`, or `"Simultaneous with A and B"`,
/// while also assigning a numeric `i64` scalar value to make it compatible with
/// systems that require `Temporal<i64>`.
///
/// The `id` field is a globally unique numeric identifier for disambiguation and integration
/// with `Identifiable` graphs or context systems.
///
/// # Fields
/// - `id`: Unique identifier for the symbolic time point
/// - `time`: A `SymbolicTimeUnit` enum variant representing the qualitative relation
///
/// # Symbolic Semantics
/// Symbolic time allows reasoning over:
/// - Event ordering (before/after)
/// - Named time anchors (e.g., "init", "decision", "outcome")
/// - Simultaneity of events
///
/// This makes it useful in:
/// - Symbolic causal graphs
/// - Event calculus and temporal logic
/// - Explainable AI and decision traces
/// - Formal methods and simulations
///
/// # Examples
///
/// ```rust
/// use deep_causality::{SymbolicTime, SymbolicTimeUnit};
///
/// let t1 = SymbolicTime::new(
///     1,
///     SymbolicTimeUnit::Named("DecisionPoint".into(), 42),
/// );
///
/// let t2 = SymbolicTime::new(
///     2,
///     SymbolicTimeUnit::Before("SensorReading".into(), -10),
/// );
///
/// println!("{}", t1); // Output: #1, Named(DecisionPoint) @ 42
/// println!("{}", t2); // Output: #2, Before(SensorReading) @ -10
/// ```
///
/// # Trait Compatibility
/// - Implements `Identifiable` using `id`
/// - Implements `Temporal<i64>` using the scalar inside the `SymbolicTimeUnit`
/// - Can be used in graphs, timelines, or symbolic propagation engines
///
/// # Note
/// While the scalar time value (`i64`) enables numeric compatibility,
/// its semantic interpretation must be **context-dependent**.
/// Do not rely solely on numeric ordering when symbolic intent (e.g., `Simultaneous`)
/// should override raw comparisons.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct SymbolicTime {
    id: u64,
    time: SymbolicTimeUnit,
}

impl SymbolicTime {
    pub fn new(id: u64, time: SymbolicTimeUnit) -> Self {
        Self { id, time }
    }

    pub fn time(&self) -> &SymbolicTimeUnit {
        &self.time
    }
}

/// Represents a symbolic unit of time with a qualitative relationship to named events.
///
/// Each variant carries a human-readable label (or multiple labels) and a numeric scalar
/// `i64` value for optional ordering, interval estimation, or compatibility with systems
/// that require `Temporal<i64>`.
///
/// # Variants
///
/// - `Before(label, t)`
///   - Indicates a time **before** the given label (e.g., `"Before(SensorTrigger)"`)
///   - Scalar `t` is expected to be negative
///
/// - `Named(label, t)`
///   - A **named symbolic anchor point** in time (e.g., `"Init"`, `"Decision"`)
///   - Scalar `t` is typically zero or positive
///
/// - `After(label, t)`
///   - Indicates a time **after** the given event
///   - Scalar `t` is always positive
///
/// - `Simultaneous(labels, t)`
///   - Represents multiple symbolic labels occurring at the **same scalar time**
///   - Useful for modeling concurrency or grouped events
///
/// # Use Cases
/// - Symbolic and rule-based AI systems
/// - Temporal logic systems (e.g., LTL, CTL)
/// - Causal modeling without physical clocks
/// - Traceable inference timelines
///
/// # Example
/// ```rust
/// use deep_causality::SymbolicTimeUnit;
///
/// let t = SymbolicTimeUnit::Simultaneous(
///     vec!["SensorA".into(), "SensorB".into()],
///     100,
/// );
///
/// match &t {
///     SymbolicTimeUnit::Simultaneous(labels, time) => {
///         assert_eq!(labels.len(), 2);
///         assert_eq!(*time, 100);
///     },
///     _ => unreachable!(),
/// }
/// ```
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum SymbolicTimeUnit {
    /// A symbolic time point before the given label (e.g., "Before('start')").
    Before(String, i64),

    /// A symbolic named anchor point in the timeline (e.g., "Init", "Decision").
    Named(String, i64),

    /// A symbolic time point after the given label (e.g., "After('end')").
    After(String, i64),

    /// Multiple events that occur simultaneously and share a scalar time.
    Simultaneous(Vec<String>, i64),
}
