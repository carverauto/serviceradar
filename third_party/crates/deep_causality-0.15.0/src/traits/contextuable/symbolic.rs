/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::Identifiable;

/// Represents a symbolic, logical, or linguistic identity.
///
/// This trait allows integration of abstract knowledge representations
/// into a unified context system—such as:
/// - Atoms (`"A"`)
/// - Named terms (`goal(X)`)
/// - Logical constructs (`∀x.P(x) → Q(x)`)
///
/// The `Repr` type is intentionally generic to support structured representations:
/// enums, trees, strings, or AST nodes.
///
/// # Example
/// ```
/// use deep_causality::{Identifiable, Symbolic};
///
/// struct RuleNode { id: u64, term: String }
///
/// impl Identifiable for RuleNode {fn id(&self) -> u64 {
///         self.id
///     }}
///
/// impl Symbolic for RuleNode {
///     type Repr = String;
///     fn symbol(&self) -> &Self::Repr { &self.term }
/// }
/// ```
pub trait Symbolic: Identifiable {
    /// The representation type used to encode the symbolic value.
    type Repr;

    /// Returns a reference to the symbolic representation.
    fn symbol(&self) -> &Self::Repr;
}
