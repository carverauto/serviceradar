/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use std::collections::BTreeSet;
use std::fmt::Display;

/// A minimal spacetime model preserving only causal and angular structure,
/// based on conformal geometry.
///
/// `ConformalSpacetime` models **causal relationships** (what can influence what)
/// without assigning meaning to distances or durations. This is useful for:
/// - **Conformal diagrams** (Penrose diagrams)
/// - **Asymptotic analysis** (e.g., black hole horizons, AdS boundaries)
/// - **Symbolic causal inference** when exact metrics are unknown or irrelevant
///
/// # Fields
/// - `id`: Unique identifier for this event or node
/// - `label`: Optional symbolic annotation (e.g., "i+", "scri−", "origin")
/// - `causal_links`: IDs of other nodes reachable via causal paths
///
/// # Notes
/// - This type ignores units, curvature, and absolute scale
/// - It encodes **who can affect whom**, not how or when
/// - Useful when embedding causal graphs inside bounded spacetime representations
///
/// # Example
/// ```
/// use deep_causality::*;
///
/// let mut n1 = ConformalSpacetime::new(1, Some("Origin".into()));
/// let mut n2 = ConformalSpacetime::new(2, Some("Infinity".into()));
///
/// n1.link_to(2); // n1 can influence n2
///
/// assert!(n1.can_affect(2));
/// ```
#[derive(Debug, Clone, PartialEq)]
pub struct ConformalSpacetime {
    /// Unique identifier for this event
    pub id: u64,

    /// Optional symbolic label (e.g., "i+", "scri", "horizon")
    pub label: Option<String>,

    /// Causally reachable nodes (light cone structure only)
    pub causal_links: std::collections::BTreeSet<u64>,
}

impl ConformalSpacetime {
    pub fn new(id: u64, label: Option<String>) -> Self {
        Self {
            id,
            label,
            causal_links: BTreeSet::new(),
        }
    }
}

impl ConformalSpacetime {
    /// Adds a forward causal connection (like drawing a light ray)
    pub fn link_to(&mut self, other_id: u64) {
        self.causal_links.insert(other_id);
    }

    /// Checks if this node can causally influence the other node
    pub fn can_affect(&self, other_id: u64) -> bool {
        self.causal_links.contains(&other_id)
    }

    /// Returns number of causal outputs (fanout of light cone)
    pub fn fanout(&self) -> usize {
        self.causal_links.len()
    }
}

impl Display for ConformalSpacetime {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "ConformalSpacetime {{ id: {}, label: {:?} }}",
            self.id, self.label
        )
    }
}
