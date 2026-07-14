/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use std::fmt::{Display, Formatter};

/// Represents the structural type of a `Causaloid`.
///
/// This enum is a key part of the `Causaloid`'s internal design. It allows a
/// `Causaloid` to act as a polymorphic container, holding either a single causal
/// element, a collection of elements, or a complex causal graph.
///
/// The primary use of `CausaloidType` is to dispatch method calls like `verify`
/// or `explain` to the appropriate underlying implementation based on the structure
/// it contains. This avoids dynamic dispatch (e.g., `dyn Trait`) and keeps the
/// `Causaloid`'s data layout concrete and efficient.
///
/// # Variants
///
/// * `Singleton` - Represents a `Causaloid` containing a single, indivisible causal unit.
///   This is the most basic form.
/// * `Collection` - Represents a `Causaloid` containing a collection of other `Causaloid`s,
///   typically stored in a `Vec`. The elements in the collection are treated as
///   independent units for reasoning.
/// * `Graph` - Represents a `Causaloid` containing a directed acyclic graph (DAG)
///   of other `Causaloid`s. This structure allows for modeling complex causal
///
#[derive(Debug, Clone, Copy, PartialEq, PartialOrd)]
pub enum CausaloidType {
    Singleton,
    Collection,
    Graph,
}

impl Display for CausaloidType {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
