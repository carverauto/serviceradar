/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::AlternatableValue;

/// Causal-inference vocabulary trait for value substitution on a monadic
/// effect system.
///
/// `Intervenable<V>` is the surface that speaks Pearl's `do(...)` language:
/// `effect.intervene(x)` reads as "force the value at this point of the
/// chain to be `x`," which is exactly an interventional substitution on
/// the value channel.
///
/// Mechanically, `intervene` is the same operation as
/// [`AlternatableValue::alternate_value`]: replace the carried value,
/// preserve state/context, short-circuit on error, append one audit-log
/// entry. This trait is a thin vocabulary alias: it is a super-trait of
/// [`AlternatableValue<V>`] whose only method delegates to
/// `alternate_value`. The blanket impl below means every carrier that
/// implements [`AlternatableValue<V>`] is automatically `Intervenable<V>`.
///
/// Audit-log note: because `intervene` delegates to `alternate_value`,
/// the log marker recorded is `!!ValueAlternation!!`.
/// The two API surfaces share one underlying operation and one underlying log entry.
pub trait Intervenable<V>: AlternatableValue<V> {
    /// Force-substitute the carried value with `new_value`, preserving
    /// the rest of the chain. Delegates to
    /// [`AlternatableValue::alternate_value`].
    fn intervene(self, new_value: V) -> Self
    where
        Self: Sized,
    {
        self.alternate_value(new_value)
    }
}

impl<T, V> Intervenable<V> for T where T: AlternatableValue<V> {}
