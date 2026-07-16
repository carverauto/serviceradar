/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! # HKT Effect System Module
//!
//! This module implements a Higher-Kinded Type (HKT) effect system for the generative subsystem.
//! It provides an arity-3 monad that tracks computation results, errors, and audit logs.
//!
//! ## Overview
//!
//! The effect system wraps every operation execution in a monadic context that automatically
//! captures:
//! - **Value**: The computation result (wrapped in `Option<T>`)
//! - **Error**: Any fatal errors that occurred (wrapped in `Option<ModelValidationError>`)
//! - **Logs**: A detailed audit trail of all modifications (`ModificationLog`)
//!
//! ## Key Types
//!
//! - [`GraphGeneratableEffect<T, E, L>`]: The core effect type wrapping values, errors, and logs
//! - [`ModificationLog`]: Container for audit trail entries
//! - [`ModificationLogEntry`]: Individual log entry with timestamp, operation details, and metadata
//! - [`OpStatus`]: Operation status (Success/Failure)
//! - [`AuditableGraphGenerator<T>`]: Type alias for the complete effect system
//!
//! ## Design
//!
//! This implementation uses the `deep_causality_haft` library to provide:
//! - `HKT` and `HKT3` traits for higher-kinded type abstraction
//! - `Functor`, `Applicative`, and `Monad` traits for composable effects
//! - `Effect3` witness for fixing error and log types
//!
//! ## Example
//!
//! ```rust,ignore
//! use deep_causality::types::generative_types::effect_system::*;
//!
//! // Create a successful effect
//! let effect = GraphGeneratableEffect {
//!     value: Some(my_state),
//!     error: None,
//!     logs: ModificationLog::new(),
//! };
//!
//! // Use monadic operations
//! let result = effect.map(|state| transform(state));
//! ```

use crate::{ModelValidationError, ModificationLog};
use deep_causality_haft::{
    Applicative, Effect3, Functor, HKT, HKT3, LogAppend, Monad, NoConstraint, Placeholder, Pure,
};

/// HKT witness type for the graph generatable effect system.
///
/// This type is used internally by the HKT machinery to provide type-level
/// evidence for the effect system's structure.
pub struct GraphGeneratableEffectWitness<E, L>(Placeholder, E, L);

/// The core effect type for the HKT generative system.
///
/// This struct wraps computation results in a monadic context that tracks:
/// - The result value (or `None` if an error occurred)
/// - Any error that prevented computation
/// - A complete audit log of all operations
///
/// # Type Parameters
///
/// - `T`: The wrapped value type
/// - `E`: The error type (fixed to `ModelValidationError` in practice)
/// - `L`: The log type (fixed to `ModificationLog` in practice)
///
/// # Design
///
/// The `value` field is `Option<T>` rather than `T` to allow representing
/// error states without requiring `T: Default`. When an error occurs during
/// a monadic operation, the value becomes `None` and the error is captured.
#[derive(Debug, Clone)]
pub struct GraphGeneratableEffect<T, E, L> {
    /// The computation result, or `None` if an error occurred
    pub value: Option<T>,
    /// Any error that occurred during computation
    pub error: Option<E>,
    /// Complete audit trail of all operations
    pub logs: L,
}

impl<E, L> HKT for GraphGeneratableEffectWitness<E, L> {
    type Constraint = NoConstraint;
    type Type<T> = GraphGeneratableEffect<T, E, L>;
}

impl<E, L> HKT3<E, L> for GraphGeneratableEffectWitness<E, L> {
    type Type<T> = GraphGeneratableEffect<T, E, L>;
}

impl<E: Clone, L: Clone> Functor<GraphGeneratableEffectWitness<E, L>>
    for GraphGeneratableEffectWitness<E, L>
{
    fn fmap<A, B, Func>(m_a: <Self as HKT>::Type<A>, f: Func) -> <Self as HKT>::Type<B>
    where
        Func: FnMut(A) -> B,
    {
        let mut func = f;
        if m_a.error.is_some() {
            GraphGeneratableEffect {
                value: None,
                error: m_a.error,
                logs: m_a.logs,
            }
        } else if let Some(val) = m_a.value {
            GraphGeneratableEffect {
                value: Some(func(val)),
                error: m_a.error,
                logs: m_a.logs,
            }
        } else {
            GraphGeneratableEffect {
                value: None,
                error: m_a.error,
                logs: m_a.logs,
            }
        }
    }
}

