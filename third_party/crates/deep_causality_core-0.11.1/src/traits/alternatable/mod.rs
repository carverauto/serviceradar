/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{AlternatableContext, AlternatableState, AlternatableValue};

/// Marker super-trait indicating that a carrier supports alternation on
/// **all three** mutable channels: value, context, and state.
///
/// `Alternatable<V, C, S>` carries no methods of its own; it is auto-
/// implemented by the blanket impl below for any type that already
/// implements [`AlternatableValue<V>`], [`AlternatableContext<C>`], and
/// [`AlternatableState<S>`]. Bound on it when generic code needs the full
/// triple capability; bound on the individual sub-traits when only one or
/// two channels need to be alternated.
///
/// The `error` and `logs` channels are intentionally **not** alternatable:
/// overwriting an error is a safety violation, and the log is append-only
/// by design.
///
/// # Note on the stateless carrier
///
/// [`crate::PropagatingEffect`] (where `State = Context = ()`) satisfies
/// the bound via the trivial unit-channel impls. `alternate_context(())`
/// and `alternate_state(())` are well-typed but observably no-ops apart
/// from the audit-log entry. The capability is meaningful on
/// [`crate::PropagatingProcess`].
pub trait Alternatable<V, C, S>:
    AlternatableValue<V> + AlternatableContext<C> + AlternatableState<S>
{
}

impl<T, V, C, S> Alternatable<V, C, S> for T where
    T: AlternatableValue<V> + AlternatableContext<C> + AlternatableState<S>
{
}
