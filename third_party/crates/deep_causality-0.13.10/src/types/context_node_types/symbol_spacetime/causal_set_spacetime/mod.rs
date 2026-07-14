/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use std::collections::BTreeSet;
use std::fmt::Display;

/// A symbolic, discrete model of spacetime based on causal set theory (CST).
///
/// `CausalSetSpacetime` represents events not by coordinates, but by their
/// **causal relationships** — i.e., who can influence whom. This allows reasoning
/// about causality and temporal order **without requiring geometry, coordinates, or metrics**.
///
/// This type is part of a broader class of **non-metric causal models**, ideal for:
/// - Symbolic AI
/// - Quantum gravity models
/// - Abstract causal graphs
///
/// # Fields
/// - `id`: Unique identifier for the event
/// - `label`: Optional semantic tag (e.g., "observation", "input")
/// - `predecessors`: Set of event IDs that causally precede this one
///
/// # Notes
/// - This model assumes **transitive reduction** (i.e., minimal representation of causality)
/// - No distance or duration is defined — just causal topology
/// - Cycles are disallowed by construction
///
/// # Example
/// ```
/// use deep_causality::*;
///
/// let mut e1 = CausalSetSpacetime::new(1, Some("A".into()));
/// let mut e2 = CausalSetSpacetime::new(2, Some("B".into()));
///
/// e2.add_predecessor(1);
///
/// assert!(e2.predecessors.contains(&1));
/// assert_eq!(e2.label.as_deref(), Some("B"));
/// ```
#[derive(Debug, Clone, PartialEq)]
pub struct CausalSetSpacetime {
    /// Unique event identifier
    pub id: u64,

    /// Optional label or annotation for semantic reasoning
    pub label: Option<String>,

    /// List of causally preceding event IDs (must be acyclic)
    pub predecessors: std::collections::BTreeSet<u64>,
}

impl CausalSetSpacetime {
    pub fn new(id: u64, label: Option<String>) -> Self {
        Self {
            id,
            label,
            predecessors: BTreeSet::new(),
        }
    }
}

impl CausalSetSpacetime {
    /// Adds a causal link (edge) from another event that precedes this one.
    pub fn add_predecessor(&mut self, parent_id: u64) {
        self.predecessors.insert(parent_id);
    }

    /// Checks whether the current event is causally downstream of another.
    pub fn is_after(&self, other_id: u64) -> bool {
        self.predecessors.contains(&other_id)
    }

    /// Returns the causal depth (number of direct predecessors)
    pub fn causal_depth(&self) -> usize {
        self.predecessors.len()
    }
}

impl Display for CausalSetSpacetime {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "CausalSetSpacetime {{ id: {}, label: {:?}, predecessors: {:?} }}",
            self.id, self.label, self.predecessors
        )
    }
}
