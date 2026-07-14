/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
pub mod stateful;

use crate::{Identifiable, PropagatingEffect};

/// The Causable trait defines the core behavior for all causal elements.
///
/// It requires implementing the Identifiable trait.
pub trait Causable: Identifiable {
    /// Determines if the causaloid represents a single, indivisible causal unit.
    ///
    /// This method helps distinguish base-case causaloids from composite structures
    /// like collections or graphs.
    ///
    /// # Returns
    ///
    /// `true` if the implementor is a `Singleton` type, `false` otherwise.
    fn is_singleton(&self) -> bool;
}

pub trait MonadicCausable<I, O> {
    /// The core monadic bind operation.
    /// Takes a monadic context (the incoming effect), applies the embedded causal logic,
    /// and returns the new monadic context (the outgoing effect).
    fn evaluate(&self, incoming_effect: &PropagatingEffect<I>) -> PropagatingEffect<O>;
}