impl<E, L> Pure<GraphGeneratableEffectWitness<E, L>> for GraphGeneratableEffectWitness<E, L>
where
    E: Clone,
    L: Clone + Default + LogAppend,
{
    fn pure<T>(value: T) -> <Self as HKT>::Type<T> {
        GraphGeneratableEffect {
            value: Some(value),
            error: None,
            logs: L::default(),
        }
    }
}

impl<E: Clone, L: Clone + Default + LogAppend> Applicative<GraphGeneratableEffectWitness<E, L>>
    for GraphGeneratableEffectWitness<E, L>
{
    fn apply<A, B, Func>(
        f_ab: <Self as HKT>::Type<Func>,
        m_a: <Self as HKT>::Type<A>,
    ) -> <Self as HKT>::Type<B>
    where
        Func: FnMut(A) -> B,
        A: Clone,
    {
        let mut combined_logs = f_ab.logs;
        let mut m_a_logs = m_a.logs;
        combined_logs.append(&mut m_a_logs);

        if let Some(err) = f_ab.error {
            return GraphGeneratableEffect {
                value: None,
                error: Some(err),
                logs: combined_logs,
            };
        }

        if let Some(err) = m_a.error {
            return GraphGeneratableEffect {
                value: None,
                error: Some(err),
                logs: combined_logs,
            };
        }

        // Both must have values
        if let (Some(mut func), Some(val)) = (f_ab.value, m_a.value) {
            GraphGeneratableEffect {
                value: Some(func(val)),
                error: None,
                logs: combined_logs,
            }
        } else {
            // Should not happen if error is None, but technically possible if we have a state with no value and no error?
            GraphGeneratableEffect {
                value: None,
                error: None,
                logs: combined_logs,
            }
        }
    }
}

impl<E: Clone, L: Clone + Default + LogAppend> Monad<GraphGeneratableEffectWitness<E, L>>
    for GraphGeneratableEffectWitness<E, L>
{
    fn bind<A, B, Func>(m_a: <Self as HKT>::Type<A>, mut f: Func) -> <Self as HKT>::Type<B>
    where
        Func: FnMut(A) -> <Self as HKT>::Type<B>,
    {
        if let Some(err) = m_a.error {
            return GraphGeneratableEffect {
                value: None,
                error: Some(err),
                logs: m_a.logs,
            };
        }

        if let Some(val) = m_a.value {
            let mut m_b = f(val);
            let mut new_logs = m_a.logs;
            new_logs.append(&mut m_b.logs);
            GraphGeneratableEffect {
                value: m_b.value,
                error: m_b.error,
                logs: new_logs,
            }
        } else {
            // No value, no error?
            GraphGeneratableEffect {
                value: None,
                error: None,
                logs: m_a.logs,
            }
        }
    }
}

/// The effect system witness that fixes error and log types.
///
/// This struct implements [`Effect3`] to provide a complete HKT effect system
/// with `ModelValidationError` as the error type and `ModificationLog` as the log type.
pub struct GraphGeneratableEffectSystem;

impl Effect3 for GraphGeneratableEffectSystem {
    type Fixed1 = ModelValidationError;
    type Fixed2 = ModificationLog;
    type HktWitness = GraphGeneratableEffectWitness<Self::Fixed1, Self::Fixed2>;
}

/// Type alias for auditable graph generator computations.
///
/// This is the primary type used throughout the HKT generative system.
/// It represents a computation that produces a value of type `T` while
/// automatically tracking errors and maintaining a complete audit log.
///
/// # Example
///
/// ```rust,ignore
/// use deep_causality::types::generative_types::effect_system::*;
///
/// fn my_operation() -> AuditableGraphGenerator<MyState> {
///     GraphGeneratableEffectSafe {
///         value: Some(my_state),
///         error: None,
///         logs: ModificationLog::new(),
///     }
/// }
/// ```
pub type AuditableGraphGenerator<T> =
    <<GraphGeneratableEffectSystem as Effect3>::HktWitness as HKT>::Type<T>;
